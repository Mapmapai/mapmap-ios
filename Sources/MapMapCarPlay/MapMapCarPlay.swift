import CarPlay
import Foundation

/// CarPlay turn-by-turn support for the MapMap iOS SDK.
///
/// `MapMapCarPlay` is a thin adapter layer: it converts ``NavigationEngine``
/// output (``NavigationState``/``GuidanceUpdate``, ``VisualBanner``,
/// ``SpokenPrompt``, ``SpeedLimit``) into CarPlay's own vocabulary
/// (`CPTrip`, `CPManeuver`, `CPTravelEstimates`, `CPNavigationSession`), and
/// provides ``CarPlayManager`` — an orchestrator that owns the `CPMapTemplate`
/// root and the scene lifecycle so host apps don't have to reimplement it.
///
/// The SDK stays headless here too: MapMapCarPlay never creates a map
/// renderer. The host app supplies its own MapLibre view (or any other
/// `UIViewController`) through ``CarPlayManagerDelegate/carPlayManager(_:mapViewControllerFor:)``,
/// and ``CarPlayManager`` only handles the CarPlay-specific scaffolding
/// around it (window attachment timing, screen-scale correction, template
/// stack, navigation-session lifecycle).
///
/// ## Layout
///
/// - ``CarPlayManager`` — the `CPTemplateApplicationSceneDelegate`-facing
///   orchestrator: browse → preview → navigate → stop activity states, the
///   `CPMapTemplate` + its delegate, and the active `CPNavigationSession`.
/// - ``CarPlayManagerDelegate`` — host hooks: supply the map view
///   controller, customise map buttons, observe camera gestures.
/// - `CPTrip`, `CPManeuver`, `CPTravelEstimates` converters (this module's
///   `Models/` directory) — pure value conversions from MapMap's FFI types.
/// - ``CarPlayWindowScaleAdjuster`` — mitigation for the CarPlay-screen
///   scale bug class (MapLibre Native computes scale from
///   `UIScreen.main`, not the CarPlay screen — maplibre-native#3214).
/// - ``CarPlayAudioSession`` — the exact `AVAudioSession` configuration
///   voice prompts need on CarPlay.
/// - `ExampleCarPlaySceneDelegate.swift` — a compiled, heavily-commented
///   integration example: Info.plist scene manifest keys, the
///   `com.apple.developer.carplay-maps` entitlement, and the connect flow.
///
/// ## Attribution
///
/// Several converters in this module are ported from Ferrostar's
/// `FerrostarCarPlayUI` (https://github.com/stadiamaps/ferrostar/tree/main/apple/Sources/FerrostarCarPlayUI,
/// © Stadia Maps, Inc., BSD-3-Clause — the same licence already recorded
/// for the pinned Ferrostar Rust crate in `THIRD-PARTY-NOTICES.md`) —
/// individual files carry a header noting what was ported. **No Ferrostar
/// Swift package is linked**: everything here binds against MapMapKit's
/// own generated types, per the "Ferrostar boundary" in ios/README.md —
/// linking `FerrostarCarPlayUI` directly would pull in Ferrostar's own
/// copy of the Rust core, duplicating `sn_nav_core`.
public enum MapMapCarPlay {

    /// The CarPlay entitlement identifier apps must request from Apple
    /// (see "Requesting CarPlay Entitlements",
    /// https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
    /// before this module's scenes can connect on a real head unit or in
    /// the CarPlay Simulator. Exposed as a constant so host apps can
    /// reference it (e.g. in onboarding copy) without retyping it.
    public static let requiredEntitlement = "com.apple.developer.carplay-maps"
}
