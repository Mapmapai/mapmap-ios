# MapMap iOS SDK

Fully offline turn-by-turn navigation for iOS: signed territory packages,
on-device Valhalla routing with ADR dangerous-goods enforcement,
Ferrostar-based guidance and MapLibre/PMTiles rendering — no Google
services, no network required once a territory is installed.

This is the binary + Swift-source distribution repository. Docs live at
[mapmap.ai/docs](https://mapmap.ai/docs).

## Installation

Add the package in Xcode (**File → Add Package Dependencies…**):

```
https://github.com/Mapmapai/mapmap-ios
```

or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Mapmapai/mapmap-ios.git", from: "0.1.0")
]
```

Link **MapMapKit**. For on-device routing, also link **MapMapValhalla**
(adds the [valhalla-mobile](https://github.com/Rallista/valhalla-mobile)
engine; iOS 16.4+).

## Quick start

```swift
import MapMapKit

try MapMap.ensureLoaded()

// Install a signed territory package (.snpkg), then route offline.
let store = try TerritoryStore(directory: territoriesDir)
// ... install / activate a territory, build an OfflineRouter,
// start a NavigationEngine guidance session.
```

See the [SDK documentation](https://mapmap.ai/docs) for territories,
routing, ADR compliance and turn-by-turn guidance sessions.

## Products

| Product | What it gives you |
|---|---|
| `MapMapKit` | Territories, offline routing API, ADR checks, `NavigationEngine` guidance, replay corpora |
| `MapMapValhalla` | The on-device Valhalla engine binding (opt-in) |

The Rust navigation core ships as the `MapMapFFI` binary target
(XCFramework), pinned by checksum per release.

## Licence

Proprietary — see [LICENSE](LICENSE) and
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
