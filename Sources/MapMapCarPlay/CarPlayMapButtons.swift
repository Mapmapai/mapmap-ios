// Portions of this file are derived from Ferrostar's FerrostarCarPlayUI
// (apple/Sources/FerrostarCarPlayUI/CarPlayTemplate/CarPlayMapButtons.swift,
// https://github.com/stadiamaps/ferrostar), © Stadia Maps, Inc.,
// licensed under the BSD 3-Clause License. No Ferrostar Swift package is
// linked (see ios/README.md, "Ferrostar boundary").

import CarPlay
import UIKit

/// Ready-made `CPMapButton`s for the common navigation-app map controls.
/// Entirely optional — ``CarPlayManagerDelegate`` lets host apps supply
/// their own `mapButtons` array instead.
///
/// `CPMapButton` (like `CPMapTemplate`/`CPNavigationSession`) is
/// main-actor-isolated by the CarPlay framework itself
/// (`CARPLAY_TEMPLATE_UI_ACTOR` in `CPTemplate.h`), so this whole type is
/// `@MainActor`.
@MainActor
public enum CarPlayMapButtons {

    public static func zoomIn(action: @escaping () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in action() }
        button.image = UIImage(systemName: "plus.circle.fill")
        return button
    }

    public static func zoomOut(action: @escaping () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in action() }
        button.image = UIImage(systemName: "minus.circle.fill")
        return button
    }

    public static func recenter(action: @escaping () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in action() }
        button.image = UIImage(systemName: "location.fill")
        return button
    }

    public static func toggleMute(isMuted: Bool, action: @escaping () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in action() }
        button.image = UIImage(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        return button
    }

    public static func pan(action: @escaping () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in action() }
        button.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        return button
    }
}
