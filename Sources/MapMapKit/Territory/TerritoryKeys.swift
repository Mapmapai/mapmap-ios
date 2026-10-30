import Foundation

/// The public halves of the keys that sign MapMap's hosted territory
/// packages, for pinning in an app. Both are ed25519 public keys as 64 hex
/// characters, the form ``TerritoryStore`` takes.
///
/// Pin them at build time; never read either from the network. An app that
/// runs its own factory or region signer passes its own keys instead.
public enum TerritoryKeys {
    /// The factory key: verifies every country package on the hosted
    /// channel (`https://api.mapmap.ai/territories`). Also published at
    /// mapmap.ai/docs/territories.
    public static let hostedFactoryKeyHex =
        "c2230696626a1ecbc61cf9ac141eabea5a3a1a15dab70d2acc110bec79108bcf"

    /// The region key: verifies custom regions (`region-` ids) cut by the
    /// hosted gateway (`POST /v1/jobs/territory`). The core accepts it for
    /// `region-` ids only, and never the factory key for them, so a leaked
    /// region key cannot forge a country package. Pass it as
    /// `TerritoryStore(rootDir:verifyingKeyHex:regionKeyHex:)`.
    public static let hostedRegionKeyHex =
        "6f60f17bc31be2f7696cb957b2188416741e09cb3e7bdec2719fe553213be107"
}
