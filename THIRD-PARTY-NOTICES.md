# Third-party notices

MapMap is first-party proprietary code (see `LICENSE`) built on
permissive open-source components. This file lists the **architectural**
third-party components, their licences (SPDX identifier + upstream licence
text) and copyright lines. It is not exhaustive at the Rust-crate level: the
complete, machine-generated crate report (via `cargo deny` / `cargo about`)
is produced in CI and ships with the M4 SBOM/procurement pack. Component
ancestry and how each is consumed is documented in
[`docs/LINEAGE.md`](docs/LINEAGE.md).

| Component | Use | SPDX | Copyright | Licence text |
|---|---|---|---|---|
| [Valhalla](https://github.com/valhalla/valhalla) | Routing engine (server + tile builder; bounded ADR costing fork planned under `fork/`, M3) | MIT | Copyright (c) 2018 Valhalla contributors; Copyright (c) 2015-2017 Mapillary AB, Mapzen | [LICENSE.md](https://github.com/valhalla/valhalla/blob/master/COPYING) |
| [MapLibre Native](https://github.com/maplibre/maplibre-native) | Map rendering in the mobile/web SDKs (unmodified binary dependency) | BSD-2-Clause | Copyright (c) MapLibre contributors; Copyright (c) 2014-2020 Mapbox | [LICENSE.md](https://github.com/maplibre/maplibre-native/blob/main/LICENSE.md) |
| [Ferrostar](https://github.com/stadiamaps/ferrostar) | Turn-by-turn guidance core (pinned Rust crate) | BSD-3-Clause | Copyright (c) 2023 Stadia Maps, Inc. | [LICENSE](https://github.com/stadiamaps/ferrostar/blob/main/LICENSE) |
| [Planetiler](https://github.com/onthegomap/planetiler) | Render-tile generation (build-side subprocess of `snfactory`, never distributed to devices) | Apache-2.0 | Copyright (c) Planetiler contributors / Michael Barry | [LICENSE](https://github.com/onthegomap/planetiler/blob/main/LICENSE) |
| [PMTiles](https://github.com/protomaps/PMTiles) | Tile container format (written by Planetiler, read by MapLibre) | BSD-3-Clause | Copyright (c) 2021 Protomaps LLC | [LICENSE](https://github.com/protomaps/PMTiles/blob/main/LICENSE) |
| [Photon](https://github.com/komoot/photon) | Hosted geocoding service (self-hosted behind the gateway) | Apache-2.0 | Copyright (c) komoot GmbH and Photon contributors | [LICENSE](https://github.com/komoot/photon/blob/master/LICENSE) |
| [tantivy](https://github.com/quickwit-oss/tantivy) | On-device/hosted search index (Rust crate in `sn-geocode`) | MIT | Copyright (c) 2018 by the project authors (Quickwit, Inc. and contributors) | [LICENSE](https://github.com/quickwit-oss/tantivy/blob/main/LICENSE) |
| [GraphHopper](https://github.com/graphhopper/graphhopper) | Optional hosted ADR-capable routing backend (day-one, self-hosted, unmodified; also the public spec reference for ADR custom-model semantics) | Apache-2.0 | Copyright GraphHopper GmbH and contributors | [LICENSE.txt](https://github.com/graphhopper/graphhopper/blob/master/LICENSE.txt) |
| [VROOM](https://github.com/VROOM-Project/vroom) | Optional route-optimisation (VRP) solver sidecar behind `POST /optimise` (self-hosted, unmodified; fed explicit travel-time matrices by the gateway, never routing itself) | BSD-2-Clause | Copyright (c) 2015-2025 Julien Coupey and VROOM contributors | [LICENSE](https://github.com/VROOM-Project/vroom/blob/master/LICENSE) |
| [OpenMapTiles](https://openmaptiles.org) | Vector tile schema of the render layer and the packaged/hosted map styles (emitted by Planetiler, styled by `sn-style`; "© OpenMapTiles" attribution is stamped on every compiled style and cannot be removed) | CC-BY-4.0 | © OpenMapTiles, MapTiler AG and contributors | [LICENSE.md](https://github.com/openmaptiles/openmaptiles/blob/master/LICENSE.md) |
| [Noto Sans](https://fonts.google.com/noto) | Label font referenced by packaged/hosted map styles (as hosted glyph PBFs; font files are not embedded in territory packages) | OFL-1.1 | Copyright Google LLC | [SIL Open Font License 1.1](https://openfontlicense.org) |

Full licence texts are available at the linked upstream files and at
[spdx.org/licenses](https://spdx.org/licenses/) under the given identifiers
(MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0, CC-BY-4.0, OFL-1.1). Where a
component is distributed with our images or SDKs, the corresponding licence
text is included in the distributed artefact's notices.

## Data

OpenStreetMap data is © OpenStreetMap contributors, licensed
[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/). OSM-derived
artefacts (routing tiles, render tiles, geocode indices) are handled as ODbL
Derivative Databases with a published recreation recipe — see
[`docs/ODBL-RECIPE.md`](docs/ODBL-RECIPE.md).

## MPL-2.0 exception — UniFFI

The UniFFI crate family (`uniffi`, `uniffi_core`, `uniffi_bindgen`,
`uniffi_build`, `uniffi_macros`, `uniffi_internal_macros`, `uniffi_meta`,
`uniffi_pipeline`, `uniffi_udl`; © Mozilla Foundation) is licensed under the
Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/). MPL-2.0 is
file-scoped: our binaries link these crates unmodified, which imposes no
obligations on first-party code; the covered files' source is publicly
available upstream at https://github.com/mozilla/uniffi-rs. This is a
per-crate exception recorded in `deny.toml` — no other copyleft licence is
permitted in the dependency graph.
