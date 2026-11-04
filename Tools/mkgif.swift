// mkgif.swift — 把几段 HEVC-alpha 动画拼成 README 用的 GIF 帧序列
//
// 为什么要自己写：ffmpeg 解不了 Apple 的 HEVC with alpha（alpha 会丢），
// 所以用 AVFoundation 解码、Core Graphics 合成，最后交给 ffmpeg 做调色板转 GIF。
//
// 用法：
//   swiftc -O Tools/mkgif.swift -o .build/mkgif
//   .build/mkgif --out /tmp/frames --fps 12 --canvas 720x405 \
//       --segments "待机呼吸休闲.mov,0,2.0;点击回应-元气挥手.mov,0,5.5"
//
// 参数：
//   --segments  分号分隔的「文件,起点秒,时长秒」，文件可写相对 animations 目录的名字
//   --animdir   片段所在目录（默认 Resources/characters/dsh/animations）
//   --fps       输出帧率（默认 12，GIF 够用且体积小）
//   --canvas    WxH，默认 720x405
//   --petHeight 角色实际占位高度（像素，按不透明像素算），默认 190
//   --bottom    脚底距画面底部，默认 34
//   --bg1/--bg2 背景纵向渐变的两端颜色
//   --out       帧输出目录（会清空重建）
//   --clicks    可选，分号分隔的「秒,x,y」：在该时刻于 (x,y) 画一次点击（会补光标移动 + 涟漪）

import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 参数

func arg(_ name: String, _ def: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--" + name), i + 1 < a.count { return a[i + 1] }
    return def
}

let outDir = arg("out", "/tmp/mkgif-frames")
let fps = Double(arg("fps", "12"))!
let animDir = arg("animdir", "Resources/characters/dsh/animations")
let canvasParts = arg("canvas", "720x405").split(separator: "x").map { Int($0)! }
let canvasW = canvasParts[0], canvasH = canvasParts[1]
let petHeight = Double(arg("petHeight", "190"))!
let bottomInset = Double(arg("bottom", "34"))!
let bg1 = hexColor(arg("bg1", "#FBFCFD"))
let bg2 = hexColor(arg("bg2", "#E4E9EF"))

struct Seg { let url: URL; let start: Double; let dur: Double }

let segs: [Seg] = arg("segments", "").split(separator: ";").compactMap { raw -> Seg? in
    let f = raw.split(separator: ",").map(String.init)
    guard f.count >= 3, let s = Double(f[1]), let d = Double(f[2]) else { return nil }
    let u = f[0].hasPrefix("/") ? URL(fileURLWithPath: f[0])
                                  : URL(fileURLWithPath: "\(animDir)/\(f[0])")
    return Seg(url: u, start: s, dur: d)
}
guard !segs.isEmpty else { FileHandle.standardError.write(Data("没有 --segments\n".utf8)); exit(1) }

func hexColor(_ s: String) -> CGColor {
    var h = s.replacingOccurrences(of: "#", with: "")
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    let v = UInt32(h, radix: 16) ?? 0xFFFFFF
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

// MARK: - 输出目录

let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext() -> CGContext {
    CGContext(data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8,
              bytesPerRow: 0, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// 背景 + 地面投影 + 身后柔光，先画一次存成模板，逐帧只画宠物
func drawBackdrop(_ ctx: CGContext) {
    let grad = CGGradient(colorsSpace: colorSpace, colors: [bg1, bg2] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(canvasH)),
                           end: CGPoint(x: 0, y: 0), options: [])

    // 宠物身后的柔光，让轮廓从背景里浮起来
    let cx = CGFloat(canvasW) / 2
    let glow = CGGradient(colorsSpace: colorSpace,
                          colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85),
                                   CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: cx, y: CGFloat(canvasH) * 0.55), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: CGFloat(canvasH) * 0.55), endRadius: CGFloat(canvasH) * 0.62,
                           options: [])

    // 地面投影：椭圆 + 由中心向外衰减
    let sw = CGFloat(petHeight) * 0.62
    let sh = sw * 0.11
    let rect = CGRect(x: cx - sw / 2, y: CGFloat(bottomInset) - sh * 1.1, width: sw, height: sh * 2)
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    let shadow = CGGradient(colorsSpace: colorSpace,
                            colors: [CGColor(srgbRed: 0.31, green: 0.36, blue: 0.44, alpha: 0.30),
                                     CGColor(srgbRed: 0.31, green: 0.36, blue: 0.44, alpha: 0)] as CFArray,
                            locations: [0, 1])!
    ctx.drawRadialGradient(shadow,
                           startCenter: CGPoint(x: cx, y: rect.midY), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: rect.midY), endRadius: rect.width / 2,
                           options: [])
    ctx.restoreGState()
}

let backdrop = makeContext()
drawBackdrop(backdrop)
let backdropImage = backdrop.makeImage()!

// MARK: - 逐段解码

var frameIndex = 0

/// 角色在 640×360 画布里只占中间一小块，直接按画布尺寸缩放会小得离谱。
/// 这里量一次不透明像素的包围盒，所有帧共用同一个参考框，缩放和落点才不会跳。
func alphaBBox(_ cg: CGImage) -> CGRect? {
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let base = ctx.data else { return nil }
    let p = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            if p[(y * w + x) * 4 + 3] > 12 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX else { return nil }
    // CGContext 原点在左下，转成「从上往下」的图像坐标，和肉眼看的一致
    return CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

var refBBox: CGRect?

// MARK: - 光标 / 点击涟漪

struct Click { let t: Double; let x: Double; let y: Double }

let clicks: [Click] = arg("clicks", "").split(separator: ";").compactMap { raw in
    let f = raw.split(separator: ",").map(String.init)
    guard f.count >= 3, let t = Double(f[0]), let x = Double(f[1]), let y = Double(f[2]) else { return nil }
    return Click(t: t, x: x, y: y)
}

FileHandle.standardError.write(Data("clicks=\(clicks.count) fps=\(fps)\n".utf8))

func drawCursor(_ ctx: CGContext, at p: CGPoint) {
    // 经典 macOS 箭头：白底黑边（放大 2.2 倍，不然 760px 画布上小得看不见）
    let k: CGFloat = 2.2
    let pts: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -15.5), CGPoint(x: 4.2, y: -11.8),
        CGPoint(x: 6.6, y: -17.2), CGPoint(x: 9.4, y: -16.0), CGPoint(x: 7.0, y: -10.6),
        CGPoint(x: 12.2, y: -10.4)
    ].map { CGPoint(x: $0.x * k, y: $0.y * k) }

    func trace(_ dx: CGFloat, _ dy: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.x + pts[0].x + dx, y: p.y + pts[0].y + dy))
        for q in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x + q.x + dx, y: p.y + q.y + dy)) }
        path.closeSubpath()
        return path
    }

    ctx.saveGState()
    // 投影，让箭头在浅色背景和角色身上都看得出来
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(trace(0, 0))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.98))
    ctx.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 0.92))
    ctx.setLineWidth(1.6)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
}

func drawClicks(_ ctx: CGContext, t: Double) {
    for c in clicks {        let beginMove = c.t - 0.55
        let endFade = c.t + 0.75
        guard t >= beginMove, t <= endFade else { continue }

        let target = CGPoint(x: c.x, y: CGFloat(canvasH) - c.y)   // 参数用左上原点，转成 CG 坐标
        let from = CGPoint(x: target.x + 110, y: target.y - 70)
        let moveP = max(0, min(1, (t - beginMove) / 0.55))
        let ease = 1 - pow(1 - moveP, 3)
        let pos = CGPoint(x: from.x + (target.x - from.x) * ease,
                          y: from.y + (target.y - from.y) * ease)

        // 点击涟漪：两圈由内向外扩散的环
        let age = t - c.t
        if age >= 0, age <= 0.42 {
            let p = CGFloat(age / 0.42)
            for k in 0..<2 {
                let r = 8 + p * 46 + CGFloat(k) * 12
                let a = 0.9 * (1 - p) * (k == 0 ? 1 : 0.6)
                let rect = CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)
                // 白环打底 + 蓝环压上：深色头发和浅色背景上都看得见
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a * 0.95))
                ctx.setLineWidth(k == 0 ? 5.5 : 4.0)
                ctx.strokeEllipse(in: rect)
                ctx.setStrokeColor(CGColor(srgbRed: 0.11, green: 0.31, blue: 0.64, alpha: a))
                ctx.setLineWidth(k == 0 ? 2.6 : 1.8)
                ctx.strokeEllipse(in: rect)
            }
        }

        // 松手后光标淡出
        let fade = t > c.t + 0.35 ? max(0, 1 - (t - c.t - 0.35) / 0.4) : 1.0
        ctx.saveGState()
        ctx.setAlpha(CGFloat(fade))
        drawCursor(ctx, at: pos)
        ctx.restoreGState()
    }
}

func writeFrame(_ pet: CGImage) {
    if refBBox == nil { refBBox = alphaBBox(pet) }
    let box = refBBox ?? CGRect(x: 0, y: 0, width: pet.width, height: pet.height)

    let ctx = makeContext()
    ctx.draw(backdropImage, in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

    let s = CGFloat(petHeight) / box.height
    let drawW = CGFloat(pet.width) * s
    let drawH = CGFloat(pet.height) * s
    // 让参考框的底边落在 bottomInset、水平中心落在画布中心
    let x0 = CGFloat(canvasW) / 2 - (box.midX) * s
    let y0 = CGFloat(bottomInset) - (CGFloat(pet.height) - box.maxY) * s

    ctx.interpolationQuality = .high
    ctx.draw(pet, in: CGRect(x: x0, y: y0, width: drawW, height: drawH))

    drawClicks(ctx, t: Double(frameIndex) / fps)

    let img = ctx.makeImage()!
    let path = String(format: "%@/%04d.png", outDir, frameIndex)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    frameIndex += 1
}

for seg in segs {
    let asset = AVURLAsset(url: seg.url)
    guard let track = asset.tracks(withMediaType: .video).first else {
        FileHandle.standardError.write(Data("跳过（没有视频轨）：\(seg.url.lastPathComponent)\n".utf8))
        continue
    }
    let reader = try! AVAssetReader(asset: asset)
    let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()

    let segEnd = seg.start + seg.dur
    var nextEmit = seg.start

    while let sb = output.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if pts + 0.0001 < nextEmit { continue }
        if pts > segEnd { break }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        guard let cg = makeCGImage(from: pb) else { continue }
        writeFrame(cg)
        nextEmit += 1.0 / fps
    }
    reader.cancelReading()
}

func makeCGImage(from pb: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bytesPerRow, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    return ctx.makeImage()
}

print("输出 \(frameIndex) 帧 → \(outDir)")
