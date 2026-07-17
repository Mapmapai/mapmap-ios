import Foundation

/// One guidance emission: the fix that produced it plus the core's
/// verdict.
///
/// ``GuidanceUpdate`` is the Rust core's state — `navigating`, `arrived`
/// or `offRoute` — and the single source of truth. This wrapper only adds
/// the triggering sample and display conveniences.
public struct NavigationState: Equatable, Sendable {
    public let fix: LocationSample
    public let update: GuidanceUpdate

    public init(fix: LocationSample, update: GuidanceUpdate) {
        self.fix = fix
        self.update = update
    }

    /// True once the core reports arrival at the destination.
    public var isArrived: Bool {
        if case .arrived = update { return true }
        return false
    }

    /// True when the user has left the route entirely and the app should
    /// request a recalculation (build a new route + ``NavigationEngine``).
    public var needsReroute: Bool {
        if case .offRoute = update { return true }
        return false
    }
}

/// Pure display mappers for ``GuidanceUpdate``. Kept free of native calls
/// so they are unit-testable anywhere.
public enum GuidanceDisplay {

    /// The instruction to show for the current update, if any.
    public static func instruction(_ update: GuidanceUpdate) -> String? {
        switch update {
        case .navigating(_, _, _, _, let currentInstruction, _, _, _, _, _):
            return currentInstruction
        case .arrived, .offRoute:
            return nil
        }
    }

    /// The visual banner for the upcoming manoeuvre, when one is active
    /// at the current distance (primary/secondary/sub lines with lane
    /// diagrams; render `primary.text` with the arrow named by
    /// `primary.maneuverType`/`maneuverModifier`).
    public static func visualBanner(_ update: GuidanceUpdate) -> VisualBanner? {
        switch update {
        case .navigating(_, _, _, _, _, _, let visual, _, _, _):
            return visual
        case .arrived, .offRoute:
            return nil
        }
    }

    /// The spoken prompt currently due. Hand `ssml ?? text` to
    /// `AVSpeechSynthesizer`, and de-duplicate by `utteranceId` — the same
    /// prompt is reported on every update until it is superseded.
    public static func spokenPrompt(_ update: GuidanceUpdate) -> SpokenPrompt? {
        switch update {
        case .navigating(_, _, _, _, _, _, _, let spoken, _, _):
            return spoken
        case .arrived, .offRoute:
            return nil
        }
    }

    /// How urgently the update should be surfaced (see the core's
    /// `InstructionSeverity` for the derivation). Off-route is a
    /// `.warning` — the driver has left the route and a recalculation is
    /// due; arrival is routine.
    public static func severity(_ update: GuidanceUpdate) -> InstructionSeverity {
        switch update {
        case .navigating(_, _, _, _, _, _, _, _, _, let severity):
            return severity
        case .arrived:
            return .info
        case .offRoute:
            return .warning
        }
    }

    /// The route-snapped position and course for the current update, if
    /// any. Drive follow-cameras from this — e.g. feed it into a
    /// MapLibre course-tracking camera (`MapViewCamera.automotiveNavigation()`
    /// style: course-up, zoom 16, pitch 45) — never the raw fix, which
    /// jitters and drifts off the carriageway.
    public static func snappedFix(_ update: GuidanceUpdate) -> SnappedFix? {
        switch update {
        case .navigating(_, _, _, _, _, _, _, _, let snapped, _):
            return snapped
        case .arrived, .offRoute:
            return nil
        }
    }

    /// Format a distance in metres for guidance display: metres under
    /// 1 km (10 m steps under 100 m, 50 m steps above), kilometres with
    /// one decimal from 1 km.
    public static func formatDistance(_ metres: Double) -> String {
        precondition(
            metres.isFinite && metres >= 0.0,
            "distance must be finite and >= 0, got \(metres)")
        switch metres {
        case ..<100.0:
            return "\(Int((metres / 10.0).rounded()) * 10) m"
        case ..<1_000.0:
            return "\(Int((metres / 50.0).rounded()) * 50) m"
        default:
            return String(format: "%.1f km", locale: Locale(identifier: "en_US_POSIX"),
                          metres / 1_000.0)
        }
    }

    /// One-line status suitable for a debug HUD or live activity.
    public static func summarise(_ update: GuidanceUpdate) -> String {
        switch update {
        case .navigating(
            _, let distanceToNextManeuverM, let distanceRemainingM, _,
            let currentInstruction, _, _, _, _, _):
            return "\(currentInstruction) — "
                + "\(formatDistance(distanceToNextManeuverM)) to manoeuvre, "
                + "\(formatDistance(distanceRemainingM)) remaining"
        case .arrived:
            return "Arrived at destination"
        case .offRoute(let deviationM):
            return "Off route by \(formatDistance(deviationM)) — recalculating required"
        }
    }
}
