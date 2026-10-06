import CarPlay
import UIKit

/// Where ``CarPlayManager`` currently is in the browse → preview →
/// navigate flow. Exposed so host apps can drive their own UI (e.g. a
/// phone-side "navigating on CarPlay" banner) off the same state machine.
public enum CarPlayActivity: Equatable, Sendable {
    /// Connected, no destination chosen yet — the map template is showing
    /// free browse (pan/zoom) with the host's custom buttons, if any.
    case browsing
    /// One or more ``RouteResult``s are being previewed
    /// (`showRouteChoicesPreview`) before the driver commits to one.
    case previewingRoutes
    /// A `CPNavigationSession` is active for the given trip.
    case navigating(trip: CPTrip)
}

/// Host app hooks for ``CarPlayManager``.
///
/// MapMapKit is headless everywhere, including here: ``CarPlayManager``
/// owns the CarPlay *chrome* (template stack, navigation session
/// lifecycle, screen-scale correction) but never renders a map itself.
/// The one piece of UI it cannot supply on the host's behalf is the map
/// view — that comes from ``carPlayManager(_:mapViewControllerFor:)``.
@MainActor
public protocol CarPlayManagerDelegate: AnyObject {

    /// Supply the view controller to place behind CarPlay's map template
    /// chrome — typically a thin wrapper around your own `MLNMapView`
    /// (MapLibre) instance, styled with `styleForNavigation(styleJson:)`.
    ///
    /// Called exactly once per connection, **after** `window` has already
    /// been attached to its `CPTemplateApplicationScene` (`window.screen`
    /// and `window.mapButtonSafeAreaLayoutGuide` are valid) — this is the
    /// point at which it is safe to create a MapLibre view. Creating one
    /// any earlier is a known crash/blank-map bug class in MapLibre Native
    /// iOS tied to the window not yet reporting a real drawable size.
    ///
    /// Use `scaleAdjuster` to correct for CarPlay's screen-scale
    /// mismatch (maplibre-native#3214) before or as you configure your
    /// map view's layer.
    func carPlayManager(
        _ manager: CarPlayManager,
        mapViewControllerFor window: CPWindow,
        scaleAdjuster: CarPlayWindowScaleAdjuster
    ) -> UIViewController

    /// Customise the map template's `mapButtons` for the current
    /// ``CarPlayActivity``. Return `nil` to keep whatever
    /// ``CarPlayManager`` last set (its default is empty — most apps will
    /// want to provide at least a mute toggle via ``CarPlayMapButtons``).
    func carPlayManager(
        _ manager: CarPlayManager,
        mapButtonsFor activity: CarPlayActivity
    ) -> [CPMapButton]?

    /// The trailing/leading navigation-bar buttons (e.g. "Cancel", "Go")
    /// for the current activity. Return `nil` to keep CarPlay's defaults
    /// (none).
    func carPlayManager(
        _ manager: CarPlayManager,
        leadingNavigationBarButtonsFor activity: CarPlayActivity
    ) -> [CPBarButton]?

    func carPlayManager(
        _ manager: CarPlayManager,
        trailingNavigationBarButtonsFor activity: CarPlayActivity
    ) -> [CPBarButton]?

    /// The driver picked a route to preview/select. Most apps will store
    /// `routeChoice.mapMapRouteResult` and, once the driver taps "Go"
    /// (``carPlayManager(_:didStartTrip:using:)``), build a
    /// ``NavigationEngine`` from it.
    func carPlayManager(
        _ manager: CarPlayManager,
        didSelectRouteChoice routeChoice: CPRouteChoice,
        for trip: CPTrip
    )

    /// The driver committed to navigating `routeChoice`. Start your
    /// ``NavigationEngine`` here and feed its states back through
    /// ``CarPlayManager/updateNavigationState(_:)`` on every tick.
    func carPlayManager(
        _ manager: CarPlayManager,
        didStartTrip trip: CPTrip,
        using routeChoice: CPRouteChoice
    )

    /// The trip ended — either the driver/system cancelled it
    /// (`cancelled == true`, e.g. `mapTemplateDidCancelNavigation`) or your
    /// own code called ``CarPlayManager/stopTrip(cancelled:)`` (e.g. on
    /// arrival). Stop your ``NavigationEngine`` here.
    func carPlayManager(_ manager: CarPlayManager, didEndTrip trip: CPTrip, cancelled: Bool)

    // MARK: - iOS 26 multitouch gestures
    //
    // CPMapTemplateDelegate gained direct pinch/rotate/pitch callbacks in
    // iOS 26 (`CPMapTemplate.h`: `mapTemplate(_:didUpdateZoomGestureWithCenter:scale:velocity:)`
    // and the rotation/pitch equivalents). CarPlayManager forwards them
    // here unchanged so host apps can drive their map camera the same way
    // they already handle on-phone pinch/rotate/pitch gestures — these are
    // all optional (default no-ops) since a pre-26 host that only wants
    // pan/zoom buttons has nothing to implement.

    @available(iOS 26.0, *)
    func carPlayManager(_ manager: CarPlayManager, didUpdateZoomWithScale scale: CGFloat, velocity: CGFloat)

    @available(iOS 26.0, *)
    func carPlayManager(_ manager: CarPlayManager, didUpdateRotationWithRadians radians: CGFloat, velocity: CGFloat)

    @available(iOS 26.0, *)
    func carPlayManager(_ manager: CarPlayManager, didUpdatePitchAtCenter center: CGPoint)
}

/// Default (no-op) implementations for everything except the map view
/// factory, so a minimal integration only has to implement one method.
extension CarPlayManagerDelegate {
    public func carPlayManager(_ manager: CarPlayManager, mapButtonsFor activity: CarPlayActivity) -> [CPMapButton]? { nil }
    public func carPlayManager(_ manager: CarPlayManager, leadingNavigationBarButtonsFor activity: CarPlayActivity) -> [CPBarButton]? { nil }
    public func carPlayManager(_ manager: CarPlayManager, trailingNavigationBarButtonsFor activity: CarPlayActivity) -> [CPBarButton]? { nil }
    public func carPlayManager(_ manager: CarPlayManager, didSelectRouteChoice routeChoice: CPRouteChoice, for trip: CPTrip) {}
    public func carPlayManager(_ manager: CarPlayManager, didStartTrip trip: CPTrip, using routeChoice: CPRouteChoice) {}
    public func carPlayManager(_ manager: CarPlayManager, didEndTrip trip: CPTrip, cancelled: Bool) {}

    @available(iOS 26.0, *)
    public func carPlayManager(_ manager: CarPlayManager, didUpdateZoomWithScale scale: CGFloat, velocity: CGFloat) {}
    @available(iOS 26.0, *)
    public func carPlayManager(_ manager: CarPlayManager, didUpdateRotationWithRadians radians: CGFloat, velocity: CGFloat) {}
    @available(iOS 26.0, *)
    public func carPlayManager(_ manager: CarPlayManager, didUpdatePitchAtCenter center: CGPoint) {}
}
