import Foundation

/// Where a signed territory channel lives over HTTPS: its index, the
/// index's detached signature, and the base every channel-relative layer
/// path (`territories/<id>/<version>/...`) is resolved against.
///
/// Nothing fetched from here is trusted: the core verifies the index
/// signature, the manifest signature and every layer hash against the keys
/// pinned in the ``TerritoryStore``.
public struct ChannelSource: Equatable, Sendable {
    public let indexURL: URL
    public let indexSigURL: URL
    /// Layer paths are appended to this.
    public let layerBaseURL: URL

    public init(indexURL: URL, indexSigURL: URL, layerBaseURL: URL) {
        self.indexURL = indexURL
        self.indexSigURL = indexSigURL
        self.layerBaseURL = layerBaseURL
    }

    /// The hosted gateway.
    public static let defaultGateway = URL(string: "https://api.mapmap.ai")!

    /// A gateway's country channel: `GET /territories` (the signed index)
    /// and `GET /territories/index.sig`.
    public static func gateway(_ base: URL = defaultGateway) -> ChannelSource {
        ChannelSource(
            indexURL: base.appendingPathComponent("territories"),
            indexSigURL: base.appendingPathComponent("territories/index.sig"),
            layerBaseURL: base)
    }

    /// A custom region's own one-territory channel, from the `index_url` /
    /// `index_sig_url` of a `POST /v1/jobs/territory` result.
    ///
    /// The gateway serves the index at `<base>/v1/territories/<id>/index.json`
    /// and the layers under `<base>/territories/<id>/...`, so the layer base
    /// is `<base>`. Any other `.../index.json` (a mirror of the region
    /// directory, laid out as `SN_REGION_DIR/<id>/`) resolves layers next to
    /// the index.
    ///
    /// - Throws: ``ChannelSourceError`` if `territoryId` is not a
    ///   custom-region id or `indexURL` does not end in `index.json`.
    public static func customRegion(
        territoryId: String, indexURL: URL, indexSigURL: URL
    ) throws -> ChannelSource {
        guard isCustomRegionId(territoryId) else {
            throw ChannelSourceError.notACustomRegion(territoryId)
        }
        let index = indexURL.absoluteString
        let gatewaySuffix = "/v1/territories/\(territoryId)/index.json"
        let base: String
        if index.hasSuffix(gatewaySuffix) {
            base = String(index.dropLast(gatewaySuffix.count))
        } else if index.hasSuffix("/index.json") {
            base = String(index.dropLast("/index.json".count))
        } else {
            throw ChannelSourceError.notAnIndexURL(index)
        }
        guard let layerBase = URL(string: base) else {
            throw ChannelSourceError.notAnIndexURL(index)
        }
        return ChannelSource(indexURL: indexURL, indexSigURL: indexSigURL, layerBaseURL: layerBase)
    }

    /// Whether `territoryId` has the shape the gateway gives custom
    /// regions: `region-` plus 16 lowercase hex characters.
    public static func isCustomRegionId(_ territoryId: String) -> Bool {
        let prefix = "region-"
        guard territoryId.hasPrefix(prefix) else { return false }
        let hex = territoryId.dropFirst(prefix.count)
        return hex.count == 16 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// Why a ``ChannelSource`` could not be built.
public enum ChannelSourceError: Error, Equatable, CustomStringConvertible {
    case notACustomRegion(String)
    case notAnIndexURL(String)
    /// The store was built without a region key, so it refuses every
    /// custom region.
    case noRegionKey

    public var description: String {
        switch self {
        case .notACustomRegion(let id):
            return "\"\(id)\" is not a custom-region id (region- plus 16 hex characters)"
        case .notAnIndexURL(let url):
            return "a region index URL ends in index.json, got \(url)"
        case .noRegionKey:
            return "this TerritoryStore has no region key, so it refuses every custom region: "
                + "create it with regionKeyHex: TerritoryKeys.hostedRegionKeyHex"
        }
    }
}

/// The exact served bytes of a channel index and its detached signature.
public struct SignedChannelIndex: Equatable, Sendable {
    public let json: String
    public let signatureBase64: String
}

/// A blocking HTTPS ``LayerFetcher`` for a ``ChannelSource``, on
/// `URLSession`. ``TerritoryStore`` calls it off the cooperative pool.
///
/// `apiKey` is sent as `Authorization: Bearer <apiKey>` (the hosted gateway
/// meters layer downloads against the key's allowance); `nil` for an open
/// mirror. `cancel` is polled while a request is in flight, so a tripped
/// token aborts the transfer, not only the next one. `configuration`
/// defaults to an ephemeral session (pass your own for a proxy or a test
/// `URLProtocol`).
public final class HTTPChannelFetcher: LayerFetcher, @unchecked Sendable {
    public let source: ChannelSource
    private let apiKey: String?
    private let cancel: CancelToken?
    private let onBytes: (@Sendable (Int64) -> Void)?
    private let session: URLSession
    private let lock = NSLock()
    private var received: Int64 = 0
    private var failedStatus: Int?

    public init(
        source: ChannelSource,
        apiKey: String? = nil,
        cancel: CancelToken? = nil,
        onBytes: (@Sendable (Int64) -> Void)? = nil,
        configuration: URLSessionConfiguration? = nil
    ) {
        self.source = source
        self.apiKey = apiKey
        self.cancel = cancel
        self.onBytes = onBytes
        let config = configuration ?? {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            config.waitsForConnectivity = false
            return config
        }()
        self.session = URLSession(configuration: config)
    }

    /// Total bytes received so far.
    public var bytesReceived: Int64 {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    /// HTTP status of the last failed request: 401/403 auth, 402 allowance,
    /// 404 not found.
    public var lastFailedStatus: Int? {
        lock.lock(); defer { lock.unlock() }
        return failedStatus
    }

    /// GET the signed index and its signature, exact bytes.
    public func fetchIndex() throws -> SignedChannelIndex {
        let json = String(decoding: try get(source.indexURL), as: UTF8.self)
        let sig = String(decoding: try get(source.indexSigURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SignedChannelIndex(json: json, signatureBase64: sig)
    }

    public func fetch(relPath: String, expectedBlake3: String, destPath: String) throws {
        if relPath.hasPrefix("/") || relPath.contains("://")
            || relPath.split(separator: "/").contains("..")
        {
            throw FetchError.Transport(message: "refusing a non channel-relative path: \(relPath)")
        }
        let data = try get(source.layerBaseURL.appendingPathComponent(relPath))
        do {
            try data.write(to: URL(fileURLWithPath: destPath), options: .atomic)
        } catch {
            throw FetchError.Transport(message: "cannot write \(destPath): \(error)")
        }
    }

    private func get(_ url: URL) throws -> Data {
        if cancel?.isCancelled() == true { throw FetchError.Transport(message: "cancelled") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        let done = DispatchSemaphore(value: 0)
        var body: Data?
        var failure: String?
        var status = 0
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                failure = "request to \(url.absoluteString) failed: \(error.localizedDescription)"
                return
            }
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data
        }
        task.resume()
        while done.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
            if cancel?.isCancelled() == true { task.cancel() }
        }
        if cancel?.isCancelled() == true { throw FetchError.Transport(message: "cancelled") }
        if let failure { throw FetchError.Transport(message: failure) }
        guard (200...299).contains(status) else {
            lock.lock(); failedStatus = status; lock.unlock()
            throw FetchError.Transport(message: "HTTP \(status) for \(url.absoluteString)")
        }
        let data = body ?? Data()
        lock.lock()
        received += Int64(data.count)
        let total = received
        lock.unlock()
        onBytes?(total)
        return data
    }
}
