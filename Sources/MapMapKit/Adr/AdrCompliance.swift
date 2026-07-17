import Foundation

/// On-device ADR 8.6.4 dangerous-goods enforcement.
///
/// Two enforcement points, both running the same Rust domain model
/// (`sn-adr`, conservative ADR 8.6.4 reading):
///
/// 1. **Pre-route** — pass the ``AdrProfile`` to
///    ``OfflineRouting/route(router:waypoints:costing:adr:)``; the core
///    merges the restrictions into Valhalla truck costing, so forbidden
///    tunnels and undersized roads are excluded before a route exists.
/// 2. **En-route** — call ``checkTunnel(profile:category:)`` against a
///    tunnel's category (e.g. from map data ahead of the vehicle) to gate
///    entry while driving, and ``forbiddenCategories(profile:)`` to badge
///    the whole profile in the UI.
public enum AdrCompliance {

    /// May the vehicle described by `profile` pass through a tunnel of
    /// `category`? Blocked decisions carry a human-readable reason citing
    /// ADR 8.6.4.
    public static func checkTunnel(
        profile: AdrProfile,
        category: AdrTunnelCategory
    ) -> AdrDecision {
        MapMapKit.checkTunnel(profile: profile, category: category)
    }

    /// All tunnel categories the vehicle is forbidden from, ascending.
    /// Empty when unrestricted.
    public static func forbiddenCategories(profile: AdrProfile) -> [AdrTunnelCategory] {
        MapMapKit.forbiddenCategories(profile: profile)
    }

    /// True when the profile is barred from at least one tunnel category.
    public static func isTunnelRestricted(profile: AdrProfile) -> Bool {
        !forbiddenCategories(profile: profile).isEmpty
    }

    /// Validate a profile's physical plausibility before it goes anywhere
    /// near routing. Returns a list of human-readable problems; empty
    /// means valid. Pure Swift — safe to call from previews and tests
    /// without the native library.
    public static func validateProfile(_ profile: AdrProfile) -> [String] {
        var problems: [String] = []
        if !profile.heightM.isFinite || profile.heightM <= 0.0 {
            problems.append(
                "height must be a positive number of metres, got \(profile.heightM)")
        }
        if !profile.widthM.isFinite || profile.widthM <= 0.0 {
            problems.append(
                "width must be a positive number of metres, got \(profile.widthM)")
        }
        if !profile.lengthM.isFinite || profile.lengthM <= 0.0 {
            problems.append(
                "length must be a positive number of metres, got \(profile.lengthM)")
        }
        if !profile.grossWeightT.isFinite || profile.grossWeightT <= 0.0 {
            problems.append(
                "gross weight must be a positive number of tonnes, got \(profile.grossWeightT)")
        }
        if let axleLoad = profile.axleLoadT {
            if !axleLoad.isFinite || axleLoad <= 0.0 {
                problems.append(
                    "axle load must be a positive number of tonnes, got \(axleLoad)")
            } else if profile.grossWeightT.isFinite, axleLoad > profile.grossWeightT {
                problems.append(
                    "axle load (\(axleLoad) t) cannot exceed gross weight "
                        + "(\(profile.grossWeightT) t)")
            }
        }
        if let axles = profile.axleCount, axles == 0 {
            problems.append("axle count cannot be zero")
        }
        if profile.tunnelCode != nil, !profile.hazmat {
            problems.append(
                "a tunnel restriction code was set but hazmat is false; set hazmat = true")
        }
        return problems
    }
}
