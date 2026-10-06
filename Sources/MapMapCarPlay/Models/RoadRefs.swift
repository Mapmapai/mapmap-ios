import Foundation
import MapMapKit

/// One road-number badge to draw (SPEC 4.5): the text on the shield, its tier, the country whose
/// signs it follows and the shield template. A mirror of the canonical `RoadRef` in
/// `web-sdk/src/road-signs.ts`, plus ``source``, the raw ref the text came from.
public struct RoadRef: Equatable, Hashable, Sendable {
    /// Text on the shield, the country's display prefix stripped where the sign does
    /// (`"I 95"` draws `95`; GB, IE, FR, DE and NL keep the full text).
    public let text: String
    /// Tier id (`gb-motorway`, `us-interstate`, ...), `"generic"` for a ref with no national
    /// tier, `"text"` for a ref longer than six characters, which is never a badge.
    public let tier: String
    /// ISO 3166-1 alpha-2 of the profile that resolved it, `""` when unknown.
    public let country: String
    /// Spoken label (`"Motorway M25"`, `"Interstate 95"`); English only for now, like the
    /// canonical table.
    public let a11yLabel: String
    /// Shield template id; `nil` for a text-only ref.
    public let template: String?
    /// The raw ref as the engine reported it (`"I 95"`), the text a badge stands in for.
    public let source: String

    public init(text: String, tier: String, country: String, a11yLabel: String, template: String?, source: String) {
        self.text = text
        self.tier = tier
        self.country = country
        self.a11yLabel = a11yLabel
        self.template = template
        self.source = source
    }
}

/// One road-number tier of a country (`profiles.json`).
struct RoadRefTier {
    let id: String
    let template: String
    let template3: String?
    let refPattern: String?
    let roadClasses: [String]?
    let subdivisions: [String]?
    let stripPrefix: String?
}

/// Picks the road-number badges for a step's road (SPEC 4.5) from what the car SDK knows about
/// it: the raw `ref`, its country, subdivision and road class.
///
/// A mirror of the canonical `resolveRoadRef` for those inputs. Natively there is no route
/// relation `network` and no tile network, so a tier is chosen by its ref-prefix pattern only
/// (the spec's third rule); `RoadRefResolverTests` checks this against a golden table computed
/// by the canonical resolver itself, so the two cannot drift silently.
///
/// Never invents a ref: no ref, no badge. Refs over six characters come back as tier `"text"`
/// with no template (shown as text, never a badge). At most three concurrent routes.
public enum RoadRefResolver {

    public static func resolve(ref: String?, country: String?, subdivision: String?, roadClass: String?) -> [RoadRef] {
        let parts = (ref ?? "")
            .components(separatedBy: ";")
            .map(trim)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [] }

        let profile = profileFor(country: country, subdivision: subdivision)
        let tiers = profile?.tiers ?? RoadRefTables.genericTiers
        let sub = profile?.subdivision
        var out: [RoadRef] = []
        var seen = Set<String>()
        for raw in parts {
            if out.count >= 3 { break }
            let tier = matchTier(tiers, raw: raw, roadClass: roadClass, subdivision: sub)
            var text = raw
            if let strip = tier?.stripPrefix {
                text = trim(replacingFirst(strip, in: raw))
            }
            if text.isEmpty { text = raw }
            guard seen.insert("\(tier?.id ?? "generic")|\(text)").inserted else { continue }
            let cc = profile?.country ?? ""
            if text.utf16.count > 6 {
                out.append(RoadRef(text: text, tier: "text", country: cc, a11yLabel: label(text: text, tier: "text"), template: nil, source: raw))
                continue
            }
            let tierId = tier?.id ?? "generic"
            let long = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined().utf16.count >= 3
            let template: String
            if let tier {
                template = long ? (tier.template3 ?? tier.template) : tier.template
            } else {
                template = "generic"
            }
            out.append(RoadRef(text: text, tier: tierId, country: cc, a11yLabel: label(text: text, tier: tierId), template: template, source: raw))
        }
        return out
    }

    /// `"Motorway M25"`, `"A road A259"`, `"Interstate 95"`: the canonical `roadRefLabel`.
    public static func label(text: String, tier: String) -> String {
        let t = trim(text)
        guard !t.isEmpty else { return "" }
        let template = RoadRefTables.labels[tier] ?? (tier.hasPrefix("au-") ? "Route {text}" : "Road {text}")
        var number = replacingFirst("^[A-Za-z]+[- ]?", in: t)
        if number.isEmpty { number = t }
        return replaceFirst(
            replaceFirst(replaceFirst(template, "{text}", t), "{num}", number),
            "{letter}", String(t.prefix(1)).uppercased())
    }

    // MARK: - Profile lookup

    private struct Profile {
        let country: String
        let subdivision: String?
        let tiers: [RoadRefTier]
    }

    private static func profileFor(country: String?, subdivision: String?) -> Profile? {
        guard let country else { return nil }
        var cc = trim(country).uppercased()
        guard matches("^[A-Z]{2}$", cc) else { return nil }
        cc = RoadRefTables.aliases[cc] ?? cc
        let sub = subdivision.map { replacingFirst("^[A-Z]{2}-", in: trim($0).uppercased()) }
        if let tiers = RoadRefTables.tiers[cc] { return Profile(country: cc, subdivision: sub, tiers: tiers) }
        if RoadRefTables.genericCountries.contains(cc) {
            return Profile(country: cc, subdivision: sub, tiers: RoadRefTables.genericTiers)
        }
        return nil
    }

    private static func matchTier(_ tiers: [RoadRefTier], raw: String, roadClass: String?, subdivision: String?) -> RoadRefTier? {
        tiers.first { t in
            guard let pattern = t.refPattern, matches(pattern, raw) else { return false }
            if let classes = t.roadClasses, !(roadClass.map(classes.contains) ?? false) { return false }
            if let subs = t.subdivisions, !(subdivision.map(subs.contains) ?? false) { return false }
            return true
        }
    }

    // MARK: - Strings and patterns (JavaScript semantics)

    private static let lock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        lock.lock()
        defer { lock.unlock() }
        if let r = regexCache[pattern] { return r }
        // The patterns are generated from profiles.json, so a failure is a generator bug.
        let r = try! NSRegularExpression(pattern: pattern)
        regexCache[pattern] = r
        return r
    }

    private static func matches(_ pattern: String, _ s: String) -> Bool {
        regex(pattern).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `s.replace(new RegExp(pattern), "")`: the first match only.
    private static func replacingFirst(_ pattern: String, in s: String) -> String {
        guard let m = regex(pattern).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(m.range, in: s) else { return s }
        return s.replacingCharacters(in: range, with: "")
    }

    /// `s.replace(literal, replacement)`: the first occurrence only.
    private static func replaceFirst(_ s: String, _ literal: String, _ replacement: String) -> String {
        guard let range = s.range(of: literal) else { return s }
        return s.replacingCharacters(in: range, with: replacement)
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension VisualBanner {
    /// The road-number badges for the road this banner's manoeuvre leads onto
    /// (``VisualBanner/roadRef``, ``VisualBanner/country``, ``VisualBanner/subdivision``,
    /// ``VisualBanner/roadClass``); empty when the engine reported no ref.
    public var roadRefs: [RoadRef] {
        RoadRefResolver.resolve(ref: roadRef, country: country, subdivision: subdivision, roadClass: roadClass)
    }
}
