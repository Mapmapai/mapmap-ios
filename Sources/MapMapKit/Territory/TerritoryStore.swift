import Foundation

/// Actor-isolated store of signed offline territory packages.
///
/// Wraps the Rust `TerritoryManager`: every package is ed25519-signature
/// and BLAKE3-layer-hash verified before promotion, and nothing is
/// trusted until verification passes. Verification is fail-closed — a
/// package that does not verify is never promoted and leaves nothing on
/// disk.
///
/// All methods are `async` by actor isolation; the disk-heavy calls
/// (installs read whole archives) additionally hop onto a detached
/// utility task so they never occupy a cooperative-pool thread for the
/// duration of an install.
///
/// ``territories`` caches the installed set; it refreshes after every
/// mutating call and on ``refresh()``. Observe changes with
/// ``territoryUpdates()``.
public actor TerritoryStore {

    private let rootDir: URL
    private let verifyingKeyHex: String

    // Lazy so constructing the store never touches the native library —
    // important for previews and tests; the first call pays the cost.
    private var lazyManager: TerritoryManager?

    /// The installed territories as of the last refresh or mutation.
    public private(set) var territories: [TerritoryInfo] = []

    private var observers: [UUID: AsyncStream<[TerritoryInfo]>.Continuation] = [:]

    /// - Parameters:
    ///   - rootDir: directory the store owns; created on first use.
    ///   - verifyingKeyHex: the factory signing key's public half, 64 hex
    ///     characters (`sn_package::VerifyingKey::to_hex`). Baked into
    ///     the app at build time — treat it like a pin.
    public init(rootDir: URL, verifyingKeyHex: String) {
        self.rootDir = rootDir
        self.verifyingKeyHex = verifyingKeyHex
    }

    deinit {
        for continuation in observers.values {
            continuation.finish()
        }
    }

    private func manager() throws -> TerritoryManager {
        if let manager = lazyManager { return manager }
        let manager = try TerritoryManager(
            rootDir: rootDir.path, verifyingKeyHex: verifyingKeyHex)
        lazyManager = manager
        return manager
    }

    /// Run a blocking native call off the cooperative pool.
    private func blocking<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .utility) { try body() }.value
    }

    /// Re-read the installed set from disk, cache and broadcast it.
    @discardableResult
    public func refresh() async throws -> [TerritoryInfo] {
        let manager = try manager()
        let listed = try await blocking { try manager.list() }
        publish(listed)
        return listed
    }

    /// Install a packed `.snpkg` archive. Verify-then-promote: a package
    /// that fails verification leaves no trace on disk.
    ///
    /// - Throws: ``NavCoreError/Verification(message:)`` if the signature
    ///   or any layer hash does not verify.
    @discardableResult
    public func install(snpkg: URL) async throws -> TerritoryInfo {
        let manager = try manager()
        let path = snpkg.path
        let info = try await blocking { try manager.installSnpkg(archivePath: path) }
        publish(try manager.list())
        return info
    }

    /// Install an unpacked package directory (same verification rules).
    @discardableResult
    public func installDirectory(_ packageDir: URL) async throws -> TerritoryInfo {
        let manager = try manager()
        let path = packageDir.path
        let info = try await blocking { try manager.installDir(packageDir: path) }
        publish(try manager.list())
        return info
    }

    /// Mark `territoryId` active; persisted atomically by the core.
    public func setActive(_ territoryId: String) async throws {
        let manager = try manager()
        try manager.setActive(territoryId: territoryId)
        publish(try manager.list())
    }

    /// The active territory id, if one is set and still installed.
    public func active() async throws -> String? {
        try manager().active()
    }

    /// The active territory's full info, if any.
    public func activeTerritory() async throws -> TerritoryInfo? {
        let manager = try manager()
        guard let id = try manager.active() else { return nil }
        return try manager.list().first { $0.territoryId == id }
    }

    /// Absolute path of one layer of an installed territory — e.g.
    /// ``MapLayerKind/valhallaTiles`` for the on-device router,
    /// ``MapLayerKind/pmtiles`` for MapLibre.
    public func layerPath(territoryId: String, kind: MapLayerKind) async throws -> URL {
        URL(fileURLWithPath: try manager().layerPath(territoryId: territoryId, kind: kind))
    }

    /// A complete MapLibre style JSON for an installed territory with
    /// **local** (offline) references, mirroring the web SDK's
    /// `buildStyle()`. Load it straight into MapLibre — the territory
    /// tile source points at the installed PMTiles layer via a
    /// `pmtiles://<absolute path>` URL, so the map renders with radios
    /// off. Packages without a baked style layer get the default MapMap
    /// theme compiled on the fly.
    public func territoryStyle(
        territoryId: String, theme: StyleTheme = .light
    ) async throws -> String {
        let manager = try manager()
        return try await blocking {
            try manager.territoryStyle(territoryId: territoryId, theme: theme)
        }
    }

    /// Open the installed territory's bundled geocode index for fully
    /// offline on-device search. The returned handle holds the index
    /// open (mmap-backed) — create it once per territory and reuse it:
    ///
    /// ```swift
    /// let search = try await store.openSearch(territoryId: "uk")
    /// let places = try search.search(
    ///     query: "watford gap", near: nil, limit: 10)
    /// ```
    public func openSearch(territoryId: String) async throws -> TerritorySearch {
        let manager = try manager()
        return try await blocking { try manager.openSearch(territoryId: territoryId) }
    }

    /// Remove an installed territory (clears the active marker if needed).
    public func remove(_ territoryId: String) async throws {
        let manager = try manager()
        let id = territoryId
        try await blocking { try manager.remove(territoryId: id) }
        publish(try manager.list())
    }

    /// Plan a differential update against a newly served (signed)
    /// manifest JSON: which layers must be downloaded, and how many bytes.
    public func planUpdate(newManifestJson: String) async throws -> UpdatePlan {
        try manager().planUpdate(newManifestJson: newManifestJson)
    }

    /// Check the signed channel index for an update to an installed
    /// territory.
    ///
    /// `indexJson` must be the exact bytes served as `index.json` and
    /// `indexSigBase64` the content of `index.json.sig`; the remote
    /// manifest is fetched and verified through `fetcher` (the app's
    /// download transport — URLSession, an air-gapped mirror, … — the
    /// core decides *what* to fetch and cryptographically verifies
    /// everything itself). Returns `nil` when the device is already on
    /// the channel's latest version or the channel does not list the
    /// territory.
    public func checkForUpdate(
        territoryId: String,
        indexJson: String,
        indexSigBase64: String,
        fetcher: LayerFetcher
    ) async throws -> AvailableUpdate? {
        let manager = try manager()
        return try await blocking {
            try manager.checkForUpdate(
                territoryId: territoryId,
                indexJson: indexJson,
                indexSigBase64: indexSigBase64,
                fetcher: fetcher)
        }
    }

    /// Apply a differential update: stage, fetch only the changed layers
    /// through `fetcher`, verify everything and swap atomically. Any
    /// failure leaves the installed territory untouched; the active flag
    /// is preserved.
    @discardableResult
    public func applyUpdate(
        territoryId: String,
        manifestJson: String,
        manifestSigBase64: String,
        fetcher: LayerFetcher
    ) async throws -> UpdateResult {
        let manager = try manager()
        let result = try await blocking {
            try manager.applyUpdate(
                territoryId: territoryId,
                newManifestJson: manifestJson,
                newManifestSigBase64: manifestSigBase64,
                fetcher: fetcher)
        }
        publish(try manager.list())
        return result
    }

    /// Apply an update discovered by
    /// ``checkForUpdate(territoryId:indexJson:indexSigBase64:fetcher:)``,
    /// passing its manifest and signature through verbatim.
    @discardableResult
    public func applyUpdate(
        territoryId: String,
        update: AvailableUpdate,
        fetcher: LayerFetcher
    ) async throws -> UpdateResult {
        try await applyUpdate(
            territoryId: territoryId,
            manifestJson: update.manifestJson,
            manifestSigBase64: update.manifestSig,
            fetcher: fetcher)
    }

    /// A stream of the installed set: yields the current value
    /// immediately, then every subsequent change. Each call returns an
    /// independent stream; it finishes when the store is deallocated.
    public func territoryUpdates() -> AsyncStream<[TerritoryInfo]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [TerritoryInfo].self)
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.removeObserver(id) }
        }
        observers[id] = continuation
        continuation.yield(territories)
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func publish(_ listed: [TerritoryInfo]) {
        territories = listed
        for continuation in observers.values {
            continuation.yield(listed)
        }
    }
}
