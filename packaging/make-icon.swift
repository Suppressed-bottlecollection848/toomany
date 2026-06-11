// Renders the ProjectOpener app icon to packaging/icon_1024.png.
// Run: swift packaging/make-icon.swift
import AppKit

let canvas = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

// — Background squircle (standard macOS icon grid: 824pt with ~100pt margins)
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 186, yRadius: 186)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.75, alpha: 1).setFill()
bgPath.fill()
ctx.restoreGState()

NSGradient(colors: [
    NSColor(calibratedRed: 0.47, green: 0.55, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.66, alpha: 1),
])!.draw(in: bgPath, angle: -72)

// subtle top sheen
let sheen = NSBezierPath(roundedRect: bgRect.insetBy(dx: 26, dy: 26), xRadius: 165, yRadius: 165)
NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.22),
    NSColor.white.withAlphaComponent(0.0),
])!.draw(in: sheen, angle: -90)

// — Folder
func folderPath(body: CGRect, tabWidth: CGFloat, tabHeight: CGFloat, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    let tab = CGRect(x: body.minX, y: body.maxY - 6, width: tabWidth, height: tabHeight + 6)
    let tabPath = NSBezierPath()
    let slant: CGFloat = 42
    tabPath.move(to: CGPoint(x: tab.minX + radius, y: tab.maxY))
    tabPath.line(to: CGPoint(x: tab.maxX - slant, y: tab.maxY))
    tabPath.line(to: CGPoint(x: tab.maxX, y: tab.minY))
    tabPath.line(to: CGPoint(x: tab.minX, y: tab.minY))
    tabPath.line(to: CGPoint(x: tab.minX, y: tab.maxY - radius))
    tabPath.appendArc(withCenter: CGPoint(x: tab.minX + radius, y: tab.maxY - radius),
                      radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
    tabPath.close()
    path.append(tabPath)
    return path
}

let folderBody = CGRect(x: 232, y: 282, width: 560, height: 380)
let folder = folderPath(body: folderBody, tabWidth: 250, tabHeight: 64, radius: 36)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
              color: NSColor.black.withAlphaComponent(0.30).cgColor)
NSColor.white.setFill()
folder.fill()
ctx.restoreGState()

NSGradient(colors: [
    NSColor.white,
    NSColor(calibratedRed: 0.87, green: 0.90, blue: 1.00, alpha: 1),
])!.draw(in: folder, angle: -90)

// — Launch arrow (↗) on the folder, in the background blue
let arrowColor = NSColor(calibratedRed: 0.22, green: 0.29, blue: 0.85, alpha: 1)
arrowColor.setStroke()
arrowColor.setFill()

let center = CGPoint(x: folderBody.midX, y: folderBody.midY - 14)
let reach: CGFloat = 96
let shaft = NSBezierPath()
shaft.lineWidth = 58
shaft.lineCapStyle = .round
shaft.move(to: CGPoint(x: center.x - reach, y: center.y - reach))
shaft.line(to: CGPoint(x: center.x + reach * 0.46, y: center.y + reach * 0.46))
shaft.stroke()

let tip = CGPoint(x: center.x + reach, y: center.y + reach)
let head = NSBezierPath()
head.move(to: tip)
head.line(to: CGPoint(x: tip.x - 150, y: tip.y - 26))
head.line(to: CGPoint(x: tip.x - 26, y: tip.y - 150))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()

let outURL = URL(fileURLWithPath: "packaging/icon_1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("wrote \(outURL.path)")
