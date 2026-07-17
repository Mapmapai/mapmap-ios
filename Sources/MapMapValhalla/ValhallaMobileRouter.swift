import Foundation
import MapMapKit
import Valhalla

/// ``OfflineRouter`` backed by valhalla-mobile's on-device engine
/// (https://github.com/Rallista/valhalla-mobile, MIT — SwiftPM product
/// "Valhalla", iOS 16.4+).
///
/// valhalla-mobile's `Valhalla` class exposes exactly the
/// `route(rawRequest:) -> String` shape the Rust core's `LocalRouter`
/// callback expects (verified against
/// `apple/Sources/Valhalla/Valhalla.swift` in the upstream repository,
/// 2026-07-13): a raw Valhalla request JSON in, a raw response JSON (or
/// Valhalla error body) out — the Rust core parses and classifies both.
///
/// This class lives in the separate `MapMapValhalla` product so
/// apps opt in to the engine (which embeds a prebuilt
/// `valhalla-wrapper.xcframework`) — the SwiftPM equivalent of the
/// Android SDK's `compileOnly` seam. Routing is CPU-bound native work —
/// call it through
/// ``MapMapKit/OfflineRouting/route(router:waypoints:costing:adr:)``,
/// which hops off the caller's executor.
public final class ValhallaMobileRouter: OfflineRouter, @unchecked Sendable {

    private let engine: Valhalla

    /// Create a router from an absolute path of a `valhalla.json` whose
    /// `mjolnir.tile_dir` points at the territory's Valhalla tile layer.
    public init(configPath: String) throws {
        self.engine = try Valhalla(configPath: configPath)
    }

    /// Create a router from an existing `valhalla.json` config file.
    public static func fromConfig(_ configFile: URL) throws -> ValhallaMobileRouter {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            throw MapMapKitError.invalidArgument(
                "valhalla config not found: \(configFile.path)")
        }
        return try ValhallaMobileRouter(configPath: configFile.path)
    }

    /// Create a router for a territory's Valhalla tile directory, writing
    /// a config file under `scratchDir` (e.g. the app's caches
    /// directory).
    ///
    /// ```swift
    /// let tiles = try await store.layerPath(territoryId: id, kind: .valhallaTiles)
    /// let router = try ValhallaMobileRouter.fromTileDir(tiles, scratchDir: cachesDir)
    /// ```
    public static func fromTileDir(
        _ tileDir: URL, scratchDir: URL
    ) throws -> ValhallaMobileRouter {
        let config = try ValhallaConfigWriter.write(
            tileDir: tileDir,
            configFile: scratchDir.appendingPathComponent("mapmap-valhalla.json")
        )
        return try fromConfig(config)
    }

    public func route(requestJson: String) -> String {
        engine.route(rawRequest: requestJson)
    }
}
