// Portions of this file are derived from Ferrostar's FerrostarCarPlayUI
// (apple/Sources/FerrostarCarPlayUI/CarPlayModels/CPManeuver.swift,
// https://github.com/stadiamaps/ferrostar), © Stadia Maps, Inc.,
// licensed under the BSD 3-Clause License. Re-implemented against
// ``VisualBanner``/``BannerLine`` (MapMap's own generated types) instead
// of Ferrostar's `VisualInstruction` — no Ferrostar Swift package is
// linked (see ios/README.md, "Ferrostar boundary").

import CarPlay
import Foundation
import MapMapKit
import UIKit

/// The key `CPManeuver.userInfo` is stashed under so a maneuver can be
/// compared back against the ``VisualBanner`` that produced it — this is
/// how ``NavigationState/refreshCarPlay(session:mapTemplate:units:)``
/// decides whether the upcoming maneuver needs replacing or just a travel
/// estimate refresh.
private let bannerUserInfoKey = "ai.mapmap.carplay.visualBanner"

extension CPManeuver {

    /// Attribution/identity note: this is `self.init()` (CPManeuver's
    /// designated initializer) plus property assignment, matching the
    /// pattern `CPManeuver` uses everywhere (there is no
    /// designated-initializer overload that takes these as arguments).
    convenience init(
        visualBanner: VisualBanner,
        initialTravelEstimates: CPTravelEstimates,
        locale: Locale = .current
    ) {
        self.init()
        self.initialTravelEstimates = initialTravelEstimates
        instructionVariants = visualBanner.instructionVariants
        // Road-number badges (SPEC 5.5) from the engine's ref on the banner, never a street
        // name: CarPlay prefers attributed variants when set, and keeps the plain ones as the
        // text. No speed sign here: CarPlay shows the limit in its own system UI.
        if let badged = visualBanner.attributedInstructionVariants {
            attributedInstructionVariants = badged
            dashboardAttributedInstructionVariants = badged
        }
        // The side traffic drives on at this manoeuvre, from the engine
        // (``VisualBanner/drivingSide``). Never defaulted: unknown means a
        // plain turn glyph and no roundabout junction, not a guessed ring.
        let drivingSide = ManeuverGlyph.drivingSide(visualBanner.drivingSide)
        symbolImage = ManeuverGlyph.symbolImage(
            maneuverType: visualBanner.primary.maneuverType,
            maneuverModifier: visualBanner.primary.maneuverModifier,
            drivingSide: drivingSide)
        userInfo = [bannerUserInfoKey: visualBanner]

        if #available(iOS 17.4, *) {
            if let exitNumber = visualBanner.primary.exitNumbers.first {
                highwayExitLabel = exitNumber
            }
            maneuverType = ManeuverGlyph.cpManeuverType(
                maneuverType: visualBanner.primary.maneuverType,
                maneuverModifier: visualBanner.primary.maneuverModifier)
            if let drivingSide {
                trafficSide = drivingSide == "left" ? .left : .right
            }
            // Roundabout exit angle: BannerLine reports the exit as
            // degrees travelled around the roundabout (OSM/Valhalla
            // convention), which maps directly onto CPManeuver's junction
            // model — more precise than picking one of the fixed
            // `.roundaboutExit1...19` cases. Only with a known driving
            // side: the cluster draws the junction in `trafficSide`'s
            // circulation, and an unset side would draw it anticlockwise.
            if ManeuverGlyph.isRoundabout(visualBanner.primary.maneuverType),
               drivingSide != nil,
               let exitDegrees = visualBanner.primary.roundaboutExitDegrees {
                junctionType = .roundabout
                junctionExitAngle = Measurement(value: Double(exitDegrees), unit: UnitAngle.degrees)
            }
        }
    }

    /// The ``VisualBanner`` this maneuver was built from, if it was built
    /// via the initializer above — used to detect whether the current
    /// instruction actually changed before rebuilding the maneuver list.
    var sourceVisualBanner: VisualBanner? {
        (userInfo as? [String: Any])?[bannerUserInfoKey] as? VisualBanner
    }
}

extension VisualBanner {

    /// Instruction variants from most to least preferred, as `CPManeuver`
    /// expects: `instructionVariants` are alternative, **self-contained**
    /// renderings of the *same* instruction, longest first — CarPlay
    /// picks whichever variant is the longest that still fits the
    /// available width. `[primary.text, secondary.text]` would be wrong
    /// here: `secondary` is a *different, later* instruction (e.g. "then
    /// arrive at your destination"), so a narrow head unit choosing the
    /// second "variant" would show the wrong maneuver's text instead of a
    /// shorter rendering of the current one. Each returned variant must
    /// stand alone: the combined "primary, secondary" reading first (for
    /// wide displays that can show both), then `primary` alone (for
    /// narrow ones) — never `secondary` alone. (MapMap has no
    /// third-priority text — `sub` is the lane diagram, handled
    /// separately via ``CPLaneGuidance``.)
    fileprivate var instructionVariants: [String] {
        guard let secondaryText = secondary?.text, !secondaryText.isEmpty else {
            return [primary.text]
        }
        return ["\(primary.text), \(secondaryText)", primary.text]
    }

    /// ``instructionVariants`` with road-number badges as text attachments (see
    /// ``RoadRefImage/attributedInstruction(_:refs:badge:)``), followed by the plain primary
    /// text so a display too narrow for a badge still has a variant that fits; `nil` when the
    /// banner carries no ref with a badge.
    fileprivate var attributedInstructionVariants: [NSAttributedString]? {
        let refs = roadRefs
        guard !refs.isEmpty else { return nil }
        var cache: [RoadRef: UIImage] = [:]
        let badge: (RoadRef) -> UIImage? = { ref in
            if let image = cache[ref] { return image }
            let image = RoadRefImage.carPlayImage(for: ref)
            cache[ref] = image
            return image
        }
        let badged = instructionVariants.compactMap { RoadRefImage.attributedInstruction($0, refs: refs, badge: badge) }
        guard !badged.isEmpty else { return nil }
        return badged + [NSAttributedString(string: primary.text)]
    }
}
