// Portions of this file are derived from Ferrostar's FerrostarCarPlayUI
// (apple/Sources/FerrostarCarPlayUI/CarPlayModels/NavigationState+CarPlay.swift,
// CPNavigationSession+Estimates.swift and TripProgress+Estimates.swift,
// https://github.com/stadiamaps/ferrostar), © Stadia Maps, Inc.,
// licensed under the BSD 3-Clause License. Re-implemented against
// MapMapKit's own ``NavigationState``/``GuidanceUpdate`` — no Ferrostar
// Swift package is linked (see ios/README.md, "Ferrostar boundary").

import CarPlay
import Foundation
import MapMapKit

extension NavigationState {

    /// Push this state onto an active `CPNavigationSession`/`CPMapTemplate`:
    /// updates the trip-level travel estimates every call, and only
    /// rebuilds `upcomingManeuvers`/`currentLaneGuidance` when the visual
    /// banner actually changed — **CPManeuvers must be refreshed on every
    /// navigation-state tick** (ferrostar#537), but rebuilding on every fix
    /// (tens of times a second) would needlessly re-run CarPlay's
    /// presentation layer *and*, for lane guidance, register an
    /// ever-growing set of `CPLaneGuidance` instances on the session (see
    /// `CPNavigationSession.h`: instances must be added via `add(_:)`
    /// before `currentLaneGuidance` can reference them, and nothing ever
    /// removes an added instance) — the dedupe below is what makes both
    /// safe. Distance-only refreshes (the "same instruction" branch) never
    /// touch lane guidance, by design: it only changes when the maneuver
    /// does.
    ///
    /// No-op for `.arrived`/`.offRoute` — callers should react to
    /// ``NavigationState/isArrived`` (finish the trip) and
    /// ``NavigationState/needsReroute`` (recalculate and start a fresh
    /// session) themselves; this method only carries the `.navigating`
    /// case onto CarPlay.
    /// `CPNavigationSession`/`CPMapTemplate` are main-actor-isolated by the
    /// CarPlay framework itself, so this method is too.
    @MainActor
    public func refreshCarPlay(
        session: CPNavigationSession,
        mapTemplate: CPMapTemplate,
        units: CarPlayDistanceUnits = .localeDefault,
        locale: Locale = .current
    ) {
        guard case .navigating(
            _, let distanceToNextManeuverM, let distanceRemainingM, let durationRemainingS,
            _, _, let visual, _, _, _, _
        ) = update else { return }

        let tripEstimates = CPTravelEstimates.forTrip(
            distanceRemainingM: distanceRemainingM,
            durationRemainingS: durationRemainingS,
            units: units, locale: locale)
        mapTemplate.updateEstimates(tripEstimates, for: session.trip)

        guard let visual else { return }

        let stepEstimates = CPTravelEstimates.forStep(
            distanceToNextManeuverM: distanceToNextManeuverM, units: units, locale: locale)

        if let currentManeuver = session.upcomingManeuvers.first,
           currentManeuver.sourceVisualBanner == visual {
            // Same instruction as last tick: just refresh the distance.
            // Deliberately does NOT touch `currentLaneGuidance` — lane
            // guidance is a property of the maneuver, not the fix, so it
            // only needs revisiting when the maneuver itself changes
            // (the branch below).
            session.updateEstimates(stepEstimates, for: currentManeuver)
        } else {
            // A new manoeuvre became current: rebuild the (single-entry)
            // upcoming list. MapMap surfaces one active banner at a time
            // (see ``GuidanceDisplay/visualBanner(_:)``), unlike Ferrostar's
            // full remaining-steps list, so there is only ever one
            // maneuver to add here.
            let maneuver = CPManeuver(visualBanner: visual, initialTravelEstimates: stepEstimates, locale: locale)
            if #available(iOS 17.4, *) {
                // Apple's documented flow (CPNavigationSession.h): an
                // instance must be registered via `add(_:)` before it can
                // be referenced by `upcomingManeuvers`/`currentLaneGuidance`
                // — add, then assign, in that order, and only when the
                // maneuver actually changed (never per-tick).
                session.add([maneuver])
            }
            session.upcomingManeuvers = [maneuver]

            if #available(iOS 18.0, *) {
                let laneGuidance = visual.sub.flatMap(CPLaneGuidanceConverter.laneGuidance(for:))
                if let laneGuidance {
                    session.add([laneGuidance])
                }
                // Clearing to `nil` also only happens here, on a genuine
                // maneuver change — not every tick — matching the
                // add-then-assign discipline above.
                session.currentLaneGuidance = laneGuidance
            }
        }
    }
}
