import Foundation

/// The surface a badge sits on: on ``dark`` it gets the white halo of SPEC 3.6.
public enum BadgeSurface: Sendable {
    case light
    case dark
}

/// A text slot of a shield blank (`native/sign-layout.json` `slots.text` / `slots.legend`).
struct BadgeSlot {
    let words: [String]?
    let cx: Double
    let cy: [Double]
    let h: [Double]
    let maxw: Double
    let family: String
    let fill: String
    let minsize: Double
    /// Centre and fit the run by its tiles (advances) instead of its ink (`centre: "tiles"`).
    var centreTiles: Bool = false
    /// Slot kerning (`kern`), looked up before the family's: "LR", "L R" or "L*" to cap units.
    var kern: [String: Double] = [:]
    /// Vertical band (template units) the ink must stay inside; nil = no limit.
    var ymin: Double? = nil
    var ymax: Double? = nil
}

/// A family's word space and pair kerning (`numerals|alphabet/<family>/_spacing.json`).
struct FamilySpacing {
    let space: Double?
    let kern: [String: Double]
}

/// A shield blank (`native/sign-layout.json` `shields[id]`), in template units (height 100).
struct ShieldLayout {
    /// Image name in this module's Signs.xcassets.
    let image: String
    let width: Double
    let height: Double
    /// The outer edge as absolute M / L / C / Z commands, for the halo.
    let outline: String
    /// Horizontal ranges that stretch when the text is wider than the slot.
    let stretchX: [(Double, Double)]
    let text: BadgeSlot
    let legend: BadgeSlot?
}

/// A glyph vector on the 100-unit cap grid (cap top y 0, baseline y 100): its box is x
/// `0...advance`, y `top...bottom`, and its image adds `RoadRefTables.glyphPad` of margin on every
/// side so overshooting rounds are not clipped; `inkMinX`, `inkMaxX`, `inkMinY` and `inkMaxY` bound its ink.
struct GlyphMetrics {
    let image: String
    let advance: Double
    let top: Double
    let bottom: Double
    let inkMinX: Double
    let inkMaxX: Double
    let inkMinY: Double
    let inkMaxY: Double
}

/// The geometry of one composed badge (SPEC 3.5 and 3.6, `native/sign-layout.json` rules), in
/// template units unless named `Pt`: the canonical `roadRefSvg` laid out for native drawing.
///
/// The blank is drawn in ``slices``, each a horizontal band of the blank's image mapped onto a
/// band of the badge (the stretch regions widen, everything else keeps its shape); the halo is
/// the blank's outline through the same slices; glyphs are placed on the cap grid.
struct RoadRefBadgeLayout {
    /// Maps the blank's band `srcX0...srcX1` onto the badge's `dstX0...dstX1`.
    struct Slice: Equatable {
        let srcX0: Double
        let srcX1: Double
        let dstX0: Double
        let dstX1: Double
        var scale: Double { srcX1 > srcX0 ? (dstX1 - dstX0) / (srcX1 - srcX0) : 1 }
    }

    /// A glyph whose cap-grid origin sits at (`x`, `y`) at `scale` (the canonical SVG's
    /// `translate(x y) scale(s)`). `glyph` is `nil` for the hyphen, a plain rectangle.
    struct PlacedGlyph {
        let glyph: GlyphMetrics?
        let x: Double
        let y: Double
        let scale: Double
        let fill: String
    }

    let ref: RoadRef
    let shield: ShieldLayout
    /// Badge width after stretching.
    let width: Double
    /// Points per template unit: height in points / 100.
    let unitPt: Double
    /// Halo width in points; 0 on a light surface.
    let haloPt: Double
    let slices: [Slice]
    /// Legend glyphs first, then the text, in drawing order.
    let glyphs: [PlacedGlyph]

    var haloUnits: Double { unitPt > 0 ? haloPt / unitPt : 0 }
    var widthPt: Double { width * unitPt + 2 * haloPt }
    var heightPt: Double { shield.height * unitPt + 2 * haloPt }
}

/// The badge composer's layout rules, a mirror of the canonical `layoutRoadRef`.
enum RoadRefBadgeLayouts {

    private enum RunGlyph {
        case vector(GlyphMetrics)
        /// A word space with the family's advance (`FamilySpacing.space`) or the default.
        case space(Double)
        case hyphen

        var advance: Double {
            switch self {
            case .vector(let g): return g.advance
            case .space(let a): return a
            case .hyphen: return RoadRefTables.hyphenAdvance
            }
        }

        var ink: (Double, Double)? {
            switch self {
            case .vector(let g): return (g.inkMinX, g.inkMaxX)
            case .space: return nil
            case .hyphen: return (RoadRefTables.hyphenRect[0], RoadRefTables.hyphenRect[2])
            }
        }

        var inkY: (Double, Double)? {
            switch self {
            case .vector(let g): return (g.inkMinY, g.inkMaxY)
            case .space: return nil
            case .hyphen: return (RoadRefTables.hyphenRect[1], RoadRefTables.hyphenRect[3])
            }
        }
    }

    /// How a run is centred and fitted (the canonical `CentreBy`).
    private enum Centre { case contract, ink, tiles }

    /// `fitWidth` is the ink width, or the tile width when centred by tiles, after scaling.
    private struct Run {
        let glyphs: [(RunGlyph, Double, Double, Double)]
        let fitWidth: Double
    }

    /// Halo width in points: 1 at 24 and below, 2 at 48 and above, linear between (SPEC 3.6).
    static func haloPt(_ size: Double) -> Double {
        if size <= 24 { return 1 }
        if size >= 48 { return 2 }
        return 1 + (size - 24) / 24
    }

    /// The layout of `ref` at `height` points, or `nil` when nothing draws: a text-only ref, an
    /// unknown template, or a character with no glyph.
    static func layout(_ ref: RoadRef, height: Double, surface: BadgeSurface) -> RoadRefBadgeLayout? {
        guard let templateId = ref.template, !ref.text.isEmpty,
              let shield = RoadRefTables.shields[templateId] else { return nil }
        let slot = shield.text
        let chars = ref.text.unicodeScalars.map { String($0) }
        var glyphs: [RunGlyph] = []
        for ch in chars {
            guard let g = textGlyph(family: slot.family, ch: ch) else { return nil }
            glyphs.append(g)
        }
        let gaps = runGaps(chars, fam: familySpacing(slot.family), slotKern: slot.kern)
        let centre: Centre = slot.centreTiles ? .tiles : .ink
        let h = slot.h.first ?? 50
        let contentWidth = slot.maxw
        let probe = placeRun(glyphs, gaps: gaps, cx: 0, cy: 0, h: h, maxw: 0, centre: centre)
        let regions = shield.stretchX.filter { $0.1 > $0.0 }

        var width = shield.width
        var cx = slot.cx
        var maxw = contentWidth
        var slices = [RoadRefBadgeLayout.Slice(srcX0: 0, srcX1: shield.width, dstX0: 0, dstX1: shield.width)]
        if probe.fitWidth > contentWidth, !regions.isEmpty {
            let extra = probe.fitWidth - contentWidth
            let stretch = stretchMap(regions, extra: extra)
            width = shield.width + extra
            cx = stretch(cx)
            maxw = contentWidth + extra
            slices = makeSlices(width: shield.width, regions: regions, stretch: stretch)
        }

        var placed: [RoadRefBadgeLayout.PlacedGlyph] = []
        if let legend = shield.legend, height >= legend.minsize, let words = legendGlyphs(legend, cx: cx) {
            placed += words
        }
        let text = placeRun(glyphs, gaps: gaps, cx: cx, cy: slot.cy.first ?? 50, h: h, maxw: maxw, centre: centre, ymin: slot.ymin, ymax: slot.ymax)
        placed += text.glyphs.compactMap { placedGlyph($0, fill: slot.fill) }

        return RoadRefBadgeLayout(
            ref: ref,
            shield: shield,
            width: width,
            unitPt: height / shield.height,
            haloPt: surface == .dark ? haloPt(height) : 0,
            slices: slices,
            glyphs: placed)
    }

    private static func placedGlyph(_ g: (RunGlyph, Double, Double, Double), fill: String) -> RoadRefBadgeLayout.PlacedGlyph? {
        switch g.0 {
        case .vector(let m): return .init(glyph: m, x: g.1, y: g.2, scale: g.3, fill: fill)
        case .hyphen: return .init(glyph: nil, x: g.1, y: g.2, scale: g.3, fill: fill)
        case .space: return nil
        }
    }

    private static func legendGlyphs(_ slot: BadgeSlot, cx: Double) -> [RoadRefBadgeLayout.PlacedGlyph]? {
        var out: [RoadRefBadgeLayout.PlacedGlyph] = []
        for (i, word) in (slot.words ?? []).enumerated() {
            guard let glyphs = wordGlyphs(family: slot.family, word: word) else { return nil }
            let h = i < slot.h.count ? slot.h[i] : (slot.h.first ?? 10)
            let cy = i < slot.cy.count ? slot.cy[i] : (slot.cy.first ?? 50)
            out += placeRun(glyphs, gaps: [], cx: cx, cy: cy, h: h, maxw: slot.maxw, centre: .contract)
                .glyphs.compactMap { placedGlyph($0, fill: slot.fill) }
        }
        return out
    }

    private static func chain(_ family: String) -> [String] {
        [family] + (RoadRefTables.glyphFallback[family] ?? [])
    }

    /// The first family in the fallback chain with a spacing entry (the canonical `familySpacing`).
    private static func familySpacing(_ family: String) -> FamilySpacing? {
        for f in chain(family) { if let sp = RoadRefTables.familySpacing[f] { return sp } }
        return nil
    }

    private static func kernLookup(_ key: String, slot: [String: Double], fam: [String: Double]?) -> Double {
        let wild = String(key.dropLast()) + "*"
        return slot[key] ?? slot[wild] ?? fam?[key] ?? fam?[wild] ?? 0
    }

    /// Extra advance after each glyph (the canonical `runGaps`): slot kerning, then the family's.
    private static func runGaps(_ chars: [String], fam: FamilySpacing?, slotKern: [String: Double]) -> [Double] {
        guard chars.count > 1 else { return [] }
        return (0..<(chars.count - 1)).map { i in
            let a = chars[i], b = chars[i + 1]
            if a != " " && b != " " { return kernLookup(a + b, slot: slotKern, fam: fam?.kern) }
            if a == " " && i > 0 && chars[i - 1] != " " && b != " " {
                return kernLookup(chars[i - 1] + " " + b, slot: slotKern, fam: fam?.kern)
            }
            return 0
        }
    }

    private static func textGlyph(family: String, ch: String) -> RunGlyph? {
        if ch == " " { return .space(familySpacing(family)?.space ?? RoadRefTables.defaultSpace) }
        for f in chain(family) {
            if let g = RoadRefTables.alphabets[f]?[ch] ?? RoadRefTables.numerals[f]?[ch] { return .vector(g) }
        }
        return ch == "-" ? .hyphen : nil
    }

    private static func wordGlyphs(family: String, word: String) -> [RunGlyph]? {
        for f in chain(family) {
            if let whole = RoadRefTables.numerals[f]?[word] ?? RoadRefTables.alphabets[f]?[word] { return [.vector(whole)] }
        }
        var out: [RunGlyph] = []
        for scalar in word.unicodeScalars {
            let ch = String(scalar)
            guard let g = textGlyph(family: family, ch: ch) ?? textGlyph(family: "fhwa-d", ch: ch) else { return nil }
            out.append(g)
        }
        return out
    }

    /// Glyphs on their advances plus `gaps`, centred on (`cx`, `cy`) at cap height `h`, shrunk
    /// (never stretched) so the run stays within `maxw` (0 = no cap; ink width, or tiles when
    /// centred by tiles) and the ink inside `ymin`...`ymax`. A single glyph, or a run centred by
    /// ink, centres on its ink box; `.tiles` and other runs on their advance box.
    private static func placeRun(
        _ glyphs: [RunGlyph], gaps: [Double], cx: Double, cy: Double, h: Double, maxw: Double,
        centre: Centre, ymin: Double? = nil, ymax: Double? = nil
    ) -> Run {
        var pen = 0.0
        var inkMin = Double.infinity
        var inkMax = -Double.infinity
        var inkTop = Double.infinity
        var inkBottom = -Double.infinity
        var xs: [Double] = []
        for (i, g) in glyphs.enumerated() {
            xs.append(pen)
            if let (lo, hi) = g.ink {
                inkMin = min(inkMin, pen + lo)
                inkMax = max(inkMax, pen + hi)
                if let (top, bottom) = g.inkY {
                    inkTop = min(inkTop, top)
                    inkBottom = max(inkBottom, bottom)
                }
            }
            pen += g.advance + (i < glyphs.count - 1 && i < gaps.count ? gaps[i] : 0)
        }
        guard inkMin.isFinite else { return Run(glyphs: [], fitWidth: 0) }
        let fit = centre == .tiles ? pen : inkMax - inkMin
        var s = h / 100
        if maxw > 0, fit * s > maxw { s = maxw / fit }
        if let ymin, inkTop < 50 { s = min(s, (cy - ymin) / (50 - inkTop)) }
        if let ymax, inkBottom > 50 { s = min(s, (ymax - cy) / (inkBottom - 50)) }
        let mid: Double
        switch centre {
        case .tiles: mid = pen / 2
        case .ink: mid = (inkMin + inkMax) / 2
        case .contract: mid = glyphs.count == 1 ? (inkMin + inkMax) / 2 : pen / 2
        }
        let ty = cy - 50 * s
        return Run(
            glyphs: zip(glyphs, xs).map { ($0.0, cx + ($0.1 - mid) * s, ty, s) },
            fitWidth: fit * s)
    }

    private static func stretchMap(_ regions: [(Double, Double)], extra: Double) -> (Double) -> Double {
        let each = extra / Double(regions.count)
        return { x in
            var shift = 0.0
            for (a, b) in regions {
                if x >= b { shift += each } else if x > a { shift += each * (x - a) / (b - a) }
            }
            return x + shift
        }
    }

    /// Bands of the blank between and across the stretch regions, each mapped through `stretch`.
    private static func makeSlices(width: Double, regions: [(Double, Double)], stretch: (Double) -> Double) -> [RoadRefBadgeLayout.Slice] {
        var edges = Set([0, width])
        for (a, b) in regions {
            edges.insert(min(max(a, 0), width))
            edges.insert(min(max(b, 0), width))
        }
        let sorted = edges.sorted()
        return zip(sorted, sorted.dropFirst()).filter { $0.1 > $0.0 }.map {
            RoadRefBadgeLayout.Slice(srcX0: $0.0, srcX1: $0.1, dstX0: stretch($0.0), dstX1: stretch($0.1))
        }
    }
}
