// Portions of this file are derived from Ferrostar's FerrostarCarPlayUI
// (apple/Sources/FerrostarCarPlayUI/Measurement/CarPlayMeasurementLength.swift
// and MKDistanceFormatterUnits.swift,
// https://github.com/stadiamaps/ferrostar), © Stadia Maps, Inc.,
// licensed under the BSD 3-Clause License. Re-implemented here against
// plain metre `Double`s (MapMap's FFI types) instead of `CLLocationDistance`
// — no Ferrostar Swift package is linked (see ios/README.md, "Ferrostar
// boundary").

import Foundation
import MapKit

/// Which distance units CarPlay should display: short/long unit pairs
/// mirroring `MKDistanceFormatter.Units`, exposed independently so this
/// module has no requirement on `MKDistanceFormatter` itself.
public enum CarPlayDistanceUnits: Sendable {
    /// Follow the given locale's measurement system (the default: feet →
    /// miles in the US, yards → miles in the UK, metres → kilometres
    /// elsewhere).
    case localeDefault
    /// Feet, then miles.
    case imperial
    /// Yards, then miles (UK road-signage convention).
    case imperialWithYards
    /// Metres, then kilometres.
    case metric

    /// The short and long units to switch between, for `locale`.
    func shortAndLong(for locale: Locale) -> (short: UnitLength, long: UnitLength) {
        switch self {
        case .localeDefault:
            switch locale.measurementSystem {
            case .us: return (.feet, .miles)
            case .uk: return (.yards, .miles)
            default: return (.meters, .kilometers)
            }
        case .imperial: return (.feet, .miles)
        case .imperialWithYards: return (.yards, .miles)
        case .metric: return (.meters, .kilometers)
        }
    }

    /// The distance (in metres) above which the long unit should be
    /// preferred over the short one, for `locale`.
    func thresholdForLongUnitM(for locale: Locale) -> Double {
        switch self {
        case .localeDefault:
            switch locale.measurementSystem {
            case .us: return 289
            case .uk: return 300
            default: return 1_000
            }
        case .imperial: return 289
        case .imperialWithYards: return 300
        case .metric: return 1_000
        }
    }
}

/// A CarPlay-ready distance measurement: picks short vs. long units from a
/// raw metre value, and rounds it to the step sizes CarPlay's estimate
/// cards expect (never a distractingly precise number while driving).
public struct CarPlayMeasurementLength: Sendable {
    public let measurement: Measurement<UnitLength>

    public init(units: CarPlayDistanceUnits, distanceM: Double, locale: Locale = .current) {
        let metres = Measurement(value: distanceM, unit: UnitLength.meters)
        let (short, long) = units.shortAndLong(for: locale)
        let useShort = distanceM <= units.thresholdForLongUnitM(for: locale)
        measurement = metres.converted(to: useShort ? short : long)
    }

    /// Round to the step CarPlay's own trip-estimate cards use: 5 m/ft/yd
    /// under 50, 10 under 100, 50 under 500, 100 above; for kilometres or
    /// miles, whole numbers above 10, one decimal below.
    public func rounded() -> Measurement<UnitLength> {
        let value = measurement.value
        let unit = measurement.unit
        switch unit {
        case .feet, .meters, .yards:
            if value < 50 {
                return Measurement(value: value.roundedToNearest(5), unit: unit)
            } else if value < 100 {
                return Measurement(value: value.roundedToNearest(10), unit: unit)
            } else if value < 500 {
                return Measurement(value: value.roundedToNearest(50), unit: unit)
            } else {
                return Measurement(value: value.roundedToNearest(100), unit: unit)
            }
        default:
            if value > 10 {
                return Measurement(value: value.rounded(), unit: unit)
            } else {
                return Measurement(value: (value * 10).rounded() / 10, unit: unit)
            }
        }
    }
}

extension Double {
    fileprivate func roundedToNearest(_ step: Double) -> Double {
        (self / step).rounded() * step
    }
}
