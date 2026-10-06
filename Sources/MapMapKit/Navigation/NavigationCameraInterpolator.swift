import CoreLocation
import Foundation

/// Turns a ~1 Hz stream of guidance fixes into a value that can be sampled
/// on every display frame, so a follow camera moves continuously instead of
/// stepping once per fix.
///
/// ## Why this type exists
///
/// Guidance fixes arrive at roughly 1 Hz (the replay corpora and Core
/// Location both). Driving a map camera straight off them looks jerky in two
/// distinct ways, and only one of them is fixed by easing:
///
/// 1. **Per-tick easing.** Kicking off one animation per fix (MapLibre's
///    `easeTo`/`setCamera(_:withDuration:)`) hands the camera a new target
///    while the previous animation is still running. Each new animation
///    restarts from wherever the last one had got to, with its own easing
///    curve, so the velocity resets 1x/second — visible as a pulse.
/// 2. **Two clocks.** Animating a *map-anchored* puck while the camera is
///    itself animating gives the scene two independent clocks that drift
///    against each other. That desync is the "stutters back and forth,
///    worse at low zoom" bug already diagnosed and fixed in the MapMapNav
///    app (see `src/screens/guidance/ChaseLayer.tsx`, whose fix — camera
///    only, puck as a fixed screen overlay — this iOS work mirrors).
///
/// This type addresses (1): the host samples it from a `CADisplayLink` and
/// applies the result to the map with **no** animation, so the frame clock
/// is the only clock. (2) is addressed by the host drawing the puck as a
/// fixed overlay at the camera focal point.
///
/// There is a third way for this to look wrong, and ``setRoute(coordinates:)``
/// is the answer to it: interpolating in a straight line between two fixes
/// a second apart **cuts corners**, so through a bend the vehicle drifts
/// off the road and back on. Given the route, the interpolation runs in arc
/// length along it and every position reported is a point of the route.
///
/// ## Presentation lag (deliberate)
///
/// ``state(at:)`` reports where the vehicle was one fix-interval ago. That
/// lag is what lets it *interpolate between two known fixes* rather than
/// guess ahead of the newest one, and it is what makes the motion
/// continuous: the sample reaches fix *N* exactly as fix *N+1* lands, and
/// the next segment starts from that same point.
///
/// This is not a new trade-off. The approved MapMapNav chase camera has the
/// identical lag by construction — `ChaseLayer` eases to each fix over a
/// duration equal to the gap since the previous one, so its camera also
/// arrives at fix *N* as fix *N+1* appears. The difference here is only that
/// a frame clock replaces one animation per tick.
///
/// Guidance text, distances and ETA are *not* lagged: they come straight
/// from the engine tick. Only the camera geometry is interpolated.
///
/// ## Clock
///
/// The type is clock-agnostic: `timestamp` is whatever monotonic seconds the
/// host feeds, and ``state(at:)`` must be queried on the same clock. Hosts
/// should feed the **arrival** time of each fix (`CACurrentMediaTime()`),
/// not the fix's own `timestampMs`: arrival time is what the extrapolation
/// cap needs to reason about, and it stays correct when a replay runs at a
/// time scale (`ReplayLocationProvider(timeScale:)`) or when fixes are
/// delivered late.
///
/// Pure value type: no UIKit, no MapLibre, no CarPlay, so it builds and is
/// tested on the macOS host path (`MAPMAP_HOST_CORE=1 swift test`) as well
/// as on iOS.
public struct NavigationCameraInterpolator: Sendable {

    // MARK: - Tuning

    /// Per-fix low-pass factor for the camera bearing (0…1; lower is
    /// smoother and laggier).
    ///
    /// 0.35, taken verbatim from `BEARING_SMOOTH_ALPHA` in MapMapNav's
    /// `src/screens/guidance/GuidanceScreen.tsx`, where it is the value
    /// proven on device: enough damping that a noisy heading or a sharp
    /// corner does not whip the map, tight enough that the camera still
    /// tracks the corner.
    public static let bearingSmoothAlpha: Double = 0.35

    /// Below this speed the reported course is noise, so the smoothed
    /// bearing is frozen rather than followed.
    ///
    /// 0.5 m/s is the same standstill threshold MapMapNav uses to decide a
    /// fix is not moving (`speedMps > 0.5` in `state/guidance/routeProgress.ts`
    /// and `state/guidance/fasterRoute.ts`). A stationary vehicle's course
    /// wanders over the whole compass; following it spins the map on the
    /// spot.
    public static let standstillSpeedMps: Double = 0.5

    /// Ceiling on the interpolation parameter: 1.0 is the newest fix, so
    /// 1.5 is **half an interval past** it, and beyond that the value holds
    /// still.
    ///
    /// A late fix should not freeze the camera dead, but neither should a
    /// stalled feed send it gliding away — the further it runs on a guess,
    /// the bigger the snap back when the truth lands. Half an interval
    /// absorbs ordinary jitter without ever overshooting far enough to see.
    /// Same value and same semantics as the Android side's
    /// `EXTRAPOLATION_CAP`.
    public static let extrapolationCap: Double = 1.5

    /// The measured inter-fix interval is clamped to this range before it
    /// paces anything, so one absurd gap (a suspended app, a debugger
    /// pause) cannot make the camera crawl or bolt. Ceiling mirrors the
    /// 1400 ms clamp MapMapNav's `ChaseLayer` puts on its per-fix ease
    /// duration; the floor sits at 100 ms (below MapMapNav's 140 ms) so
    /// the demo's 8x replay cadence of 125 ms interpolates instead of
    /// binding on the clamp, which left a residual fix-interval stutter.
    /// The Android side mirrors both bounds.
    public static let minFixInterval: TimeInterval = 0.10
    public static let maxFixInterval: TimeInterval = 1.4

    /// Assumed interval before two fixes have been seen (fixes are ~1 Hz),
    /// and the value the pacing window is seeded with.
    ///
    /// Seeding matters: with an empty window a single burst gap would *be*
    /// the median and collapse the pace to the floor.
    public static let nominalFixInterval: TimeInterval = 1.0

    /// How many recent inter-fix gaps the **pacing interval** is the
    /// median of — the Android side's `INTERVAL_WINDOW`.
    ///
    /// Three is the smallest window with a median at all, and it is
    /// enough: one anomalous gap (a burst of two fixes 40 ms apart, a
    /// single late one) is outvoted by its two neighbours, while a genuine
    /// change of cadence — the demo's 8x replay, a provider switching rate
    /// — is adopted after two fixes rather than being damped away. Larger
    /// windows only add lag to that adoption.
    public static let intervalWindow: Int = 3

    /// How far off the route a fix may project and still be treated as
    /// on it, in metres — the Android side's `OFF_ROUTE_LATERAL_M`.
    ///
    /// The fix a follow camera should be fed is already route-snapped
    /// (`GuidanceDisplay.snappedFix`), so on-route projections land within
    /// centimetres; this only has to be wide enough for a raw fix on the
    /// carriageway and tight enough that a genuine excursion (a wrong turn,
    /// a parallel service road) stops pretending to be on the route.
    public static let onRouteToleranceM: Double = 25

    /// Half-width, in metres, of the window the route tangent is measured
    /// over — the Android side's `TANGENT_WINDOW_M`.
    ///
    /// Taking the tangent from a single polyline segment makes a
    /// right-angle corner flip the bearing over a couple of metres, which
    /// on a course-up camera is a snap. Measuring it as the chord across
    /// ±15 m spreads that turn over 30 m of driving instead.
    ///
    /// Note this smoothing is **spatial, not temporal**: a route-derived
    /// bearing gets no exponential filter on top of it. The wobble that
    /// filter exists for — noisy per-fix course — is not in the route
    /// geometry, and a distance-based window makes the corner look the
    /// same at any speed, which is what lets the two platforms match.
    public static let tangentWindowM: Double = 15

    // MARK: - State

    private struct Sample {
        var coordinate: CLLocationCoordinate2D
        /// Low-passed bearing as of this fix (degrees, `[0, 360)`).
        var bearingDeg: Double
        var timestamp: TimeInterval
        /// Distance along the route this fix projects to, in metres —
        /// `nil` when there is no route or the fix is off it.
        var alongM: Double?

        /// The same fix, map-matched against `geometry` instead of
        /// whatever route was current when it arrived.
        func reSnapped(onto geometry: Route?) -> Sample {
            var copy = self
            copy.alongM = geometry?.matchedAlongM(coordinate)
            return copy
        }
    }

    private var previous: Sample?
    private var latest: Sample?
    private var route: Route?

    /// The last ``intervalWindow`` clamped inter-fix gaps, as a ring
    /// buffer. Seeded with ``nominalFixInterval`` so the pace starts at
    /// the nominal 1 Hz cadence and a single anomalous gap can never
    /// become the median.
    private var recentIntervals =
        [TimeInterval](repeating: NavigationCameraInterpolator.nominalFixInterval,
                       count: NavigationCameraInterpolator.intervalWindow)
    private var intervalCursor = 0

    /// Median of ``recentIntervals`` — the interval the interpolation
    /// parameter is measured in. See ``pacingInterval``.
    private var pacingIntervalStore: TimeInterval =
        NavigationCameraInterpolator.nominalFixInterval

    public init() {}

    /// True once at least one fix has been fed.
    public var hasFix: Bool { latest != nil }

    /// The low-passed bearing as of the newest fix, in degrees `[0, 360)`.
    /// `nil` before the first fix. Exposed for tests and diagnostics;
    /// rendering should use ``state(at:)``, which interpolates towards it.
    public var latestBearingDeg: Double? { latest?.bearingDeg }

    /// The raw span between the two newest fixes, or ``nominalFixInterval``
    /// before two have been seen.
    ///
    /// Diagnostics only: what actually paces the camera is
    /// ``pacingInterval``, which is clamped and median-filtered.
    public var fixInterval: TimeInterval {
        guard let latest, let previous else { return Self.nominalFixInterval }
        let span = latest.timestamp - previous.timestamp
        return span > 0 ? span : Self.nominalFixInterval
    }

    /// The interval the camera is actually **paced** by: the median of the
    /// last ``intervalWindow`` clamped inter-fix gaps, seeded with
    /// ``nominalFixInterval``.
    ///
    /// A median rather than the single last gap because one anomalous gap
    /// must not redefine the pace. Two fixes 40 ms apart followed by
    /// ordinary 1 Hz delivery would otherwise set the interval to the
    /// 100 ms floor, run the interpolation parameter to
    /// ``extrapolationCap`` within 190 ms, freeze the pose for the rest of
    /// the second, and then snap it *backwards* when the next fix rolled
    /// the segment over. Mirrors the Android side's `pacingIntervalMs`.
    ///
    /// Distinct from ``fixInterval``, which is the raw span between the
    /// two newest fixes and is reported for diagnostics only.
    public var pacingInterval: TimeInterval { pacingIntervalStore }

    /// True when a route is set and both of the two newest fixes projected
    /// onto it — i.e. ``state(at:)`` is following the road, not a chord
    /// across it.
    public var isFollowingRoute: Bool {
        route != nil && latest?.alongM != nil && previous?.alongM != nil
    }

    // MARK: - The route

    /// Give the interpolator the route the vehicle is driving, so that it
    /// interpolates **along the road** instead of straight between fixes.
    ///
    /// Why this matters: fixes arrive about a second apart, which at urban
    /// speed is 10–15 m. Interpolating in a straight line between two of
    /// them cuts every corner — through a bend the interpolated point
    /// leaves the route line, and the puck visibly drifts off the road and
    /// back on again. Interpolating in **arc length** along the route and
    /// emitting the point *on* the polyline cannot do that: every position
    /// it reports is a point of the route.
    ///
    /// The cumulative-distance table is built **once, here**. Rebuilding it
    /// per tick is the mistake that froze MapMapNav's JS thread
    /// (`src/state/guidance/routeProgress.ts` documents the same
    /// precompute); this type projects a fix onto the route once per fix
    /// (~1 Hz), and the per-frame query is a binary search and a lerp.
    ///
    /// Pass the route geometry in order. Fewer than two points clears it.
    ///
    /// Both stored fixes are **re-snapped** onto the new geometry here.
    /// A sample's `alongM` is an arc length measured against whatever
    /// polyline was current when the fix arrived, and ``state(at:)``
    /// evaluates it against whatever polyline is current now — so carrying
    /// the old numbers across a reroute reads "2 km along route A" as
    /// "2 km along route B" and puts the camera wherever that happens to
    /// land, which on a reroute starting elsewhere is a jump of degrees of
    /// latitude (reproduced on the Android side). The re-snap honours
    /// ``onRouteToleranceM`` exactly as ``feed(coordinate:courseDeg:speedMps:timestamp:)``
    /// does, so a pose the new route does not pass near loses its match and
    /// falls back to point-to-point rather than being dragged onto a line
    /// it was never on.
    public mutating func setRoute(coordinates: [CLLocationCoordinate2D]) {
        let geometry = Route(coordinates: coordinates)
        route = geometry
        previous = previous.map { $0.reSnapped(onto: geometry) }
        latest = latest.map { $0.reSnapped(onto: geometry) }
    }

    /// Precomputed route geometry: the polyline and its cumulative
    /// distances, plus a local metre frame for projection.
    private struct Route {
        let points: [CLLocationCoordinate2D]
        /// `cumulative[i]` is the distance in metres from the start of the
        /// route to `points[i]`. Always `points.count` long.
        let cumulative: [Double]
        /// Metres per degree of longitude at the route's mean latitude.
        let metresPerLonDegree: Double

        static let metresPerLatDegree = 111_132.0

        init?(coordinates: [CLLocationCoordinate2D]) {
            let usable = coordinates.filter {
                $0.latitude.isFinite && $0.longitude.isFinite
            }
            guard usable.count >= 2 else { return nil }
            points = usable
            let meanLat = usable.reduce(0.0) { $0 + $1.latitude } / Double(usable.count)
            metresPerLonDegree = Self.metresPerLatDegree * cos(meanLat * .pi / 180)

            var running = [0.0]
            running.reserveCapacity(usable.count)
            for (a, b) in zip(usable, usable.dropFirst()) {
                let dx = (b.longitude - a.longitude) * metresPerLonDegree
                let dy = (b.latitude - a.latitude) * Self.metresPerLatDegree
                running.append(running[running.count - 1] + (dx * dx + dy * dy).squareRoot())
            }
            cumulative = running
        }

        var lengthM: Double { cumulative[cumulative.count - 1] }

        /// Project a coordinate onto the polyline.
        /// - Returns: the distance along the route, and how far off it the
        ///   coordinate sits, both in metres.
        func project(_ coordinate: CLLocationCoordinate2D) -> (alongM: Double, offsetM: Double) {
            var bestAlong = 0.0
            var bestOffsetSquared = Double.greatestFiniteMagnitude
            let px = coordinate.longitude * metresPerLonDegree
            let py = coordinate.latitude * Self.metresPerLatDegree

            for index in 0..<(points.count - 1) {
                let a = points[index], b = points[index + 1]
                let ax = a.longitude * metresPerLonDegree, ay = a.latitude * Self.metresPerLatDegree
                let bx = b.longitude * metresPerLonDegree, by = b.latitude * Self.metresPerLatDegree
                let vx = bx - ax, vy = by - ay
                let lengthSquared = vx * vx + vy * vy
                // Fraction along this segment, clamped to its ends so the
                // projection can never fall past a vertex.
                let t = lengthSquared > 0
                    ? min(max(((px - ax) * vx + (py - ay) * vy) / lengthSquared, 0), 1)
                    : 0
                let dx = px - (ax + vx * t), dy = py - (ay + vy * t)
                let offsetSquared = dx * dx + dy * dy
                if offsetSquared < bestOffsetSquared {
                    bestOffsetSquared = offsetSquared
                    bestAlong = cumulative[index]
                        + t * (cumulative[index + 1] - cumulative[index])
                }
            }
            return (bestAlong, bestOffsetSquared.squareRoot())
        }

        /// Where `coordinate` sits along this route, or `nil` when it is
        /// further than ``onRouteToleranceM`` off it — the driver has
        /// genuinely left the route, and pinning the camera to the planned
        /// line would hide that, as MapMapNav's `guidanceEventFromProgress`
        /// does.
        func matchedAlongM(_ coordinate: CLLocationCoordinate2D) -> Double? {
            let projection = project(coordinate)
            return projection.offsetM <= NavigationCameraInterpolator.onRouteToleranceM
                ? projection.alongM : nil
        }

        /// The point at a given distance along the route. Clamped to the
        /// route's ends.
        func point(atM distance: Double) -> CLLocationCoordinate2D {
            let target = min(max(distance, 0), lengthM)
            // Binary search for the segment containing `target`.
            var low = 0, high = cumulative.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if cumulative[mid] <= target { low = mid } else { high = mid }
            }
            let span = cumulative[high] - cumulative[low]
            let t = span > 0 ? (target - cumulative[low]) / span : 0
            let a = points[low], b = points[high]
            return CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * t,
                longitude: a.longitude + (b.longitude - a.longitude) * t)
        }

        /// The route's direction at a given distance along it, measured as
        /// the chord across ``tangentWindowM`` either side — a spatial
        /// low-pass, so a corner turns the camera over ~24 m rather than
        /// flipping it at one vertex.
        func bearing(atM distance: Double) -> Double {
            let window = NavigationCameraInterpolator.tangentWindowM
            var back = max(distance - window, 0)
            var forward = min(distance + window, lengthM)
            if forward - back < 0.5 {
                // Degenerate (a route shorter than the window, or an end):
                // widen to the whole route rather than divide by nothing.
                back = 0
                forward = lengthM
            }
            let from = point(atM: back), to = point(atM: forward)
            let dx = (to.longitude - from.longitude) * metresPerLonDegree
            let dy = (to.latitude - from.latitude) * Self.metresPerLatDegree
            guard dx != 0 || dy != 0 else { return 0 }
            return NavigationCameraInterpolator.wrap360(atan2(dx, dy) * 180 / .pi)
        }
    }

    // MARK: - Feeding

    /// Feed one guidance fix.
    ///
    /// - Parameters:
    ///   - coordinate: the position to follow. Use the **route-snapped**
    ///     fix (`GuidanceDisplay.snappedFix`), never the raw one: raw GPS
    ///     drifts off the carriageway, and on a course-up camera that reads
    ///     as the whole world shaking.
    ///   - courseDeg: course over ground, degrees clockwise from true
    ///     north. Values outside `[0, 360)` are wrapped.
    ///   - speedMps: speed over ground. Below ``standstillSpeedMps`` the
    ///     bearing is frozen (see the property).
    ///   - timestamp: monotonic seconds on the host's clock — the fix's
    ///     *arrival* time (see the type's "Clock" note).
    ///
    /// Fixes that are out of order, simultaneous with the newest one, or
    /// non-finite are ignored: replaying them would send the camera
    /// backwards.
    public mutating func feed(
        coordinate: CLLocationCoordinate2D,
        courseDeg: Double?,
        speedMps: Double?,
        timestamp: TimeInterval
    ) {
        guard timestamp.isFinite,
              coordinate.latitude.isFinite, coordinate.longitude.isFinite
        else { return }
        if let latest, timestamp <= latest.timestamp { return }

        let bearing = nextBearing(courseDeg: courseDeg, speedMps: speedMps)
        // Project once per fix, never per frame.
        let alongM = route?.matchedAlongM(coordinate)
        let sample = Sample(coordinate: coordinate, bearingDeg: bearing,
                            timestamp: timestamp, alongM: alongM)
        if let latest { record(gap: timestamp - latest.timestamp) }
        previous = latest
        latest = sample
    }

    /// Folds one measured gap into the pacing estimate: clamp it, push it
    /// into the rolling window, and re-take the median. See
    /// ``pacingInterval`` for why the median and not the gap itself.
    private mutating func record(gap: TimeInterval) {
        recentIntervals[intervalCursor] =
            min(max(gap, Self.minFixInterval), Self.maxFixInterval)
        intervalCursor = (intervalCursor + 1) % Self.intervalWindow
        pacingIntervalStore = recentIntervals.sorted()[Self.intervalWindow / 2]
    }

    /// The low-passed bearing this fix should produce.
    ///
    /// First fix snaps (there is nothing to smooth towards). A standstill or
    /// a missing course freezes the previous value. Otherwise the previous
    /// value moves ``bearingSmoothAlpha`` of the way along the **shortest
    /// arc** to the reported course, so 350° → 10° turns 20° clockwise
    /// rather than 340° the other way.
    private func nextBearing(courseDeg: Double?, speedMps: Double?) -> Double {
        guard let latest else {
            guard let courseDeg, courseDeg.isFinite else { return 0 }
            return Self.wrap360(courseDeg)
        }
        guard let courseDeg, courseDeg.isFinite else { return latest.bearingDeg }
        // Absent speed is treated as moving: Core Location reports a
        // negative/absent speed in conditions where the course is still
        // usable, and freezing on every such fix would stick the camera.
        if let speedMps, speedMps.isFinite, speedMps < Self.standstillSpeedMps {
            return latest.bearingDeg
        }
        let delta = Self.shortestArcDelta(from: latest.bearingDeg, to: courseDeg)
        return Self.wrap360(latest.bearingDeg + delta * Self.bearingSmoothAlpha)
    }

    // MARK: - Sampling

    /// The camera position and bearing to render at `timestamp`.
    ///
    /// `nil` before the first fix — the host should leave the camera where
    /// it framed the route.
    ///
    /// Behaviour, in the order the cases arise:
    /// - **first fix**: snaps to it (nothing to interpolate between);
    /// - **healthy feed**: linear interpolation between the two newest
    ///   fixes, one interval behind live (see the type's "Presentation
    ///   lag" note);
    /// - **late fix**: keeps going along the last segment, but only as far
    ///   as ``extrapolationCap`` — half an interval past the newest fix;
    /// - **stale feed**: holds at that capped point.
    ///
    /// With a route set (``setRoute(coordinates:)``) and both fixes on it,
    /// the interpolation runs in **arc length along the route** and the
    /// position returned is a point *on* the route line, with the bearing
    /// taken from the route's own direction there. Without a route — or
    /// once a fix projects further than ``onRouteToleranceM`` off it — it
    /// falls back to interpolating the two fixes directly.
    ///
    /// The fallback interpolates linearly in latitude/longitude. Over one
    /// fix interval of driving (tens of metres) the difference from a
    /// great-circle path is far below a pixel, so the cheap form is the
    /// honest one. It does not handle a segment crossing the antimeridian;
    /// no MapMap route fixture does.
    public func state(at timestamp: TimeInterval)
        -> (coordinate: CLLocationCoordinate2D, bearingDeg: Double)?
    {
        guard let latest else { return nil }
        guard let previous else { return (latest.coordinate, latest.bearingDeg) }

        let span = latest.timestamp - previous.timestamp
        guard span > 0 else { return (latest.coordinate, latest.bearingDeg) }

        // The interpolation parameter, measured in intervals since the
        // newest fix arrived: 0 the moment it lands (so we render the
        // PREVIOUS fix) and 1.0 an interval later (so we reach the newest
        // one exactly as its successor arrives). That one interval of
        // presentation lag is what keeps the motion continuous — sampling
        // live instead would sit an interval ahead of anything known and
        // snap backwards on every fix.
        let raw = (timestamp - latest.timestamp) / pacingIntervalStore
        let progress = min(max(raw, 0), Self.extrapolationCap)

        // On-route: interpolate the distance travelled along the road, and
        // read the position and heading off the road at that distance. A
        // straight line between two fixes cuts corners; a point on the
        // polyline cannot.
        if let route, let from = previous.alongM, let to = latest.alongM {
            let along = from + (to - from) * progress
            return (route.point(atM: along), route.bearing(atM: along))
        }

        let coordinate = CLLocationCoordinate2D(
            latitude: previous.coordinate.latitude
                + (latest.coordinate.latitude - previous.coordinate.latitude) * progress,
            longitude: previous.coordinate.longitude
                + (latest.coordinate.longitude - previous.coordinate.longitude) * progress)

        // Bearing never extrapolates: past the newest fix there is no
        // evidence the vehicle kept turning, and guessing that it did
        // rotates the whole map on nothing.
        let bearingProgress = min(progress, 1)
        let delta = Self.shortestArcDelta(from: previous.bearingDeg, to: latest.bearingDeg)
        let bearing = Self.wrap360(previous.bearingDeg + delta * bearingProgress)

        return (coordinate, bearing)
    }

    // MARK: - Angle helpers

    /// Normalise to `[0, 360)`.
    public static func wrap360(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// Signed shortest-arc difference `from -> to`, in `[-180, 180)`.
    /// Positive is clockwise.
    ///
    /// The half-open range matches `shortestArcDeltaDeg` on the Android
    /// side down to the boundary: an exact 180 degree reversal resolves
    /// anticlockwise on both platforms rather than one each way.
    public static func shortestArcDelta(from: Double, to: Double) -> Double {
        wrap360(to - from + 180) - 180
    }
}
