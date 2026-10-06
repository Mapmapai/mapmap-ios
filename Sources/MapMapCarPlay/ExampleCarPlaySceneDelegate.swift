import CarPlay
import MapMapKit
import UIKit

// MARK: - Host app integration checklist
//
// This file is compiled documentation: it always builds against
// MapMapCarPlay's real API surface (so it can't silently rot the way a
// standalone markdown snippet can), but `ExampleCarPlaySceneDelegate`
// itself is a template to copy into your **app** target, not something to
// ship as-is — it has no map view, search UI or destination picker,
// which are necessarily app-specific.
//
// 1. Info.plist — declare the CarPlay scene manifest (host app target):
//
//    <key>UIApplicationSceneManifest</key>
//    <dict>
//        <key>UIApplicationSupportsMultipleScenes</key>
//        <true/>
//        <key>UISceneConfigurations</key>
//        <dict>
//            <key>CPTemplateApplicationSceneSessionRoleApplication</key>
//            <array>
//                <dict>
//                    <key>UISceneConfigurationName</key>
//                    <string>CarPlay Configuration</string>
//                    <key>UISceneDelegateClassName</key>
//                    <string>$(PRODUCT_MODULE_NAME).YourCarPlaySceneDelegate</string>
//                </dict>
//            </array>
//        </dict>
//    </dict>
//
//    (Substitute your own scene delegate class name — a copy of
//    `ExampleCarPlaySceneDelegate` below, not this one directly.)
//
// 2. Entitlement — request `com.apple.developer.carplay-maps` from Apple
//    per https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements
//    (days to ~8 weeks lead time; a working, substantive iPhone app is
//    effectively required before applying — apply early). Once granted,
//    add it in Signing & Capabilities (or directly in your
//    `.entitlements` file):
//
//    <key>com.apple.developer.carplay-maps</key>
//    <true/>
//
//    ``MapMapCarPlay/requiredEntitlement`` holds this exact string as a
//    Swift constant (Info.plist/.entitlements are plain text, so it can't
//    be referenced from there — but it's handy for onboarding copy,
//    diagnostics, or asserting the entitlement is present before offering
//    a "Navigate on CarPlay" affordance).
//
// 3. Testing — the CarPlay Simulator (Xcode → Open Developer Tool →
//    Additional Tools for Xcode) is the serious tool; the entitlement
//    gates it too, including simulator-only testing. The Simulator app's
//    external-display CarPlay support is fine for quick smoke tests but
//    is not a substitute.

/// Example `CPTemplateApplicationSceneDelegate`: forwards scene connect/
/// disconnect straight to a ``CarPlayManager``. This is the entire
/// contract — everything else (template stack, activity states,
/// navigation session lifecycle) lives in the manager.
public final class ExampleCarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {

    private let carPlayManager = CarPlayManager()

    public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        carPlayManager.delegate = ExampleCarPlayManagerDelegate.shared
        carPlayManager.sceneConnected(interfaceController: interfaceController, window: window)
    }

    public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        carPlayManager.sceneDisconnected()
    }
}

/// Example ``CarPlayManagerDelegate``. Replace the map view controller and
/// wire real destination search / ``NavigationEngine`` calls in place of
/// the comments below.
@MainActor
final class ExampleCarPlayManagerDelegate: CarPlayManagerDelegate {
    static let shared = ExampleCarPlayManagerDelegate()

    func carPlayManager(
        _ manager: CarPlayManager,
        mapViewControllerFor window: CPWindow,
        scaleAdjuster: CarPlayWindowScaleAdjuster
    ) -> UIViewController {
        // Real integration: return your own MapLibre-backed view
        // controller here, e.g.
        //
        //   let vc = YourMapLibreCarPlayViewController(styleURL: styleURL)
        //   scaleAdjuster.applyToContentScale(of: vc.view)
        //   return vc
        //
        // `scaleAdjuster` corrects for the CarPlay screen-scale mismatch
        // MapLibre Native iOS is prone to (maplibre-native#3214) — apply
        // it as you configure the view, not after it has already laid
        // out. This factory is only called once `window` is attached to
        // its scene, so it is always safe to create the map view here
        // (creating one earlier is a known blank-map/crash bug class).
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = .black
        return placeholder
    }

    func carPlayManager(_ manager: CarPlayManager, mapButtonsFor activity: CarPlayActivity) -> [CPMapButton]? {
        switch activity {
        case .navigating:
            return [CarPlayMapButtons.toggleMute(isMuted: false) {
                // Real integration: toggle your AVSpeechSynthesizer /
                // however you're voicing SpokenPrompt.text, then call
                // manager.refreshChrome() so the icon updates.
            }]
        case .browsing, .previewingRoutes:
            return nil
        }
    }

    func carPlayManager(_ manager: CarPlayManager, didStartTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        guard routeChoice.mapMapRouteResult != nil else { return }
        // Real integration:
        //
        //   guard let route = routeChoice.mapMapRouteResult else { return }
        //   try? CarPlayAudioSession.configureForVoicePrompts()
        //   let engine = NavigationEngine(route: route)
        //   Task {
        //       for try await state in await engine.navigate(provider: CoreLocationProvider()) {
        //           manager.updateNavigationState(state)
        //           if state.isArrived {
        //               manager.stopTrip(cancelled: false)
        //               break
        //           }
        //           if state.needsReroute {
        //               // Compute a new route for the remaining waypoints
        //               // and start a fresh NavigationEngine — an engine
        //               // is bound to a single route.
        //           }
        //       }
        //   }
    }

    func carPlayManager(_ manager: CarPlayManager, didEndTrip trip: CPTrip, cancelled: Bool) {
        // Real integration: stop your NavigationEngine/location provider
        // and call `try? CarPlayAudioSession.deactivate()`.
    }
}
