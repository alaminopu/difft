// Renders the Difft app icon to a PNG.
// Usage: swift scripts/make-icon.swift <out.png> [size]
//
// The app's own dark diff, as an object: a graphite card with one line taken
// out and one put in, the old revision as a sheet of glass fanned out behind
// it, and the tick of a finished review. The tile runs from mint through teal
// into deep blue, lit from above with a rim like the system's icons. An
// earlier pass put the same card on the app's periwinkle, and graphite on
// muted indigo was dull; the mint is there to set the dark card off. What
// survives at 16px is the point: a dark card with a red band over a green one.
import AppKit
import SwiftUI

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S = CGFloat(CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 1024)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Top-left coordinates in, CoreGraphics' bottom-left out.
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x * S, y: S - (y + h) * S, width: w * S, height: h * S)
}

/// The continuous corner macOS icons have, from the system's own shape — a
/// plain rounded rectangle meets its sides at a visible kink at this size.
func squircle(in r: CGRect) -> CGPath {
    RoundedRectangle(cornerRadius: r.width * 0.2237, style: .continuous).path(in: r).cgPath
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(radius * S, r.height / 2),
           cornerHeight: min(radius * S, r.height / 2), transform: nil)
}

// MARK: Tile

// Apple's grid: an 824pt body in a 1024pt canvas, leaving room for the shadow.
let tile = squircle(in: rect(0.0977, 0.0977, 0.8046, 0.8046))

func linear(_ colors: [CGColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: CGPoint(x: from.x * S, y: S - from.y * S),
                           end: CGPoint(x: to.x * S, y: S - to.y * S), options: [])
}
func glow(_ color: CGColor, at c: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    let p = CGPoint(x: c.x * S, y: S - c.y * S)
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius * S, options: [])
}
/// A lit edge: bright where the light lands, falling to a faint shade below.
func rim(_ path: CGPath, width: CGFloat, top: CGFloat, bottom: CGFloat, from: CGFloat, to: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.addPath(path)
    ctx.setLineWidth(width * S * 2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear([rgb(0xFFFFFF, top), rgb(0xFFFFFF, 0), rgb(0x000000, bottom)], [0, 0.5, 1],
           from: CGPoint(x: 0.5, y: from), to: CGPoint(x: 0.5, y: to))
    ctx.restoreGState()
}

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: rgb(0x0B0A2A, 0.5))
ctx.addPath(tile)
ctx.setFillColor(rgb(0x0E8FC2))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
linear([rgb(0x5CF2C8), rgb(0x14C9A8), rgb(0x0E8FC2), rgb(0x1D3FB8)], [0, 0.36, 0.72, 1],
       from: CGPoint(x: 0.20, y: 0.08), to: CGPoint(x: 0.82, y: 0.94))
// Blue pooling in the far corner and a lime light from the side, so the tile
// reads as a lit surface and not a swatch.
glow(rgb(0x3D4BFF, 0.60), at: CGPoint(x: 0.88, y: 0.90), radius: 0.55)
glow(rgb(0xB6FF8A, 0.35), at: CGPoint(x: 0.12, y: 0.62), radius: 0.40)
glow(rgb(0xFFFFFF, 0.18), at: CGPoint(x: 0.34, y: 0.04), radius: 0.60)
ctx.restoreGState()
rim(tile, width: 0.007, top: 0.55, bottom: 0.25, from: 0.0977, to: 0.9023)

// MARK: The old revision

// A sheet of frosted glass fanned out behind the card from its foot.
let card = rect(0.245, 0.205, 0.51, 0.56)
ctx.saveGState()
ctx.translateBy(x: card.midX, y: card.minY)
ctx.rotate(by: 0.15)
ctx.translateBy(x: -card.midX - S * 0.012, y: -card.minY)
let sheet = rounded(card, 0.05)
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: rgb(0x120B4A, 0.35))
ctx.addPath(sheet)
ctx.setFillColor(rgb(0xFFFFFF, 0.30))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.addPath(sheet)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.45))
ctx.setLineWidth(S * 0.004)
ctx.strokePath()
ctx.restoreGState()

// MARK: Card

let cardPath = rounded(card, 0.05)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.026), blur: S * 0.06, color: rgb(0x0A0633, 0.6))
ctx.addPath(cardPath)
ctx.setFillColor(rgb(0x15181D))
ctx.fillPath()
ctx.restoreGState()

// Five lines of code; the second has been taken out, the third put in.
ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()
linear([rgb(0x1B2230), rgb(0x0A0E16)], [0, 1], from: CGPoint(x: 0.5, y: 0.205), to: CGPoint(x: 0.5, y: 0.765))

let rowH: CGFloat = 0.086
let firstRow: CGFloat = 0.250
let ink = rgb(0x3E4A60)
let gutter: CGFloat = 0.075
let lineX: CGFloat = 0.245 + gutter + 0.028

func line(row: Int, width: CGFloat, color: CGColor, indent: CGFloat = 0, lit: Bool = false) {
    let y = firstRow + CGFloat(row) * rowH
    ctx.saveGState()
    // Changed lines give off a little of their own light.
    if lit { ctx.setShadow(offset: .zero, blur: S * 0.022, color: color.copy(alpha: 0.85)) }
    ctx.addPath(rounded(rect(lineX + indent, y + 0.026, width, 0.034), 0.017))
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}
func band(row: Int, color: UInt32, alpha: CGFloat) {
    let y = firstRow + CGFloat(row) * rowH
    ctx.setFillColor(rgb(color, alpha))
    ctx.fill(rect(0.245, y, 0.51, rowH))
    ctx.setFillColor(rgb(color, alpha * 0.8))
    ctx.fill(rect(0.245, y, gutter, rowH))
}
/// The − and + in the gutter. `plus` adds the upright.
func sign(row: Int, color: CGColor, plus: Bool) {
    let c = CGPoint(x: (0.245 + gutter / 2 + 0.004) * S, y: S - (firstRow + (CGFloat(row) + 0.5) * rowH) * S)
    let arm = S * 0.017
    ctx.setStrokeColor(color)
    ctx.setLineWidth(S * 0.011)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: c.x - arm, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + arm, y: c.y))
    if plus { ctx.move(to: CGPoint(x: c.x, y: c.y - arm)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + arm)) }
    ctx.strokePath()
}

line(row: 0, width: 0.27, color: ink)
band(row: 1, color: 0xFF4B40, alpha: 0.24)
sign(row: 1, color: rgb(0xFF6B61), plus: false)
line(row: 1, width: 0.21, color: rgb(0xFF6B61), indent: 0.04, lit: true)
band(row: 2, color: 0x2BFFA0, alpha: 0.20)
sign(row: 2, color: rgb(0x4DFFB0), plus: true)
line(row: 2, width: 0.30, color: rgb(0x4DFFB0), indent: 0.04, lit: true)
line(row: 3, width: 0.18, color: ink, indent: 0.04)
line(row: 4, width: 0.24, color: ink)
// Light catching the top of the card.
glow(rgb(0x9DB4FF, 0.16), at: CGPoint(x: 0.36, y: 0.205), radius: 0.30)
ctx.restoreGState()
rim(cardPath, width: 0.004, top: 0.38, bottom: 0, from: 0.205, to: 0.765)

// MARK: Tick

// The review, finished. It overlaps the card's corner so the two read as one
// mark rather than a card with a sticker beside it.
let badge = rect(0.580, 0.580, 0.26, 0.26)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.014), blur: S * 0.04, color: rgb(0x0A0633, 0.55))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: badge)
ctx.restoreGState()

let inner = badge.insetBy(dx: S * 0.020, dy: S * 0.020)
ctx.saveGState()
ctx.addEllipse(in: inner)
ctx.clip()
linear([rgb(0xFFFFFF), rgb(0xF2F6FF), rgb(0xD9E2FF)], [0, 0.5, 1],
       from: CGPoint(x: 0.64, y: 0.60), to: CGPoint(x: 0.78, y: 0.84))
glow(rgb(0xFFFFFF, 0.22), at: CGPoint(x: 0.67, y: 0.61), radius: 0.10)
ctx.restoreGState()
rim(CGPath(ellipseIn: inner, transform: nil), width: 0.004, top: 0.5, bottom: 0.2, from: 0.60, to: 0.82)

ctx.saveGState()
ctx.setStrokeColor(rgb(0x0C9C7A))
ctx.setLineWidth(S * 0.036)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: inner.minX + inner.width * 0.27, y: inner.minY + inner.height * 0.50))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.44, y: inner.minY + inner.height * 0.33))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.74, y: inner.minY + inner.height * 0.67))
ctx.strokePath()
ctx.restoreGState()

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
