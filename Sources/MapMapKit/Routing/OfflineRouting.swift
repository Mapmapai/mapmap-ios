import Foundation

/// An on-device routing engine.
///
/// This is the Rust core's `LocalRouter` callback interface with a Swift
/// name: implementations execute a Valhalla turn-by-turn request JSON
/// synchronously and return the raw response JSON (either a route
/// response or a Valhalla error body — the core parses and classifies
/// both).
///
/// The production implementation is `ValhallaMobileRouter` in the
/// `MapMapValhalla` product (iOS only — it wraps the
/// valhalla-mobile engine); tests inject fakes that return canned
/// responses.
public protocol OfflineRouter: LocalRouter {}

/// On-device route computation.
///
/// The Rust core builds the Valhalla request (merging ADR dangerous-goods
/// and dimensional costing options, rejecting conflicts), the injected
/// ``OfflineRouter`` executes it against local tiles, and the core parses
/// the response into a ``RouteResult`` whose `valhallaResponseJson` feeds
/// ``NavigationEngine``.
public enum OfflineRouting {

    /// ADR profiles ride on Valhalla truck costing options; requesting
    /// any other costing model with an ADR profile is a contract
    /// violation the Rust core rejects. Checked here too so the failure
    /// is a fast, clearly-attributed
    /// ``MapMapKitError/incompatibleCosting(costing:)`` rather than
    /// a routing error after the FFI hop.
    public static func requireCompatibleCosting(
        costing: CostingModel, adr: AdrProfile?
    ) throws {
        if adr != nil, costing != .truck {
            throw MapMapKitError.incompatibleCosting(costing: costing)
        }
    }

    /// Compute a route on-device.
    ///
    /// Routing is CPU-bound native work; it runs on a detached utility
    /// task, never on the caller's executor.
    ///
    /// - Parameters:
    ///   - router: the on-device engine, usually a `ValhallaMobileRouter`.
    ///   - waypoints: at least two ``RoutePoint``s, in visit order.
    ///   - costing: the Valhalla costing model; must be
    ///     ``CostingModel/truck`` when `adr` is supplied.
    ///   - adr: optional dangerous-goods/dimensional profile — when set,
    ///     the request is built with the restrictions merged in, so
    ///     illegal roads and tunnels are excluded before the route exists.
    /// - Throws: ``NavCoreError/Routing(message:)`` when the engine
    ///   returns a Valhalla error body (e.g. no route, no tiles for the
    ///   area).
    public static func route(
        router: LocalRouter,
        waypoints: [RoutePoint],
        costing: CostingModel = .auto,
        adr: AdrProfile? = nil
    ) async throws -> RouteResult {
        try requireCompatibleCosting(costing: costing, adr: adr)
        return try await Task.detached(priority: .utility) {
            try routeOffline(router: router, locations: waypoints, costing: costing, adr: adr)
        }.value
    }

    /// Build the raw Valhalla request JSON without executing it — for
    /// callers that drive the engine themselves or log requests for audit.
    public static func buildRequest(
        waypoints: [RoutePoint],
        costing: CostingModel = .auto,
        adr: AdrProfile? = nil
    ) throws -> String {
        try requireCompatibleCosting(costing: costing, adr: adr)
        return try buildOfflineRouteRequest(locations: waypoints, costing: costing, adr: adr)
    }

    /// Parse a raw engine response into a ``RouteResult``.
    public static func parseResponse(_ responseJson: String) throws -> RouteResult {
        try parseRouteResult(responseJson: responseJson)
    }
}

/// Writes the minimal `valhalla.json` the on-device Valhalla engine needs.
///
/// Key names and defaults follow Valhalla's own config generator,
/// `scripts/valhalla_build_config` (MIT):
/// https://github.com/valhalla/valhalla/blob/master/scripts/valhalla_build_config
/// Keys not listed fall back to Valhalla's compiled-in defaults — the
/// same convention `sn-factory` uses for the build-side config. Only the
/// tile source and a mobile-sized cache are pinned here.
public enum ValhallaConfigWriter {

    /// Mobile default for `mjolnir.max_cache_size` (bytes): 256 MiB.
    public static let defaultMaxCacheBytes: Int64 = 268_435_456

    /// Render the config document for a routing-tile directory (the
    /// territory's ``MapLayerKind/valhallaTiles`` layer).
    public static func configJSON(
        tileDir: URL,
        maxCacheBytes: Int64 = defaultMaxCacheBytes
    ) throws -> String {
        guard maxCacheBytes > 0 else {
            throw MapMapKitError.invalidArgument(
                "maxCacheBytes must be positive, got \(maxCacheBytes)")
        }
        let config: [String: Any] = [
            "logging": [
                "type": "std_out",
                "color": false,
            ],
            "mjolnir": [
                "tile_dir": tileDir.path,
                "max_cache_size": maxCacheBytes,
                "use_lru_mem_cache": true,
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw MapMapKitError.invalidArgument(
                "valhalla config did not serialise as UTF-8")
        }
        return json
    }

    /// Write the config for `tileDir` into `configFile` (parent
    /// directories created), returning `configFile` for chaining.
    @discardableResult
    public static func write(
        tileDir: URL,
        configFile: URL,
        maxCacheBytes: Int64 = defaultMaxCacheBytes
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: tileDir.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw MapMapKitError.invalidArgument(
                "Valhalla tile dir does not exist or is not a directory: \(tileDir.path)")
        }
        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try configJSON(tileDir: tileDir, maxCacheBytes: maxCacheBytes)
            .write(to: configFile, atomically: true, encoding: .utf8)
        return configFile
    }
}
