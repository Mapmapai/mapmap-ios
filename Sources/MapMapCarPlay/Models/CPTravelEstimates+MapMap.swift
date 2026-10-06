// Portions of this file are derived from Ferrostar's FerrostarCarPlayUI
// (apple/Sources/FerrostarCarPlayUI/CarPlayModels/CPTravelEstimate.swift,
// https://github.com/stadiamaps/ferrostar), © Stadia Maps, Inc.,
// licensed under the BSD 3-Clause License. Re-implemented against
// MapMapKit's own ``GuidanceUpdate`` shape — no Ferrostar Swift package
// is linked (see ios/README.md, "Ferrostar boundary").

import CarPlay
import Foundation

extension CPTravelEstimates {

    /// Trip-level estimate (feeds `CPMapTemplate.updateEstimates(_:for:)`
    /// and the bottom arrival card): total distance/time remaining for the
    /// whole route.
    public static func forTrip(
        distanceRemainingM: Double,
        durationRemainingS: Double,
        units: CarPlayDistanceUnits,
        locale: Locale = .current
    ) -> CPTravelEstimates {
        let distance = CarPlayMeasurementLength(units: units, distanceM: distanceRemainingM, locale: locale)
        return CPTravelEstimates(
            distanceRemaining: distance.rounded(),
            timeRemaining: durationRemainingS
        )
    }

    /// Step-level estimate (feeds the instruction bar / `initialTravelEstimates`
    /// and per-maneuver updates): distance to the *next* maneuver. CarPlay's
    /// maneuver card does not read `timeRemaining` from this one — only the
    /// trip-level estimate's time is shown — so it is always zero here,
    /// mirroring the Ferrostar implementation this is ported from.
    public static func forStep(
        distanceToNextManeuverM: Double,
        units: CarPlayDistanceUnits,
        locale: Locale = .current
    ) -> CPTravelEstimates {
        let distance = CarPlayMeasurementLength(units: units, distanceM: distanceToNextManeuverM, locale: locale)
        return CPTravelEstimates(
            distanceRemaining: distance.rounded(),
            timeRemaining: 0
        )
    }
}
