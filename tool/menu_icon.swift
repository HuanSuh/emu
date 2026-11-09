// Regenerates the menu bar icon masks of the macOS app from their sources:
//
//   swift tool/menu_icon.swift
//
//   macos/Emu/AppIcon.png        → macos/Emu/MenuIcon.png, MenuIcon@2x.png       (light menu bar)
//   macos/art/menu-icon-dark.png → macos/Emu/MenuIconDark.png, MenuIconDark@2x.png (dark / selected)
//
// Each output is an 18pt mask (18px and 36px) with alpha = ink: black for the light menu bar, white for
// the dark one, so the app only picks one by appearance (MenuIcon.swift). The light mask is the app icon's
// black ink alone (the yellow and the white drop out); the dark one is drawn separately so the face
// stays white with dark eyes instead of an inverted, hollow-eyed face. Only macOS frameworks are used,
// so no extra tool is needed; the outputs are committed and `emu app install` just copies them.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) -> (w: Int, h: Int, lum: [UInt8]) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("cannot read \(path)") }
    let w = img.width, h = img.height
    var lum = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &lum, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, lum)
}

/// Area-average downscale of a full-size alpha mask to px×px.
func shrink(_ alpha: [UInt8], _ w: Int, _ h: Int, to px: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: px * px)
    for oy in 0..<px {
        let y0 = oy * h / px, y1 = (oy + 1) * h / px
        for ox in 0..<px {
            let x0 = ox * w / px, x1 = (ox + 1) * w / px
            var sum = 0
            for y in y0..<y1 { for x in x0..<x1 { sum += Int(alpha[y * w + x]) } }
            out[oy * px + ox] = UInt8(sum / ((y1 - y0) * (x1 - x0)))
        }
    }
    return out
}

func write(_ alpha: [UInt8], _ px: Int, white: Bool, _ path: String) {
    var rgba = [UInt8](repeating: 0, count: px * px * 4) // premultiplied
    for i in 0..<(px * px) {
        let a = alpha[i], c = white ? a : 0
        rgba[i * 4] = c; rgba[i * 4 + 1] = c; rgba[i * 4 + 2] = c; rgba[i * 4 + 3] = a
    }
    let ctx = CGContext(data: &rgba, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(path)") }
    print("wrote \(path)")
}

func emit(_ alpha: [UInt8], _ w: Int, _ h: Int, _ name: String, white: Bool) {
    write(shrink(alpha, w, h, to: 18), 18, white: white, "macos/Emu/\(name).png")
    write(shrink(alpha, w, h, to: 36), 36, white: white, "macos/Emu/\(name)@2x.png")
}

let light = load("macos/Emu/AppIcon.png")
emit(light.lum.map { $0 < 70 ? 255 : 0 }, light.w, light.h, "MenuIcon", white: false) // the black ink only
let dark = load("macos/art/menu-icon-dark.png")
emit(dark.lum, dark.w, dark.h, "MenuIconDark", white: true) // white = ink
