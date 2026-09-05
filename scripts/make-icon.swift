// Renders the Difft app icon (red/cream) to a PNG.
// Usage: swift scripts/make-icon.swift <out.png> [size]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S = CGFloat(CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 1024)

let red = NSColor(red: 0.81, green: 0.13, blue: 0.18, alpha: 1)         // #CF212E
let redDark = NSColor(red: 0.64, green: 0.09, blue: 0.13, alpha: 1)     // #A31721
let cream = NSColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1)       // #FAF5EE
let creamDim = NSColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 0.55)

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Background: rounded rect, subtle vertical gradient, macOS-style inset.
let inset = S * 0.09
let bg = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let bgPath = CGPath(roundedRect: bg, cornerWidth: S * 0.16, cornerHeight: S * 0.16, transform: nil)
ctx.addPath(bgPath); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [red.cgColor, redDark.cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: S/2, y: S - inset), end: CGPoint(x: S/2, y: inset), options: [])

// Two diff columns of rounded bars meeting at a center divider.
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                       cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.fillPath()
}
let barH = S * 0.055
let gap = S * 0.105
let colL = S * 0.20          // left column x
let colRend = S * 0.80       // right column right edge
let midGap = S * 0.045       // half-gap around center divider
let baseY = S * 0.26

// center divider
ctx.setFillColor(creamDim.cgColor)
ctx.fill(CGRect(x: S/2 - S * 0.006, y: S * 0.24, width: S * 0.012, height: S * 0.40))

// left bars (old side: varying widths, right-aligned to divider)
let lw: [CGFloat] = [0.16, 0.22, 0.12, 0.20]
for (i, w) in lw.enumerated() {
    let width = S * w
    bar(S/2 - midGap - width, baseY + CGFloat(i) * gap, width, barH, i == 1 ? creamDim : cream)
}
// right bars (new side: left-aligned from divider)
let rw: [CGFloat] = [0.20, 0.13, 0.23, 0.16]
for (i, w) in rw.enumerated() {
    bar(S/2 + midGap, baseY + CGFloat(i) * gap, S * w, barH, i == 2 ? creamDim : cream)
}

// Pull-request glyph in the upper area: source dot branching into a merge
// curve that lands on a target dot.
let gy = S * 0.775                 // glyph vertical center
let lx = S * 0.38, rx = S * 0.62   // branch column x positions
let dotR = S * 0.026
let lw2 = S * 0.026
ctx.setStrokeColor(cream.cgColor)
ctx.setLineWidth(lw2)
ctx.setLineCap(.round)

// CG origin is bottom-left: +y is UP.
let topY = gy + S * 0.085
let botY = gy - S * 0.085

// left rail: top dot down to bottom dot
ctx.move(to: CGPoint(x: lx, y: topY))
ctx.addLine(to: CGPoint(x: lx, y: botY))
ctx.strokePath()
// branch elbow: horizontal from the left-top dot, crisp quarter-arc down
// into the right rail (octicon git-pull-request shape)
let elbowR = S * 0.045
ctx.move(to: CGPoint(x: lx, y: topY))
ctx.addArc(tangent1End: CGPoint(x: rx, y: topY),
           tangent2End: CGPoint(x: rx, y: botY),
           radius: elbowR)
ctx.addLine(to: CGPoint(x: rx, y: botY))
ctx.strokePath()

func dot(_ x: CGFloat, _ y: CGFloat, filled: Bool) {
    let r = dotR
    let rect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
    if filled {
        ctx.setFillColor(cream.cgColor)
        ctx.fillEllipse(in: rect)
    } else {
        ctx.setFillColor(redDark.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(cream.cgColor)
        ctx.setLineWidth(lw2)
        ctx.strokeEllipse(in: rect)
    }
}
dot(lx, topY, filled: false)   // branch tip
dot(lx, botY, filled: true)    // source commit
dot(rx, botY, filled: false)   // merge target

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
