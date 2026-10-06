import Foundation
import UIKit

/// MapMap road-number badges (SPEC 4.5 and 5.5) as `UIImage`s, composed from the sign vectors
/// in this module's `Signs.xcassets` (lane 3's native assets, copied by
/// `map-assets/signs/generate-car.mjs`): the shield blank drawn in horizontal slices (its
/// stretch regions widen to fit the text, everything else keeps its shape), the halo on dark
/// surfaces, and the text as glyph vectors placed on the cap grid. No font is involved
/// anywhere, and the images keep their true colours (never template rendering).
public enum RoadRefImage {

    /// CarPlay's limit for a text attachment in a manoeuvre instruction
    /// (`CPManeuver.attributedInstructionVariants`: "The maximum text attachment image size is
    /// 64x25 points").
    public static let carPlayMaxSize = CGSize(width: 64, height: 25)

    /// The badge height on CarPlay: 23 pt plus its 1 pt halo on each side fills the 25 pt
    /// attachment limit. SPEC 5.5 asks for 32; CarPlay cannot show more than 25.
    public static let carPlayHeight: CGFloat = 23

    /// The halo's opacity (SPEC 3.6: `#FFFFFF` at 90 percent).
    private static let haloAlpha: CGFloat = 0.9

    /// The badge for `ref` at `height` points on `surface`, rendered at `scale` pixels per point;
    /// `nil` when nothing draws (a text-only ref, an unknown template or a character with no
    /// glyph).
    public static func image(for ref: RoadRef, height: CGFloat = 32, surface: BadgeSurface = .dark, scale: CGFloat = 3) -> UIImage? {
        guard let layout = RoadRefBadgeLayouts.layout(ref, height: Double(height), surface: surface) else { return nil }
        return render(layout, padding: layout.haloPt, scale: scale)
    }

    /// The badge for a CarPlay manoeuvre instruction: within ``carPlayMaxSize`` (a long ref is
    /// drawn smaller rather than cropped), with a light variant (no halo) and a dark variant
    /// (white halo) registered for `UIUserInterfaceStyle`, both on the same canvas so the
    /// instruction does not shift when the panel changes appearance.
    public static func carPlayImage(for ref: RoadRef, scale: CGFloat = 3) -> UIImage? {
        guard var dark = RoadRefBadgeLayouts.layout(ref, height: Double(carPlayHeight), surface: .dark) else { return nil }
        if dark.widthPt > Double(carPlayMaxSize.width) {
            // Width is linear in the height (the stretch is in template units): solve for it.
            let fitted = (Double(carPlayMaxSize.width) - 2 * dark.haloPt) / dark.width * dark.shield.height
            guard let smaller = RoadRefBadgeLayouts.layout(ref, height: fitted, surface: .dark) else { return nil }
            dark = smaller
        }
        let height = dark.unitPt * dark.shield.height
        guard let light = RoadRefBadgeLayouts.layout(ref, height: height, surface: .light),
              let darkImage = render(dark, padding: dark.haloPt, scale: scale),
              let lightImage = render(light, padding: dark.haloPt, scale: scale) else { return nil }
        let asset = UIImageAsset()
        asset.register(lightImage, with: UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light), UITraitCollection(displayScale: scale),
        ]))
        asset.register(darkImage, with: UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark), UITraitCollection(displayScale: scale),
        ]))
        // CarPlay's guidance panel is dark unless the app says otherwise, so the haloed image
        // is the one handed over; it still resolves its light variant through the asset.
        return asset.image(with: UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark), UITraitCollection(displayScale: scale),
        ]))
    }

    /// `text` with a road-number badge for each of `refs` that has one, as CarPlay text
    /// attachments; `nil` when none of them draws.
    ///
    /// A badge replaces the ref where the text already names it as a whole word (the banner's
    /// primary text is often the ref itself, e.g. `"A27"`), so the instruction does not say it
    /// twice; otherwise the badge goes in front of the text. Refs with no badge (text-only,
    /// longer than six characters) are left as they are.
    public static func attributedInstruction(_ text: String, refs: [RoadRef], badge: (RoadRef) -> UIImage? = { carPlayImage(for: $0) }) -> NSAttributedString? {
        let badges = refs.compactMap { ref in badge(ref).map { (ref, $0) } }
        guard !badges.isEmpty else { return nil }
        let body = NSMutableAttributedString(string: text)
        let prefix = NSMutableAttributedString()
        var used: [NSRange] = []
        for (ref, image) in badges {
            let attachment = NSAttributedString(attachment: NSTextAttachment(image: image))
            if let range = wholeWordRange(of: ref.source, in: body.string),
               !used.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                body.replaceCharacters(in: range, with: attachment)
                // Later ranges in the body shift by the replaced length minus one character.
                let delta = range.length - 1
                used = used.map { $0.location > range.location ? NSRange(location: $0.location - delta, length: $0.length) : $0 }
                used.append(NSRange(location: range.location, length: 1))
            } else {
                prefix.append(attachment)
                prefix.append(NSAttributedString(string: " "))
            }
        }
        prefix.append(body)
        return prefix
    }

    /// First range of `word` in `text` not touching another letter or digit.
    private static func wholeWordRange(of word: String, in text: String) -> NSRange? {
        guard !word.isEmpty else { return nil }
        let ns = text as NSString
        var from = 0
        while from < ns.length {
            let found = ns.range(of: word, options: [.literal], range: NSRange(location: from, length: ns.length - from))
            guard found.location != NSNotFound else { return nil }
            let before = found.location > 0 ? ns.character(at: found.location - 1) : nil
            let afterIndex = found.location + found.length
            let after = afterIndex < ns.length ? ns.character(at: afterIndex) : nil
            if !isWordCharacter(before), !isWordCharacter(after) { return found }
            from = found.location + 1
        }
        return nil
    }

    private static func isWordCharacter(_ unit: unichar?) -> Bool {
        guard let unit, let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: - Rendering

    /// Renders `layout` on a canvas `padding` points wider on every side than the blank (at
    /// least the halo).
    static func render(_ layout: RoadRefBadgeLayout, padding: Double, scale: CGFloat) -> UIImage? {
        guard let face = UIImage(named: layout.shield.image, in: .module, compatibleWith: nil) else { return nil }
        let unit = layout.unitPt
        let size = CGSize(
            width: layout.width * unit + 2 * padding,
            height: layout.shield.height * unit + 2 * padding)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        var missingGlyph = false

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            let origin = padding
            let slices = layout.slices

            // Band i of the badge in points: interior edges snapped to whole pixels so adjacent
            // bands tile exactly; the outer bands run to the canvas edges (the halo lies outside).
            func band(_ i: Int) -> CGRect {
                let s = slices[i]
                let snap = { (v: Double) in (v * Double(scale)).rounded() / Double(scale) }
                let left = i == 0 ? 0 : snap(origin + s.dstX0 * unit)
                let right = i == slices.count - 1 ? Double(size.width) : snap(origin + s.dstX1 * unit)
                return CGRect(x: left, y: 0, width: right - left, height: Double(size.height))
            }

            if layout.haloPt > 0 {
                let outline = parseOutline(layout.shield.outline)
                for (i, s) in slices.enumerated() {
                    let path = outline.copy() as! UIBezierPath
                    path.apply(CGAffineTransform(
                        a: s.scale * unit, b: 0, c: 0, d: unit,
                        tx: origin + (s.dstX0 - s.srcX0 * s.scale) * unit, ty: origin))
                    ctx.saveGState()
                    ctx.clip(to: band(i))
                    UIColor.white.withAlphaComponent(haloAlpha).setStroke()
                    path.lineWidth = 2 * layout.haloPt
                    path.lineJoinStyle = .round
                    path.stroke()
                    ctx.restoreGState()
                }
            }

            for (i, s) in slices.enumerated() {
                ctx.saveGState()
                ctx.clip(to: band(i))
                face.draw(in: CGRect(
                    x: origin + (s.dstX0 - s.srcX0 * s.scale) * unit,
                    y: origin,
                    width: layout.shield.width * s.scale * unit,
                    height: layout.shield.height * unit))
                ctx.restoreGState()
            }

            for g in layout.glyphs {
                let colour = UIColor(hex: g.fill)
                guard let m = g.glyph else {
                    let r = RoadRefTables.hyphenRect
                    colour.setFill()
                    ctx.fill(CGRect(
                        x: origin + (g.x + r[0] * g.scale) * unit,
                        y: origin + (g.y + r[1] * g.scale) * unit,
                        width: (r[2] - r[0]) * g.scale * unit,
                        height: (r[3] - r[1]) * g.scale * unit))
                    continue
                }
                guard let glyph = UIImage(named: m.image, in: .module, compatibleWith: nil) else {
                    missingGlyph = true
                    continue
                }
                // The image carries `glyphPad` of margin on every side (so rounds that
                // overshoot the cap grid are not clipped at its viewBox): place its padded box.
                let pad = RoadRefTables.glyphPad * g.scale
                let rect = CGRect(
                    x: origin + (g.x - pad) * unit,
                    y: origin + (g.y + m.top * g.scale - pad) * unit,
                    width: (m.advance * g.scale + 2 * pad) * unit,
                    height: ((m.bottom - m.top) * g.scale + 2 * pad) * unit)
                // The glyph vectors are black; draw them in the slot's colour.
                ctx.saveGState()
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                glyph.draw(in: rect)
                ctx.setBlendMode(.sourceIn)
                colour.setFill()
                ctx.fill(rect)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
        return missingGlyph ? nil : image.withRenderingMode(.alwaysOriginal)
    }

    /// An outline from `generate-car.mjs`: absolute `M x y`, `L x y`, `C x1 y1 x2 y2 x y`, `Z`.
    static func parseOutline(_ d: String) -> UIBezierPath {
        let path = UIBezierPath()
        let pattern = try! NSRegularExpression(pattern: "[MLCZ]|-?(?:\\d+\\.?\\d*|\\.\\d+)(?:e[-+]?\\d+)?", options: [.caseInsensitive])
        let tokens = pattern.matches(in: d, range: NSRange(d.startIndex..., in: d)).compactMap { Range($0.range, in: d).map { String(d[$0]) } }
        var i = 0
        func n() -> CGFloat {
            defer { i += 1 }
            return CGFloat(Double(tokens[i]) ?? 0)
        }
        func point() -> CGPoint { CGPoint(x: n(), y: n()) }
        while i < tokens.count {
            let command = tokens[i]
            i += 1
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "C":
                let c1 = point(), c2 = point(), end = point()
                path.addCurve(to: end, controlPoint1: c1, controlPoint2: c2)
            case "Z": path.close()
            default: break
            }
        }
        return path
    }
}

private extension UIColor {
    /// `#RRGGBB` (the sign layout's slot fills).
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}
