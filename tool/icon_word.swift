// Replaces the word inside the app icon's ring in place, keeping the ring,
// the plate and the colour, for every size that has a word (those that are
// only the ring are left alone). The icons have no other source.
//
//   FONT=NotoSans-Regular.ttf swift tool/icon_word.swift 'wɪspə' <png|ico>...
//
// Noto Sans Regular (OFL, notofonts.github.io) has the phonetic letters. The
// x-height is 0.27 of the ring's inner radius (XHEIGHT; the old word's was
// 0.2214), its middle where the old word's was, a little above the centre;
// the colour is #464A51 (INK; the old word's was #60646C). Letters are set
// by their ink, the same gap apart. An .ico keeps its PNG or 32-bit BMP
// entries as they were. Afterwards, files that had no alpha channel (iOS,
// assets/app_icon.png) must be made opaque again: the App Store refuses the
// 1024 one with alpha.
import AppKit
import CoreText
import Foundation

let args = CommandLine.arguments
let word = args[1]
let fontURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FONT"]!) as CFURL
let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(fontURL) as! [CTFontDescriptor])[0]
let font = CTFontCreateWithFontDescriptor(descriptor, 100, nil)
let xHeightPerPoint = CTFontGetXHeight(font) / 100
/// Between the ink of two letters, of the x-height: as loose as the old word.
let gapPerXHeight = 0.36
let env = ProcessInfo.processInfo.environment
/// Of the ring's inner radius: the x-height, and where the middle of the
/// x-height sits above the centre (the old word's, kept as the word grows).
let xHeightPerRadius = Double(env["XHEIGHT"] ?? "") ?? 0.27
let xMiddlePerRadius = 0.0094
/// The word's colour, as RRGGBB.
let inkHex = UInt32(env["INK"] ?? "464A51", radix: 16)

struct Report { var changed = false; var note = "" }

func process(_ image: CGImage) -> (CGImage?, String) {
  let w = image.width, h = image.height
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, "no ctx") }
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
  // Pixel at (x, y) with y from the top.
  func px(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
    let i = ((h - 1 - y) * w + x) * 4
    let a = Double(buf[i + 3]) / 255
    if a == 0 { return (0, 0, 0, 0) }
    return (Double(buf[i]) / 255 / a, Double(buf[i + 1]) / 255 / a, Double(buf[i + 2]) / 255 / a, a)
  }
  func sat(_ p: (Double, Double, Double, Double)) -> Double {
    let mx = max(p.0, p.1, p.2), mn = min(p.0, p.1, p.2)
    return mx == 0 ? 0 : (mx - mn) / mx
  }
  func lum(_ p: (Double, Double, Double, Double)) -> Double { 0.2126 * p.0 + 0.7152 * p.1 + 0.0722 * p.2 }
  let cx = w / 2, cy = h / 2
  var ring = -1
  for x in cx..<w { let p = px(x, cy); if p.3 > 0.8 && sat(p) > 0.25 { ring = x; break } }
  if ring < 0 { return (nil, "no ring") }
  let rIn = Double(ring - cx)
  let inside = rIn * 0.96
  var count = 0, x0 = w, x1 = 0, y0 = h, y1 = 0
  var inkR = 0.0, inkG = 0.0, inkB = 0.0, inks = 0.0
  for y in 0..<h {
    for x in 0..<w {
      let dx = Double(x - cx), dy = Double(y - cy)
      if dx * dx + dy * dy > inside * inside { continue }
      let p = px(x, y)
      if p.3 < 0.8 || sat(p) > 0.2 { continue }
      let l = lum(p)
      if l > 0.8 { continue }
      count += 1
      x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
      if l < 0.62 { inkR += p.0; inkG += p.1; inkB += p.2; inks += 1 }
    }
  }
  if Double(count) < Double(w * h) * 0.002 { return (nil, "ring only (r=\(Int(rIn)))") }
  // As on the 2363 px master, where the old word was measured: small sizes
  // are a few pixels and cannot be measured well.
  let xHeight = rIn * xHeightPerRadius
  let baseline = Double(cy) + rIn * (xHeightPerRadius / 2 - xMiddlePerRadius)
  let measured = inks > 0 ? (inkR / inks, inkG / inks, inkB / inks) : (0.376, 0.392, 0.424)
  let ink = inkHex.map {
    (Double($0 >> 16 & 0xff) / 255, Double($0 >> 8 & 0xff) / 255, Double($0 & 0xff) / 255)
  } ?? measured
  let plate = px(cx, cy - Int(rIn * 0.75))
  // Clear inside the ring, leaving its antialiased inner edge.
  ctx.setFillColor(CGColor(colorSpace: space, components: [plate.0, plate.1, plate.2, 1])!)
  let clear = rIn - 1.5
  ctx.fillEllipse(in: CGRect(x: Double(cx) - clear, y: Double(h - cy) - clear, width: clear * 2, height: clear * 2))
  // The word, same x-height and baseline, centred.
  let size = xHeight / xHeightPerPoint
  let sized = CTFontCreateWithFontDescriptor(descriptor, size, nil)
  let color = CGColor(colorSpace: space, components: [ink.0, ink.1, ink.2, 1])!
  // Letter by letter, the same gap between their ink: the phonetic letters'
  // own spacing differs from the others'.
  let chars = Array(word.utf16)
  var glyphs = [CGGlyph](repeating: 0, count: chars.count)
  CTFontGetGlyphsForCharacters(sized, chars, &glyphs, chars.count)
  var boxes = [CGRect](repeating: .zero, count: glyphs.count)
  CTFontGetBoundingRectsForGlyphs(sized, .horizontal, glyphs, &boxes, glyphs.count)
  let gap = xHeight * gapPerXHeight
  let total = boxes.reduce(0) { $0 + $1.width } + gap * Double(boxes.count - 1)
  var x = Double(cx) - total / 2
  var positions = [CGPoint]()
  for box in boxes {
    positions.append(CGPoint(x: x - box.minX, y: Double(h) - baseline))
    x += box.width + gap
  }
  ctx.setFillColor(color)
  CTFontDrawGlyphs(sized, glyphs, positions, glyphs.count, ctx)
  return (ctx.makeImage(), "word: x-height \(Int(xHeight)) px, size \(String(format: "%.1f", size)), ring r=\(Int(rIn)), old \(x1 - x0)x\(y1 - y0)")
}

func loadPNG(_ data: Data) -> CGImage? {
  guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func pngData(_ image: CGImage) -> Data {
  let out = NSMutableData()
  let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
  return out as Data
}

// A 32-bit DIB entry of an .ico: BITMAPINFOHEADER, BGRA rows bottom-up, AND mask.
func decodeDIB(_ d: Data) -> CGImage? {
  let header = d.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
  let w = Int(d.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) })
  let bpp = d.withUnsafeBytes { $0.load(fromByteOffset: 14, as: UInt16.self) }
  guard bpp == 32 else { return nil }
  let h = w
  var rgba = [UInt8](repeating: 0, count: w * h * 4)
  let start = Int(header)
  for y in 0..<h {
    for x in 0..<w {
      let s = start + ((h - 1 - y) * w + x) * 4
      let b = d[d.startIndex + s], g = d[d.startIndex + s + 1], r = d[d.startIndex + s + 2], a = d[d.startIndex + s + 3]
      let o = (y * w + x) * 4
      rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = b; rgba[o + 3] = a
    }
  }
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let provider = CGDataProvider(data: Data(rgba) as CFData)!
  return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                 decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

func encodeDIB(_ image: CGImage) -> Data {
  let w = image.width, h = image.height
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
  var out = Data()
  func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
  func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
  func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
  u32(40); i32(Int32(w)); i32(Int32(h * 2)); u16(1); u16(32); u32(0); u32(0); i32(0); i32(0); u32(0); u32(0)
  // CG rows are top-down in memory for this context; DIB rows bottom-up, straight alpha BGRA.
  for y in 0..<h {
    let row = h - 1 - y
    for x in 0..<w {
      let i = (row * w + x) * 4
      let a = buf[i + 3]
      func un(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a))) }
      out.append(contentsOf: [un(buf[i + 2]), un(buf[i + 1]), un(buf[i]), a])
    }
  }
  let maskRow = ((w + 31) / 32) * 4
  out.append(contentsOf: [UInt8](repeating: 0, count: maskRow * h))
  return out
}

for path in args.dropFirst(2) {
  let url = URL(fileURLWithPath: path)
  let data = try! Data(contentsOf: url)
  if path.hasSuffix(".png") {
    let (out, note) = process(loadPNG(data)!)
    print("\(path): \(note)")
    if let out { try! pngData(out).write(to: url) }
    continue
  }
  // .ico
  let n = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) })
  var entries: [(dir: Data, body: Data)] = []
  for i in 0..<n {
    let dir = data.subdata(in: (6 + 16 * i)..<(22 + 16 * i))
    let size = Int(dir.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) })
    let off = Int(dir.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
    var body = data.subdata(in: off..<(off + size))
    let isPNG = body.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
    let image = isPNG ? loadPNG(body) : decodeDIB(body)
    if let image {
      let (out, note) = process(image)
      print("\(path) [\(image.width)]: \(note)")
      if let out { body = isPNG ? pngData(out) : encodeDIB(out) }
    }
    entries.append((dir, body))
  }
  var out = data.prefix(6)
  var offset = 6 + 16 * n
  for e in entries {
    var dir = e.dir
    dir.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(e.body.count).littleEndian) { Data($0) })
    dir.replaceSubrange(12..<16, with: withUnsafeBytes(of: UInt32(offset).littleEndian) { Data($0) })
    out.append(dir)
    offset += e.body.count
  }
  for e in entries { out.append(e.body) }
  try! out.write(to: url)
}
