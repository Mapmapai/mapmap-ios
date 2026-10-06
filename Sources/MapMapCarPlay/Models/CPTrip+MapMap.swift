// Portions of this file are derived from Ferrostar's FerrostarCarPlayUI
// (apple/Sources/FerrostarCarPlayUI/CarPlayModels/CPTrip.swift,
// https://github.com/stadiamaps/ferrostar), © Stadia Maps, Inc.,
// licensed under the BSD 3-Clause License. Re-implemented against
// MapMapKit's own ``RouteResult``/``RouteSummary`` — no Ferrostar Swift
// package is linked (see ios/README.md, "Ferrostar boundary").

import CarPlay
import Foundation
import MapKit
import MapMapKit

/// The key `CPRouteChoice.userInfo` is stashed under so a choice can be
/// traced back to the ``RouteResult`` it was built from (the Rust core
/// needs the *route's own* Valhalla response JSON to start a
/// ``NavigationEngine``, not anything CarPlay can reconstruct).
private let routeResultUserInfoKey = "ai.mapmap.carplay.routeResult"

extension CPRouteChoice {

    /// Build a route choice from one MapMap ``RouteResult``, stashing the
    /// result itself in `userInfo` so it can be recovered when the driver
    /// selects or starts this choice
    /// (`CPMapTemplateDelegate.mapTemplate(_:startedTrip:usingRouteChoice:)`).
    public convenience init(
        routeResult: RouteResult,
        routeNumber: Int,
        units: CarPlayDistanceUnits,
        locale: Locale = .current
    ) {
        let distance = CarPlayMeasurementLength(
            units: units, distanceM: routeResult.summary.distanceM, locale: locale
        ).rounded()
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        // `.providedUnit`, not `.naturalScale`: `distance` has already been
        // unit-selected and rounded by `CarPlayMeasurementLength` for the
        // requested `units` — letting the formatter re-derive units from
        // `locale` would silently override that (e.g. an explicit
        // `.metric` request rendering as miles on a US-locale device).
        formatter.unitOptions = .providedUnit
        let distanceText = formatter.string(from: distance)

        var extras: [String] = [distanceText]
        if routeResult.summary.hasToll { extras.append("Toll road") }
        if routeResult.summary.hasFerry { extras.append("Ferry") }

        self.init(
            summaryVariants: ["Route \(routeNumber)"],
            additionalInformationVariants: [extras.joined(separator: ", ")],
            selectionSummaryVariants: ["Selected Route \(routeNumber)"]
        )
        userInfo = [routeResultUserInfoKey: routeResult]
    }

    /// The ``RouteResult`` this choice was built from, when built via the
    /// initializer above. `nil` for a `CPRouteChoice` the host app built
    /// itself without going through MapMapCarPlay.
    public var mapMapRouteResult: RouteResult? {
        (userInfo as? [String: Any])?[routeResultUserInfoKey] as? RouteResult
    }
}

extension CPTrip {

    /// Build a `CPTrip` (for `CPMapTemplate.showRouteChoicesPreview(for:textConfiguration:)`
    /// and `startNavigationSession(for:)`) from one or more candidate
    /// routes for the same origin/destination.
    ///
    /// MapMap's ``RouteResult`` carries no origin/destination coordinates
    /// of its own (only the route geometry/summary) — the host app already
    /// has them, since it supplied the ``RoutePoint`` waypoints to
    /// `OfflineRouting.route(router:waypoints:costing:adr:)`. Pass them
    /// through unchanged as `MKMapItem`s (wrap a bare coordinate in
    /// `MKMapItem(placemark:)` if you have no richer place data).
    public static func mapMapTrip(
        routes: [RouteResult],
        origin: MKMapItem,
        destination: MKMapItem,
        units: CarPlayDistanceUnits = .localeDefault,
        locale: Locale = .current
    ) -> CPTrip {
        let routeChoices = routes.enumerated().map { index, route in
            CPRouteChoice(
                routeResult: route,
                routeNumber: index + 1,
                units: units,
                locale: locale
            )
        }
        return CPTrip(origin: origin, destination: destination, routeChoices: routeChoices)
    }
}
