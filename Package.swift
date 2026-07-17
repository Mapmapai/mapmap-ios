// swift-tools-version: 5.9
//
// MapMap — the iOS navigation SDK.
//
// Fully offline turn-by-turn navigation: signed territory packages,
// on-device Valhalla routing with ADR dangerous-goods enforcement,
// Ferrostar-based guidance and MapLibre/PMTiles rendering.
//
// Products:
//  - MapMapKit      — the SDK (territories, routing, guidance, replay).
//  - MapMapValhalla — opt-in on-device Valhalla engine binding
//                     (valhalla-mobile, MIT, iOS 16.4+).
//
// The Rust core ships as the MapMapFFI binary target below; its URL and
// checksum are pinned per release by the publish workflow.

import PackageDescription

let package = Package(
    name: "MapMapKit",
    platforms: [
        .iOS("16.4")
    ],
    products: [
        .library(name: "MapMapKit", targets: ["MapMapKit"]),
        .library(name: "MapMapValhalla", targets: ["MapMapValhalla"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Rallista/valhalla-mobile.git", from: "0.5.1")
    ],
    targets: [
        .target(
            name: "MapMapKit",
            dependencies: ["MapMapFFI"]
        ),
        .target(
            name: "MapMapValhalla",
            dependencies: [
                "MapMapKit",
                .product(name: "Valhalla", package: "valhalla-mobile"),
            ]
        ),
        .binaryTarget(
            name: "MapMapFFI",
            url:
                "https://github.com/weareprecode/mapmap-ios/releases/download/sdk-v0.1.0/MapMapFFI.xcframework.zip",
            checksum: "a56ea2f18bc13f9a591393c265af270969cc417a3a6fa1c8a0d259bdda1c7e2f"
        ),
    ]
)
