#!/usr/bin/env swift

// Renders the app icon (iOS only) into Sources/EzvpnApp/Assets.xcassets/
// AppIcon.appiconset and emits a source-of-truth icon.svg, mirroring
// ../flextunnel-ios/scripts/render-icons.swift.
//
// Run:  swift scripts/render-icons.swift
//
// Motif: a shield with a keyhole (it's a VPN) in a single bold white glyph
// over a teal-green gradient, with dark and tinted appearance variants for iOS.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024

// MARK: - Asset-catalog Contents.json model

struct Contents: Encodable {
    let images: [IconImage]
    let info: Info
}

struct IconImage: Encodable {
    let appearances: [Appearance]?
    let filename: String
    let idiom: String
    let platform: String?
    let size: String
}

struct Appearance: Encodable {
    let appearance: String
    let value: String
}

struct Info: Encodable {
    let author: String
    let version: Int
}

// MARK: - Paths

func absoluteURL(for path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    return url.path.hasPrefix("/")
        ? url
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
}

let repoRoot = absoluteURL(for: CommandLine.arguments[0])
    .standardizedFileURL
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root
let outDir = repoRoot.appendingPathComponent("Sources/EzvpnApp/Assets.xcassets/AppIcon.appiconset")

// MARK: - Shared geometry (CG coordinates, origin bottom-left, y up)

let S = Double(canvas)
let cx = S / 2

// Shield outline: flat-ish top, straight sides, tapering to a bottom point.
let shieldTop = S * 0.79
let shieldShoulder = S * 0.75   // y of the top corners
let shieldWaist = S * 0.50      // y where the sides start curving inward
let shieldBottom = S * 0.21     // bottom point
let shieldHalfW = S * 0.26

// Keyhole: circle + flaring stem, filled.
let keyholeCY = S * 0.55
let keyholeR = S * 0.065
let stemTopY = S * 0.545
let stemBottomY = S * 0.40
let stemTopHalfW = S * 0.028
let stemBottomHalfW = S * 0.052

let shieldStroke = S * 0.05

// MARK: - Drawing

func makeContext(size: Int) -> CGContext {
    CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 4 * size,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func savePNG(_ context: CGContext, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func fillGradient(in context: CGContext, size: Int, top: CGColor, bottom: CGColor) {
    let s = CGFloat(size)
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
}

func shieldPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx, y: shieldTop))
    p.addQuadCurve(
        to: CGPoint(x: cx + shieldHalfW, y: shieldShoulder),
        control: CGPoint(x: cx + shieldHalfW * 0.55, y: shieldTop))
    p.addLine(to: CGPoint(x: cx + shieldHalfW, y: shieldWaist))
    p.addQuadCurve(
        to: CGPoint(x: cx, y: shieldBottom),
        control: CGPoint(x: cx + shieldHalfW, y: S * 0.30))
    p.addQuadCurve(
        to: CGPoint(x: cx - shieldHalfW, y: shieldWaist),
        control: CGPoint(x: cx - shieldHalfW, y: S * 0.30))
    p.addLine(to: CGPoint(x: cx - shieldHalfW, y: shieldShoulder))
    p.addQuadCurve(
        to: CGPoint(x: cx, y: shieldTop),
        control: CGPoint(x: cx - shieldHalfW * 0.55, y: shieldTop))
    p.closeSubpath()
    return p
}

func keyholePath() -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(
        x: cx - keyholeR, y: keyholeCY - keyholeR,
        width: 2 * keyholeR, height: 2 * keyholeR))
    p.move(to: CGPoint(x: cx - stemTopHalfW, y: stemTopY))
    p.addLine(to: CGPoint(x: cx + stemTopHalfW, y: stemTopY))
    p.addLine(to: CGPoint(x: cx + stemBottomHalfW, y: stemBottomY))
    p.addLine(to: CGPoint(x: cx - stemBottomHalfW, y: stemBottomY))
    p.closeSubpath()
    return p
}

/// A shield with a keyhole — the classic VPN glyph: stroked shield outline,
/// filled keyhole (circle + flaring stem) at its center.
func drawShield(in context: CGContext, color: CGColor) {
    context.saveGState()

    context.setStrokeColor(color)
    context.setLineWidth(shieldStroke)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.addPath(shieldPath())
    context.strokePath()

    context.setFillColor(color)
    context.addPath(keyholePath())
    context.fillPath()

    context.restoreGState()
}

func render(filename: String, background: (top: CGColor, bottom: CGColor)?, glyph: CGColor) {
    let context = makeContext(size: canvas)
    if let background {
        fillGradient(in: context, size: canvas, top: background.top, bottom: background.bottom)
    } else {
        context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    }
    drawShield(in: context, color: glyph)
    savePNG(context, to: outDir.appendingPathComponent(filename))
}

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: 1)
}
let white = rgb(1, 1, 1)

// MARK: - SVG source of truth

/// Flip a CG y (origin bottom-left) into SVG's top-left origin.
func sy(_ y: Double) -> Double { S - y }

func writeSVG(to url: URL) throws {
    let shield = """
    M \(cx) \(sy(shieldTop)) \
    Q \(cx + shieldHalfW * 0.55) \(sy(shieldTop)) \(cx + shieldHalfW) \(sy(shieldShoulder)) \
    L \(cx + shieldHalfW) \(sy(shieldWaist)) \
    Q \(cx + shieldHalfW) \(sy(S * 0.30)) \(cx) \(sy(shieldBottom)) \
    Q \(cx - shieldHalfW) \(sy(S * 0.30)) \(cx - shieldHalfW) \(sy(shieldWaist)) \
    L \(cx - shieldHalfW) \(sy(shieldShoulder)) \
    Q \(cx - shieldHalfW * 0.55) \(sy(shieldTop)) \(cx) \(sy(shieldTop)) \
    Z
    """
    let stem = """
    M \(cx - stemTopHalfW) \(sy(stemTopY)) \
    L \(cx + stemTopHalfW) \(sy(stemTopY)) \
    L \(cx + stemBottomHalfW) \(sy(stemBottomY)) \
    L \(cx - stemBottomHalfW) \(sy(stemBottomY)) \
    Z
    """
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="\(canvas)" height="\(canvas)" viewBox="0 0 \(canvas) \(canvas)">
      <defs>
        <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0" stop-color="rgb(7%,65%,51%)"/>
          <stop offset="1" stop-color="rgb(2%,40%,36%)"/>
        </linearGradient>
      </defs>
      <rect width="\(canvas)" height="\(canvas)" fill="url(#bg)"/>
      <path d="\(shield)" fill="none" stroke="white" stroke-width="\(shieldStroke)" stroke-linejoin="round" stroke-linecap="round"/>
      <circle cx="\(cx)" cy="\(sy(keyholeCY))" r="\(keyholeR)" fill="white"/>
      <path d="\(stem)" fill="white"/>
    </svg>

    """
    try svg.data(using: .utf8)!.write(to: url, options: .atomic)
}

// MARK: - Contents.json

func writeContentsJSON() throws {
    let contents = Contents(
        images: [
            IconImage(appearances: nil, filename: "icon-light.png", idiom: "universal", platform: "ios", size: "1024x1024"),
            IconImage(
                appearances: [Appearance(appearance: "luminosity", value: "dark")],
                filename: "icon-dark.png", idiom: "universal", platform: "ios", size: "1024x1024"),
            IconImage(
                appearances: [Appearance(appearance: "luminosity", value: "tinted")],
                filename: "icon-tinted.png", idiom: "universal", platform: "ios", size: "1024x1024"),
        ],
        info: Info(author: "xcode", version: 1))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(contents)
    data.append(0x0A)
    try data.write(to: outDir.appendingPathComponent("Contents.json"), options: .atomic)
}

// MARK: - Run

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

render(filename: "icon-light.png", background: (rgb(0.07, 0.65, 0.51), rgb(0.02, 0.40, 0.36)), glyph: white)
render(filename: "icon-dark.png", background: (rgb(0.06, 0.20, 0.18), rgb(0.02, 0.09, 0.08)), glyph: rgb(0.80, 0.98, 0.92))
render(filename: "icon-tinted.png", background: nil, glyph: white)
try writeSVG(to: repoRoot.appendingPathComponent("icon.svg"))
try writeContentsJSON()

print("rendered icons to \(outDir.path)")
