import Foundation

/// Entry point for the MapMap iOS SDK.
///
/// The SDK is a thin, idiomatic Swift layer over the Rust navigation core
/// (`sn-nav-core`, linked as a static library inside
/// `MapMapFFI.xcframework`). The raw UniFFI bindings — the
/// `mapmap` component and the `ferrostar` component, which is
/// compiled into the same library — live in `Generated/`; everything else
/// in this module is the supported surface:
///
/// - ``TerritoryStore`` — signed offline territory packages
///   (install / verify / activate / update planning), actor-isolated.
/// - ``OfflineRouting`` — on-device Valhalla routing with ADR
///   dangerous-goods enforcement merged into every request.
/// - ``AdrCompliance`` — pre-route and en-route ADR 8.6.4 tunnel checks.
/// - ``NavigationEngine`` — turn-by-turn guidance over a computed route,
///   fed by any ``LocationProvider`` (``CoreLocationProvider`` live,
///   ``ReplayLocationProvider`` for QA corpora).
public enum MapMap {

    /// Eagerly verify that the bindings match the linked native core.
    ///
    /// Calling this is optional — the first native call performs the same
    /// UniFFI contract check lazily — but doing it at app start surfaces
    /// packaging problems (mismatched binding checksums, wrong framework
    /// slice) as an immediate, attributable crash instead of a mid-drive
    /// one.
    public static func ensureLoaded() {
        uniffiEnsureSnNavCoreInitialized()
        uniffiEnsureFerrostarInitialized()
    }

    /// A ``GuidanceConfig`` with the core's documented defaults.
    public static func defaultGuidanceConfig() -> GuidanceConfig {
        GuidanceConfig()
    }

    /// An ``AdrProfile`` with the core's documented defaults: EU maximum
    /// authorised dimensions (Council Directive 96/53/EC), no dangerous
    /// goods.
    public static func defaultAdrProfile() -> AdrProfile {
        AdrProfile()
    }
}

/// Errors raised by the Swift layer itself, before a call ever crosses
/// into the Rust core (which throws ``NavCoreError``).
public enum MapMapKitError: Error, Equatable, LocalizedError {
    /// An ADR profile was supplied with a costing model other than
    /// ``CostingModel/truck``.
    case incompatibleCosting(costing: CostingModel)
    /// A caller-supplied argument failed Swift-side validation.
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .incompatibleCosting(let costing):
            return "ADR profiles require CostingModel.truck (got \(costing)); "
                + "dimensional and tunnel restrictions are truck costing options"
        case .invalidArgument(let message):
            return message
        }
    }
}
