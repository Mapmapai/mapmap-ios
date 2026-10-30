import Foundation
import MapMapKit
import Valhalla

/// ``OfflineRouter`` backed by the on-device Valhalla engine:
/// valhalla-mobile's wrapper (https://github.com/Rallista/valhalla-mobile,
/// MIT, SwiftPM product "Valhalla", iOS 16.4+) compiled against the
/// Valhalla release and patch series the factory builds tiles with
/// (tools/mobile-engine/engine.pin; `mapMapValhallaEngineVersion` in
/// Package.swift). An engine older than the tiles answers 171 "No suitable
/// edges" on every territory, which is why the version is pinned and
/// guarded.
///
/// valhalla-mobile's `Valhalla` class takes a raw Valhalla request JSON and
/// returns the raw response JSON. From 0.6 it throws Valhalla's errors
/// instead of returning them; this router turns a thrown error back into
/// the engine's `{"code", "message"}` envelope, which the Rust core parses
/// and classifies exactly as Android's engine returns it.
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
        do {
            return try engine.route(rawRequest: requestJson)
        } catch ValhallaError.valhallaError(let code, let message) {
            return Self.envelope(code: code, message: message)
        } catch {
            return Self.envelope(code: -1, message: "\(error)")
        }
    }

    /// Release the native engine and the mapped tiles. Routing after this
    /// returns an error envelope.
    public func close() {
        engine.close()
    }

    /// The engine's error envelope, built with a JSON encoder so a quote in
    /// the message (Valhalla echoes caller text) cannot break the document.
    static func envelope(code: Int, message: String) -> String {
        struct Envelope: Encodable {
            let code: Int
            let message: String
        }
        guard let data = try? JSONEncoder().encode(Envelope(code: code, message: message)),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"code":-1,"message":"error not encodable"}"#
        }
        return json
    }
}
