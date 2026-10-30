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
///
/// Installs are cancellable. The `cancel:` overloads take a `CancelToken`
/// (from the core) that can be tripped from any thread, and they also
/// trip it when the calling Swift `Task` is cancelled, so `task.cancel()`
/// works the way callers expect. A cancelled install returns
/// `InstallOutcome.cancelled` / `UpdateOutcome.cancelled` rather than
/// throwing: nothing was installed, staging is removed, the previous
/// version is untouched. Cancelling after completion changes nothing.
///
/// Custom regions (`region-` ids, cut by `POST /v1/jobs/territory`) are
/// signed by a separate region key. Pass its public half as `regionKeyHex`
/// (``TerritoryKeys/hostedRegionKeyHex`` for the hosted gateway) to accept
/// them; the core then verifies `region-` ids against that key only and
/// every other id against the factory key only. Without it every `region-`
/// package is refused as a bad signature.
public actor TerritoryStore {

    private let rootDir: URL
    private let verifyingKeyHex: String
    private let regionKeyHex: String?

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
    ///   - regionKeyHex: the region signing key's public half, 64 hex
    ///     characters, or `nil` to refuse custom regions. Pinned like the
    ///     factory key; never read from the network.
    public init(rootDir: URL, verifyingKeyHex: String, regionKeyHex: String? = nil) {
        self.rootDir = rootDir
        self.verifyingKeyHex = verifyingKeyHex
        self.regionKeyHex = regionKeyHex
    }

    /// Whether this store was given a region key, and so can install
    /// custom regions.
    public nonisolated var acceptsCustomRegions: Bool { regionKeyHex != nil }

    deinit {
        for continuation in observers.values {
            continuation.finish()
        }
    }

    private func manager() throws -> TerritoryManager {
        if let manager = lazyManager { return manager }
        let manager: TerritoryManager
        if let regionKeyHex {
            manager = try TerritoryManager.withRegionKey(
                rootDir: rootDir.path, verifyingKeyHex: verifyingKeyHex,
                regionKeyHex: regionKeyHex)
        } else {
            manager = try TerritoryManager(
                rootDir: rootDir.path, verifyingKeyHex: verifyingKeyHex)
        }
        lazyManager = manager
        return manager
    }

    /// Run a blocking native call off the cooperative pool.
    private func blocking<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .utility) { try body() }.value
    }

    /// As ``blocking(_:)``, also tripping `cancel` if the calling task is
    /// cancelled while the native call runs. The detached task itself is
    /// never cancelled: the core stops at its next safe point and returns
    /// a `cancelled` outcome, which is the only clean way out of a
    /// blocking FFI call.
    private func blocking<T: Sendable>(
        cancel: CancelToken,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await blocking(body)
        } onCancel: {
            cancel.cancel()
        }
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

    /// ``install(snpkg:)`` with a cancellation handle. The core polls
    /// `cancel` between archive entries, before verification and before
    /// promotion; a tripped token (or a cancelled calling task) yields
    /// `.cancelled` with staging removed and nothing installed.
    public func install(snpkg: URL, cancel: CancelToken) async throws -> InstallOutcome {
        let manager = try manager()
        let path = snpkg.path
        let outcome = try await blocking(cancel: cancel) {
            try manager.installSnpkgCancellable(archivePath: path, cancel: cancel)
        }
        if case .installed = outcome { publish(try manager.list()) }
        return outcome
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

    /// ``installDirectory(_:)`` with a cancellation handle; see
    /// ``install(snpkg:cancel:)``.
    public func installDirectory(
        _ packageDir: URL, cancel: CancelToken
    ) async throws -> InstallOutcome {
        let manager = try manager()
        let path = packageDir.path
        let outcome = try await blocking(cancel: cancel) {
            try manager.installDirCancellable(packageDir: path, cancel: cancel)
        }
        if case .installed = outcome { publish(try manager.list()) }
        return outcome
    }

    /// Install `territoryId` **from its channel**: the first-install
    /// counterpart of ``applyUpdate(territoryId:manifestJson:manifestSigBase64:fetcher:)``.
    /// `indexJson` / `indexSigBase64` are the exact served bytes of the
    /// channel index and its detached signature; the channel's latest
    /// version is installed, fetching only the layers not in `omit`.
    ///
    /// Nothing is trusted but the pinned keys: the index signature, the
    /// manifest signature and every layer hash are checked, and the
    /// assembled package goes through the full verification pass before it
    /// is promoted. Interrupted installs resume. A tripped `cancel` (or a
    /// cancelled calling task) yields `.cancelled` with nothing installed.
    ///
    /// - Throws: ``NavCoreError/Verification(message:)`` if a signature or
    ///   hash does not verify, including a `region-` id on a store without
    ///   a region key.
    public func installFromChannel(
        territoryId: String,
        indexJson: String,
        indexSigBase64: String,
        fetcher: LayerFetcher,
        omit: [MapLayerKind] = [],
        cancel: CancelToken = CancelToken()
    ) async throws -> ChannelInstallOutcome {
        let manager = try manager()
        let outcome = try await blocking(cancel: cancel) {
            try manager.installFromChannel(
                territoryId: territoryId, indexJson: indexJson,
                indexSigBase64: indexSigBase64, omit: omit, fetcher: fetcher,
                cancel: cancel)
        }
        if case .installed = outcome { publish(try manager.list()) }
        return outcome
    }

    /// Bring `territoryId` to the channel's latest version, whichever way
    /// that takes: a first install from the channel when it is not
    /// installed, a signed differential update when an older version is,
    /// nothing when it is already current. Updates go through
    /// ``checkForUpdate(territoryId:indexJson:indexSigBase64:fetcher:)``,
    /// so a channel can never move an installed territory backwards.
    public func sync(
        territoryId: String,
        indexJson: String,
        indexSigBase64: String,
        fetcher: LayerFetcher,
        omit: [MapLayerKind] = [],
        cancel: CancelToken = CancelToken()
    ) async throws -> ChannelSync {
        let installed = try await refresh().first { $0.territoryId == territoryId }
        guard let installed else {
            switch try await installFromChannel(
                territoryId: territoryId, indexJson: indexJson,
                indexSigBase64: indexSigBase64, fetcher: fetcher, omit: omit,
                cancel: cancel)
            {
            case .installed(let result): return .installed(result)
            case .cancelled: return .cancelled
            }
        }
        guard
            let update = try await checkForUpdate(
                territoryId: territoryId, indexJson: indexJson,
                indexSigBase64: indexSigBase64, fetcher: fetcher)
        else { return .upToDate(installed) }
        switch try await applyUpdate(
            territoryId: territoryId, update: update, fetcher: fetcher, cancel: cancel)
        {
        case .applied(let result): return .updated(result)
        case .cancelled: return .cancelled
        }
    }

    /// ``sync(territoryId:indexJson:indexSigBase64:fetcher:omit:cancel:)``
    /// over HTTPS: fetch the signed index from `source` and every layer
    /// relative to it with an ``HTTPChannelFetcher``. `cancel` also stops a
    /// transfer in progress.
    public func sync(
        territoryId: String,
        source: ChannelSource,
        apiKey: String? = nil,
        omit: [MapLayerKind] = [],
        cancel: CancelToken = CancelToken(),
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> ChannelSync {
        let fetcher = HTTPChannelFetcher(
            source: source, apiKey: apiKey, cancel: cancel, onBytes: onBytes)
        let index: SignedChannelIndex
        do {
            index = try await blocking(cancel: cancel) { try fetcher.fetchIndex() }
        } catch {
            if cancel.isCancelled() { return .cancelled }
            throw error
        }
        return try await sync(
            territoryId: territoryId, indexJson: index.json,
            indexSigBase64: index.signatureBase64, fetcher: fetcher, omit: omit,
            cancel: cancel)
    }

    /// Install, or update, a custom region from the `territory_id`,
    /// `index_url` and `index_sig_url` of a `POST /v1/jobs/territory`
    /// result. A re-cut of the same area after the country is republished
    /// is the same id at a newer version, so calling this again is the
    /// update.
    ///
    /// - Throws: ``ChannelSourceError/noRegionKey`` if this store has no
    ///   region key; ``ChannelSourceError`` for a malformed id or URL.
    public func installCustomRegion(
        territoryId: String,
        indexURL: URL,
        indexSigURL: URL,
        apiKey: String? = nil,
        omit: [MapLayerKind] = [],
        cancel: CancelToken = CancelToken(),
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> ChannelSync {
        guard acceptsCustomRegions else { throw ChannelSourceError.noRegionKey }
        let source = try ChannelSource.customRegion(
            territoryId: territoryId, indexURL: indexURL, indexSigURL: indexSigURL)
        return try await sync(
            territoryId: territoryId, source: source, apiKey: apiKey, omit: omit,
            cancel: cancel, onBytes: onBytes)
    }

    /// Re-verify an installed territory from disk: the manifest signature
    /// (against the key its id is partitioned to), the hash of every layer
    /// it holds and the absence of every layer it omitted. The on-demand
    /// integrity check for after a restore or a crash.
    ///
    /// - Throws: ``NavCoreError/Verification(message:)`` when the install
    ///   must be repaired or reinstalled.
    @discardableResult
    public func verify(territoryId: String) async throws -> TerritoryInfo {
        let manager = try manager()
        return try await blocking { try manager.verifyTerritory(territoryId: territoryId) }
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

    /// ``applyUpdate(territoryId:manifestJson:manifestSigBase64:fetcher:)``
    /// with a cancellation handle. The core polls `cancel` before every
    /// layer download, between archive entries while unpacking, before
    /// each hash pass and before promotion; a tripped token (or a
    /// cancelled calling task) yields `.cancelled`. The installed version
    /// is untouched and staging removed; layers already fetched *and
    /// verified* stay in the resumable cache, so a later attempt with the
    /// same manifest re-fetches only what is missing.
    ///
    /// The token cannot interrupt `fetcher` while it is inside a
    /// transfer: give the fetcher the same token and have it poll
    /// `isCancelled()` between chunks (or cancel its `URLSessionTask`).
    /// Whatever the fetcher then throws, a tripped token reports
    /// `.cancelled` rather than a transport error.
    public func applyUpdate(
        territoryId: String,
        manifestJson: String,
        manifestSigBase64: String,
        fetcher: LayerFetcher,
        cancel: CancelToken
    ) async throws -> UpdateOutcome {
        let manager = try manager()
        let outcome = try await blocking(cancel: cancel) {
            try manager.applyUpdateCancellable(
                territoryId: territoryId,
                newManifestJson: manifestJson,
                newManifestSigBase64: manifestSigBase64,
                fetcher: fetcher,
                cancel: cancel)
        }
        if case .applied = outcome { publish(try manager.list()) }
        return outcome
    }

    /// ``applyUpdate(territoryId:update:fetcher:)`` with a cancellation
    /// handle; see ``applyUpdate(territoryId:manifestJson:manifestSigBase64:fetcher:cancel:)``.
    public func applyUpdate(
        territoryId: String,
        update: AvailableUpdate,
        fetcher: LayerFetcher,
        cancel: CancelToken
    ) async throws -> UpdateOutcome {
        try await applyUpdate(
            territoryId: territoryId,
            manifestJson: update.manifestJson,
            manifestSigBase64: update.manifestSig,
            fetcher: fetcher,
            cancel: cancel)
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

/// What ``TerritoryStore/sync(territoryId:indexJson:indexSigBase64:fetcher:omit:cancel:)`` did.
public enum ChannelSync: Sendable {
    /// The territory was not installed; the channel's latest version now is.
    case installed(ChannelInstallResult)
    /// An older version was installed; it was updated in place.
    case updated(UpdateResult)
    /// Already on the channel's latest version; nothing was downloaded.
    case upToDate(TerritoryInfo)
    /// The `CancelToken` was tripped; nothing changed on disk.
    case cancelled
}
