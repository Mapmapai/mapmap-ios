import CarPlay
import UIKit

/// Mitigation for a known MapLibre Native iOS bug class: the renderer
/// computes its display scale from `UIScreen.main` rather than the screen
/// the map view is actually attached to
/// (https://github.com/maplibre/maplibre-native/issues/3214). On CarPlay
/// that produces the wrong pixel density — usually oversized or blurry
/// labels/icons — because `CPWindow.screen` is very rarely the same
/// `UIScreen` as the phone's.
///
/// This mirrors the approach Organic Maps' CarPlay integration uses
/// (`CarPlayWindowScaleAdjuster` — compare the two screens' native scales
/// and adjust the visual scale the map is told to render at): MapMap
/// is headless, so it cannot reach into the host's MapLibre view directly,
/// but this computes the correction factor and hands it to the host to
/// apply to their own map view (e.g. as a style zoom-level offset, or by
/// overriding the scale MapLibre reads if their integration exposes that
/// hook).
///
/// Usage: create this **after** the `CPWindow` has attached (see
/// ``CarPlayManager``'s connect flow — never before, the window has no
/// `screen` until then), and again on `contentStyleDidChange`/on every
/// reattach, since a CarPlay unit can be swapped or reconnected with a
/// different physical display mid-session.
public struct CarPlayWindowScaleAdjuster: Sendable {

    /// The native scale (points → pixels) of the screen the CarPlay
    /// window is actually presented on.
    public let carScreenNativeScale: CGFloat

    /// The native scale of the phone's own main screen — what MapLibre
    /// Native (pre-fix) actually renders at regardless of which screen
    /// the view is attached to.
    public let phoneScreenNativeScale: CGFloat

    /// Multiply MapLibre's reported/assumed scale by this to get the
    /// scale the CarPlay screen actually needs. `1.0` when the two
    /// screens happen to share a native scale (nothing to correct) or
    /// when the phone's scale could not be determined.
    public var correctionFactor: CGFloat {
        guard phoneScreenNativeScale > 0 else { return 1.0 }
        return carScreenNativeScale / phoneScreenNativeScale
    }

    /// - Parameters:
    ///   - carWindow: the `CPWindow` supplied by
    ///     `CPTemplateApplicationSceneDelegate.templateApplicationScene(_:didConnectInterfaceController:toWindow:)`.
    ///     Must already be attached to its scene (has a non-default `screen`).
    ///   - phoneScreen: the phone's own main screen. Defaults to
    ///     `UIScreen.main` — the same value MapLibre Native reads
    ///     internally, which is exactly what needs correcting for.
    public init(carWindow: CPWindow, phoneScreen: UIScreen = .main) {
        carScreenNativeScale = carWindow.screen.nativeScale
        phoneScreenNativeScale = phoneScreen.nativeScale
    }

    /// Apply the correction to a view's `contentScaleFactor` directly.
    /// Suitable for plain `UIView`/`CALayer`-backed renderers; MapLibre's
    /// `MLNMapView` (or a MapLibre-Metal view) may need the factor applied
    /// through its own API instead if it manages scale itself — check
    /// your MapLibre version's CarPlay notes before relying on this
    /// shortcut.
    public func applyToContentScale(of view: UIView) {
        view.contentScaleFactor = carScreenNativeScale
    }
}
