import CarPlay
import MapMapKit
import UIKit

/// Orchestrates one CarPlay connection end-to-end: the `CPMapTemplate`
/// root and its delegate, the browse → preview → navigate activity states,
/// and the active `CPNavigationSession`'s lifecycle.
///
/// This is the class Mapbox's Navigation SDK ships
/// (`CarPlayManager`/`CarPlayManagerDelegate`) and that Ferrostar's own
/// docs point to as a gap in `FerrostarCarPlayUI` — Ferrostar leaves this
/// wiring to each app's demo code (see `DemoCarPlayModel.swift`). MapMap
/// ships it as SDK surface instead: host apps forward their
/// `CPTemplateApplicationSceneDelegate` callbacks to
/// ``sceneConnected(interfaceController:window:)``/``sceneDisconnected(interfaceController:)``
/// and implement ``CarPlayManagerDelegate`` for the parts that are
/// necessarily app-specific (the map view, route selection, trip start).
///
/// Not a port of any Ferrostar source — this orchestration layer does not
/// exist in `FerrostarCarPlayUI`. See `ExampleCarPlaySceneDelegate.swift`
/// for the exact scene-delegate wiring.
@MainActor
public final class CarPlayManager: NSObject {

    /// `true` from init until ``sceneConnected(interfaceController:window:)``
    /// has run once. CarPlay scene callbacks are not guaranteed to arrive
    /// in the order you'd expect — iOS 18.5 has been observed delivering
    /// `sceneWillEnterForeground` on the CarPlay scene *before*
    /// `didConnectInterfaceController:toWindow:` — so anything that needs
    /// `interfaceController`/`window`/`mapTemplate` must check this (or
    /// simply rely on those properties being `nil`) rather than assume
    /// connection has completed just because *some* scene callback fired.
    /// This mirrors OsmAnd's CarPlay `isWaitingForConfiguration` pattern.
    public private(set) var isWaitingForConfiguration = true

    public private(set) var interfaceController: CPInterfaceController?
    public private(set) var carWindow: CPWindow?
    public private(set) var mapTemplate: CPMapTemplate?
    public private(set) var scaleAdjuster: CarPlayWindowScaleAdjuster?
    public private(set) var activity: CarPlayActivity = .browsing

    /// The active navigation session, when ``activity`` is `.navigating`.
    /// Held here (not duplicated by the delegate/host) so there is exactly
    /// one owner of the CarPlay-side trip lifecycle, per the platform note
    /// that duplicate references to the same session are a common source
    /// of "which copy is authoritative" bugs.
    public private(set) var navigationSession: CPNavigationSession?

    /// The CarPlay-suggested UI limits (keyboard/list availability) and
    /// content style (light/dark), kept live via `CPSessionConfigurationDelegate`.
    /// Consult `sessionConfiguration.limitedUserInterfaces` before
    /// presenting anything keyboard-driven (e.g. a `CPSearchTemplate`) —
    /// CarPlay screens without a keyboard input (many aftermarket and
    /// built-in units) will otherwise dead-end the driver. This SDK does
    /// not ship a search template itself; if you add one, gate it on this.
    public private(set) var sessionConfiguration: CPSessionConfiguration?

    public weak var delegate: CarPlayManagerDelegate?

    public override init() {
        super.init()
    }

    // MARK: - Scene lifecycle
    //
    // Call these from your `CPTemplateApplicationSceneDelegate`
    // (see `ExampleCarPlaySceneDelegate.swift`).

    /// Forward `templateApplicationScene(_:didConnectInterfaceController:toWindow:)`
    /// here. Creates the root `CPMapTemplate`, sets it as the scene's root
    /// template, and — only once `window` is actually attached to its
    /// scene — asks the delegate for a map view controller. Creating a
    /// MapLibre view before the window attaches is a known blank-map/crash
    /// bug class (the view has no real drawable size yet); this ordering
    /// is why the delegate callback happens here and not in `init`.
    public func sceneConnected(interfaceController: CPInterfaceController, window: CPWindow) {
        self.interfaceController = interfaceController
        carWindow = window
        isWaitingForConfiguration = false

        let adjuster = CarPlayWindowScaleAdjuster(carWindow: window)
        scaleAdjuster = adjuster

        sessionConfiguration = CPSessionConfiguration(delegate: self)

        if let delegate {
            let mapViewController = delegate.carPlayManager(self, mapViewControllerFor: window, scaleAdjuster: adjuster)
            window.rootViewController = mapViewController
        }
        window.makeKeyAndVisible()

        let template = CPMapTemplate()
        template.mapDelegate = self
        applyActivity(.browsing, to: template)
        mapTemplate = template

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await interfaceController.setRootTemplate(template, animated: true)
            } catch {
                // Nothing sensible to retry here — the interface
                // controller itself failed to accept a root template.
                // Surfacing this as a thrown error would have no
                // catcher (scene delegate callbacks don't throw), so
                // apps that care should watch for a stuck black screen
                // in their own CarPlay QA rather than rely on this path.
            }
        }
    }

    /// Forward `templateApplicationScene(_:didDisconnectInterfaceController:fromWindow:)`
    /// (or the window-less variant) here. Ends any active trip and
    /// releases everything scoped to the connection.
    public func sceneDisconnected() {
        if navigationSession != nil {
            stopTrip(cancelled: true)
        }
        Self.releaseCarWindow(carWindow)
        interfaceController = nil
        carWindow = nil
        mapTemplate = nil
        scaleAdjuster = nil
        sessionConfiguration = nil
        isWaitingForConfiguration = true
        activity = .browsing
    }

    /// Hand the car window back on disconnect.
    ///
    /// Clearing `rootViewController` is the part that was missing: the
    /// window handed to ``sceneConnected(interfaceController:window:)``
    /// outlives the connection (CarPlay may hand the same `CPWindow` back
    /// on reconnect), so a window still holding the old map view
    /// controller keeps that controller — and everything it owns, a
    /// MapLibre renderer and any display link included — alive after the
    /// head unit is gone.
    ///
    /// Split out from ``sceneDisconnected()`` because `CPInterfaceController`
    /// cannot be constructed outside a real CarPlay scene, so this is the
    /// only part of the teardown a unit test can drive.
    static func releaseCarWindow(_ window: CPWindow?) {
        guard let window else { return }
        window.isHidden = true
        window.rootViewController = nil
    }

    // MARK: - Trip flow

    /// Show a route-choice preview for `trip` (`CPMapTemplate.showRouteChoicesPreview`).
    /// Call once route(s) have been computed for a chosen destination.
    public func previewRoutes(for trip: CPTrip, textConfiguration: CPTripPreviewTextConfiguration? = nil) {
        guard let mapTemplate else { return }
        activity = .previewingRoutes
        applyActivity(activity, to: mapTemplate)
        mapTemplate.showRouteChoicesPreview(for: trip, textConfiguration: textConfiguration)
    }

    /// Start guidance for `routeChoice`. Ends any previous session first —
    /// there is only ever one active ``navigationSession``.
    @discardableResult
    public func startTrip(_ trip: CPTrip, using routeChoice: CPRouteChoice) -> CPNavigationSession? {
        guard let mapTemplate else { return nil }
        if navigationSession != nil {
            stopTrip(cancelled: false)
        }
        mapTemplate.hideTripPreviews()
        let session = mapTemplate.startNavigationSession(for: trip)
        navigationSession = session
        activity = .navigating(trip: trip)
        applyActivity(activity, to: mapTemplate)
        delegate?.carPlayManager(self, didStartTrip: trip, using: routeChoice)
        return session
    }

    /// Push the latest ``NavigationState`` from your ``NavigationEngine``
    /// onto the active session. No-op if there is no active trip.
    public func updateNavigationState(
        _ state: NavigationState,
        units: CarPlayDistanceUnits = .localeDefault,
        locale: Locale = .current
    ) {
        guard let session = navigationSession, let mapTemplate else { return }
        state.refreshCarPlay(session: session, mapTemplate: mapTemplate, units: units, locale: locale)
    }

    /// End the active trip, if any.
    ///
    /// - Parameter cancelled: `true` for a driver/system cancellation
    ///   (`cancelTrip()`); `false` for a normal finish, e.g. on arrival
    ///   (`finishTrip()`).
    public func stopTrip(cancelled: Bool) {
        guard let session = navigationSession, case .navigating(let trip) = activity else { return }
        if cancelled {
            session.cancelTrip()
        } else {
            session.finishTrip()
        }
        navigationSession = nil
        activity = .browsing
        if let mapTemplate {
            applyActivity(activity, to: mapTemplate)
        }
        delegate?.carPlayManager(self, didEndTrip: trip, cancelled: cancelled)
    }

    // MARK: - Template chrome

    private func applyActivity(_ activity: CarPlayActivity, to template: CPMapTemplate) {
        template.automaticallyHidesNavigationBar = false
        template.leadingNavigationBarButtons = delegate?.carPlayManager(self, leadingNavigationBarButtonsFor: activity) ?? []
        template.trailingNavigationBarButtons = delegate?.carPlayManager(self, trailingNavigationBarButtonsFor: activity) ?? []
        template.mapButtons = delegate?.carPlayManager(self, mapButtonsFor: activity) ?? []
    }

    /// Re-apply the current activity's chrome (buttons) — call after
    /// something that affects them changes (e.g. a mute toggle), since
    /// ``CarPlayManagerDelegate`` is asked fresh each time.
    public func refreshChrome() {
        guard let mapTemplate else { return }
        applyActivity(activity, to: mapTemplate)
    }
}

// MARK: - CPMapTemplateDelegate

extension CarPlayManager: CPMapTemplateDelegate {

    public func mapTemplate(
        _ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice
    ) {
        delegate?.carPlayManager(self, didSelectRouteChoice: routeChoice, for: trip)
    }

    public func mapTemplate(
        _ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice
    ) {
        startTrip(trip, using: routeChoice)
    }

    public func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        stopTrip(cancelled: true)
    }

    // MARK: iOS 26 multitouch gestures — forwarded to the delegate
    // unchanged, so a host's existing on-phone camera-gesture handling
    // can be reused for the CarPlay screen.

    @available(iOS 26.0, *)
    public func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdateZoomGestureWithCenter center: CGPoint, scale: CGFloat, velocity: CGFloat) {
        delegate?.carPlayManager(self, didUpdateZoomWithScale: scale, velocity: velocity)
    }

    @available(iOS 26.0, *)
    public func mapTemplate(_ mapTemplate: CPMapTemplate, didRotateWithCenter center: CGPoint, rotation: CGFloat, velocity: CGFloat) {
        delegate?.carPlayManager(self, didUpdateRotationWithRadians: rotation, velocity: velocity)
    }

    @available(iOS 26.0, *)
    public func mapTemplate(_ mapTemplate: CPMapTemplate, pitchWithCenter center: CGPoint) {
        delegate?.carPlayManager(self, didUpdatePitchAtCenter: center)
    }
}

// MARK: - CPSessionConfigurationDelegate

extension CarPlayManager: CPSessionConfigurationDelegate {

    public func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        self.sessionConfiguration = sessionConfiguration
    }

    public func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration, contentStyleChanged contentStyle: CPContentStyle
    ) {
        self.sessionConfiguration = sessionConfiguration
    }
}
