import CarPlay
import Foundation
import MapMapKit

/// Converts MapMap's OSRM-style ``LaneGuidance`` (direction strings, e.g.
/// `"left"`, `"straight"`, `"slight right"`) into CarPlay's angle-based
/// `CPLane`/`CPLaneGuidance` (iOS 17.4+, and the non-deprecated `CPLane`
/// initializer only from iOS 18.0).
///
/// This is a best-effort approximation, not a port: OSRM lane directions
/// are discrete buckets, not measured angles, so each bucket is mapped to
/// a representative angle (straight ahead = 0°, clockwise positive,
/// mirroring `CPTrafficSide.right`'s convention in `CPManeuver.h`). Host
/// apps with more precise lane geometry (e.g. from their own map data) can
/// bypass this and build `CPLaneGuidance` directly.
public enum CPLaneGuidanceConverter {

    /// Representative angle in degrees for one OSRM lane direction bucket.
    /// Unrecognised directions fall back to straight ahead (0°) rather
    /// than being dropped, so a lane is never silently omitted from the
    /// diagram.
    static func angleDegrees(forDirection direction: String) -> Double {
        switch direction {
        case "sharp left": return -120
        case "left": return -90
        case "slight left": return -45
        case "straight": return 0
        case "slight right": return 45
        case "right": return 90
        case "sharp right": return 120
        case "uturn": return 180
        default: return 0
        }
    }

    @available(iOS 18.0, *)
    private static func lane(from guidance: LaneGuidance) -> CPLane {
        let angles = guidance.directions.map {
            Measurement(value: angleDegrees(forDirection: $0), unit: UnitAngle.degrees)
        }
        guard guidance.active, !angles.isEmpty else {
            return CPLane(angles: angles.isEmpty
                ? [Measurement(value: 0, unit: UnitAngle.degrees)]
                : angles)
        }
        let highlightDegrees = guidance.activeDirection.map(angleDegrees(forDirection:))
            ?? angleDegrees(forDirection: guidance.directions.first ?? "straight")
        let highlighted = Measurement(value: highlightDegrees, unit: UnitAngle.degrees)
        let remaining = angles.filter { $0 != highlighted }
        return CPLane(angles: remaining, highlightedAngle: highlighted, isPreferred: true)
    }

    /// Build a `CPLaneGuidance` from a sub ``BannerLine``'s lane diagram.
    /// Returns `nil` below iOS 18 (no non-deprecated `CPLane` initializer)
    /// or when there are no lanes to show.
    @available(iOS 18.0, *)
    public static func laneGuidance(for bannerLine: BannerLine) -> CPLaneGuidance? {
        guard !bannerLine.lanes.isEmpty else { return nil }
        let guidance = CPLaneGuidance()
        guidance.lanes = bannerLine.lanes.map(lane(from:))
        guidance.instructionVariants = [bannerLine.text]
        return guidance
    }
}
