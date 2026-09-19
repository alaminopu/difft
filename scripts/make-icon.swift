// Renders the Difft app icon to a PNG.
// Usage: swift scripts/make-icon.swift <out.png> [size]
//
// A page with one line taken out and one put in, and the tick of a finished
// review, on the app's own periwinkle. The previous icon drew eight bars and a
// pull-request glyph; below 64px that was a red square with noise on it. This
// one is three shapes — tile, page, tick — and the red and green bands are
// what is left of it at 16px, which is the right thing to be left.
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

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: rgb(0x0B1030, 0.45))
ctx.addPath(tile)
ctx.setFillColor(rgb(0x4B55D6))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
let sky = CGGradient(colorsSpace: space,
                     colors: [rgb(0x93ABFF), rgb(0x6F86F7), rgb(0x3F45C4)] as CFArray,
                     locations: [0, 0.45, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: S * 0.22, y: S * 0.92),
                       end: CGPoint(x: S * 0.80, y: S * 0.06), options: [])
// A soft light from above, so the tile reads as a surface and not a swatch.
let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: S * 0.36, y: S * 0.95), startRadius: 0,
                       endCenter: CGPoint(x: S * 0.36, y: S * 0.95), endRadius: S * 0.62, options: [])
ctx.restoreGState()

// MARK: Page

let page = rect(0.235, 0.215, 0.53, 0.57)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.02), blur: S * 0.05, color: rgb(0x14195A, 0.45))
ctx.addPath(rounded(page, 0.05))
ctx.setFillColor(rgb(0xFBFCFF))
ctx.fillPath()
ctx.restoreGState()

// Five lines of code; the second has been taken out, the third put in.
ctx.saveGState()
ctx.addPath(rounded(page, 0.05))
ctx.clip()

let rowH: CGFloat = 0.086
let firstRow: CGFloat = 0.262
let ink = rgb(0xC5CBE3)
let lineX: CGFloat = 0.295

func line(row: Int, width: CGFloat, color: CGColor, indent: CGFloat = 0) {
    let y = firstRow + CGFloat(row) * rowH
    ctx.addPath(rounded(rect(lineX + indent, y + 0.024, width, 0.036), 0.018))
    ctx.setFillColor(color)
    ctx.fillPath()
}
func band(row: Int, color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(rect(0.235, firstRow + CGFloat(row) * rowH, 0.53, rowH))
}

line(row: 0, width: 0.30, color: ink)
band(row: 1, color: rgb(0xFFDAD5))
line(row: 1, width: 0.25, color: rgb(0xE5534B), indent: 0.045)
band(row: 2, color: rgb(0xCDF2DF))
line(row: 2, width: 0.345, color: rgb(0x23A06B), indent: 0.045)
line(row: 3, width: 0.21, color: ink, indent: 0.045)
line(row: 4, width: 0.27, color: ink)
ctx.restoreGState()

// MARK: Tick

// The review, finished. It overlaps the page's corner so the two read as one
// mark rather than a page with a sticker beside it.
let badge = rect(0.575, 0.585, 0.255, 0.255)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: rgb(0x0B1030, 0.4))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: badge)
ctx.restoreGState()

let inner = badge.insetBy(dx: S * 0.022, dy: S * 0.022)
ctx.saveGState()
ctx.addEllipse(in: inner)
ctx.clip()
let ink2 = CGGradient(colorsSpace: space, colors: [rgb(0x2B2F8F), rgb(0x1B1D5C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ink2, start: CGPoint(x: inner.midX, y: inner.maxY),
                       end: CGPoint(x: inner.midX, y: inner.minY), options: [])
ctx.restoreGState()

ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(S * 0.034)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: inner.minX + inner.width * 0.27, y: inner.minY + inner.height * 0.50))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.44, y: inner.minY + inner.height * 0.33))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.74, y: inner.minY + inner.height * 0.67))
ctx.strokePath()

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
