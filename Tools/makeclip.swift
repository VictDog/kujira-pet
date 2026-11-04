// makeclip —— 把「一段真实视频」变成桌宠能播的 HEVC + alpha 片段。
//
// 用法：
//   makeclip <视频/帧目录/GIF> <输出包目录> <动作名> [选项]
//
// 选项：
//   --key green|blue|auto   按纯色背景抠图（绿幕/蓝幕）
//   --matte                 用系统主体抠图逐帧抠（背景不是纯色时）
//   --fill loop|pingpong|hold|once   短片段怎么补到 10s（默认 pingpong）
//   --height 290 --bottom 28        在 640×360 里的占位
//   --start 0 --trim 0.3            起点秒数、裁掉片头片尾
//   --fps 30
//
// 逻辑：用系统框架把视频/GIF/帧序列读成 RGBA 帧 → 逐帧抠出 alpha →
// 用所有帧的并集算一次统一摆位 → AVAssetWriter 编成 HEVC with alpha 的 .mov。

import AVFoundation
import AppKit
import Vision

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 参数

var args = Array(CommandLine.arguments.dropFirst())
func takeFlag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
func takeValue(_ name: String, _ def: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let keyMode = takeValue("--key", "none")
let useMatte = takeFlag("--matte")
let reverse = takeFlag("--reverse")
let fillMode = takeValue("--fill", "pingpong")
let targetH = Double(takeValue("--height", "290")) ?? 290
// --scale 用「统一缩放系数」而不是固定高度：不同姿态（站着/趴着/悬空）
// 并集高度差很多，按固定高度缩会让角色在动作之间突然变大变小。
// 系数取自参考站姿：290 / 903 ≈ 0.321。
let scaleArg = takeValue("--scale", "")
let bottomGap = Double(takeValue("--bottom", "28")) ?? 28
let fps = Int(takeValue("--fps", "30")) ?? 30
let startSec = Double(takeValue("--start", "0")) ?? 0
let durationSec = Double(takeValue("--duration", "10.03")) ?? 10.03
// --clear x0,y0,x1,y1（归一化 0-1，原点左上）：把这块区域的 alpha 归零，
// 用来抹掉生成服务压在角上的水印。白字是纯白，绿色抠像抠不掉它。
var clearRect: CGRect? = nil
if let v = Optional(takeValue("--clear", "")) , !v.isEmpty {
    let f = v.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    if f.count == 4 { clearRect = CGRect(x: f[0], y: f[1], width: f[2] - f[0], height: f[3] - f[1]) }
    if clearRect == nil { print("! --clear 需要 x0,y0,x1,y1 四个数（0-1）"); exit(1) }
}

guard args.count >= 3 else {
    print("""
    用法: makeclip <视频/帧目录/GIF> <输出包目录> <动作名> [选项]
      --key green|blue|auto   纯色背景抠图
      --matte                 逐帧主体抠图（任意背景）
      --fill loop|pingpong|hold|once
      --reverse               帧序倒放（比如「躺下」倒过来当「起身」）
      --scale 0.321           统一缩放系数（优于 --height：保证各动作体型一致）
      --height 290 --bottom 28 --fps 30 --start 0 --duration 10.03
    """)
    exit(1)
}
let inputPath = args[0]
let packDir = URL(fileURLWithPath: args[1])
let clipName = args[2]
let animDir = packDir.appendingPathComponent("animations", isDirectory: true)

let CW = 640, CH = 360
let outFrames = Int((durationSec * Double(fps)).rounded())
try? FileManager.default.createDirectory(at: animDir, withIntermediateDirectories: true)

// MARK: - 读取源画面
//
// 全部走系统框架，不依赖 ffmpeg：
//   · 帧目录      → 逐张读
//   · GIF        → ImageIO 取每帧
//   · 视频(mp4/mov/m4v…) → AVAssetImageGenerator 按 fps 抽帧
// 这样在沙箱/无 homebrew 的机器上也能跑，且不会因派生外部进程被杀。

var sourceFrames: [CGImage] = []
let inputURL = URL(fileURLWithPath: inputPath)
let ext = inputURL.pathExtension.lowercased()

let isDir = (try? FileManager.default.attributesOfItem(atPath: inputPath)[.type] as? FileAttributeType) == .typeDirectory

if isDir {
    // 已经是帧序列
    let items = (try? FileManager.default.contentsOfDirectory(atPath: inputPath)) ?? []
    let imgs = items.filter { ["png", "jpg", "jpeg", "tiff", "bmp", "webp"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
    for name in imgs {
        if let d = try? Data(contentsOf: inputURL.appendingPathComponent(name)),
           let s = CGImageSourceCreateWithData(d as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(s, 0, nil) {
            sourceFrames.append(img)
        }
    }
    print("==> 读入帧序列 \(sourceFrames.count) 张")

} else if ext == "gif" || ext == "apng" || ext == "webp" {
    print("==> 解 GIF/动图")
    guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
        print("! 读不了 \(inputPath)"); exit(2)
    }
    let n = CGImageSourceGetCount(src)
    // 尊重每帧时长，换算成目标 fps 的重复次数
    for i in 0..<n {
        guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
        var delay = 0.1
        if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
           let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let d = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif[kCGImagePropertyGIFDelayTime] as? Double {
            delay = d
        }
        let reps = max(1, Int((delay * Double(fps)).rounded()))
        for _ in 0..<reps { sourceFrames.append(img) }
    }
    print("    共 \(n) 帧 → 展开 \(sourceFrames.count) 帧")

} else {
    print("==> 原生解码视频")
    let asset = AVURLAsset(url: inputURL, options: [
        // 不要自动套色域转换，尽量保留原始像素
        AVURLAssetPreferPreciseDurationAndTimingKey: true
    ])
    let dur = CMTimeGetSeconds(asset.duration)
    guard dur.isFinite, dur > 0 else {
        print("! 读不到时长，可能不是视频文件：\(inputPath)"); exit(2)
    }
    let begin = min(max(startSec, 0), dur)
    let take = min(durationSec, max(0, dur - begin))
    let total = Int((take * Double(fps)).rounded())

    var t = begin
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    // 保持原始尺寸，不缩
    gen.maximumSize = CGSize(width: 0, height: 0)
    var fail = 0
    for i in 0..<total {
        let ct = CMTime(seconds: t, preferredTimescale: 600)
        if let cg = try? gen.copyCGImage(at: ct, actualTime: nil) {
            sourceFrames.append(cg)
        } else {
            fail += 1
        }
        t += 1.0 / Double(fps)
        if i % 30 == 0 { print("    \(i)/\(total)") }
    }
    if let track = asset.tracks(withMediaType: .video).first {
        let sz = track.naturalSize.applying(track.preferredTransform)
        print("    源 \(Int(abs(sz.width)))x\(Int(abs(sz.height)))  \(String(format: "%.2f", dur))s  → 取 \(sourceFrames.count) 帧" + (fail > 0 ? "（失败 \(fail)）" : ""))
    }
}


guard !sourceFrames.isEmpty else {
    print("! 没拿到任何画面")
    exit(3)
}

// MARK: - 抠背景

/// 背景色全局缓存：同一段视频只用第一帧估一次。
/// 逐帧重估的问题：个别帧有闪光/压缩突变，四角采样会偏，整帧就抠不干净。
var sharedBG: (Double, Double, Double)? = nil

/// 纯色背景抠图：在 Cb/Cr 色度平面上算到背景色的距离，顺带 despill。
func keyOut(_ src: CGImage, mode: String) -> CGImage? {
    let w = src.width, h = src.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))

    // 取四角采样估计背景色——不管哪种模式都先量一次，比写死 #00FF00 靠谱得多
    var sr = 0.0, sg = 0.0, sb = 0.0
    if let cached = sharedBG {
        sr = cached.0; sg = cached.1; sb = cached.2
    } else {
        for (x, y) in [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)] {
            let o = (y * w + x) * 4
            sb += Double(buf[o]); sg += Double(buf[o + 1]); sr += Double(buf[o + 2])
        }
        sr /= 4; sg /= 4; sb /= 4
        sharedBG = (sr, sg, sb)
    }

    // 判断这块背景偏什么色。绿幕用「绿通道优势」判定，蓝幕同理。
    // 为什么不用色度距离：低饱和的灰绿背景和奶油白/浅灰在 CbCr 平面上几乎重合，
    // 距离法会把角色身上浅色的部分一起抠掉（实测柴犬的胸口、肚皮全透明了）。
    // 绿通道优势 G-max(R,B) 对两者分得很开：背景 #5C8F52 得到 +51，奶油白 #FBEFD7 得到 -12。
    let greenAdv = sg - max(sr, sb)
    let blueAdv = sb - max(sr, sg)
    var isGreen = mode == "green" || (mode == "auto" && greenAdv > 6 && greenAdv >= blueAdv)
    var isBlue = mode == "blue" || (mode == "auto" && blueAdv > 6 && blueAdv > greenAdv)
    if mode == "blue" { isGreen = false; isBlue = true }
    if mode == "green" { isGreen = true; isBlue = false }

    // 色度距离兜底（背景既不是绿也不是蓝，比如粉色/白色背景）
    let keyCb = 128 - 0.168736 * sr - 0.331264 * sg + 0.5 * sb
    let keyCr = 128 + 0.5 * sr - 0.418688 * sg - 0.081312 * sb
    let useChroma = !isGreen && !isBlue && mode != "none"

    if useChroma {
        print("    背景色 R\(Int(sr)) G\(Int(sg)) B\(Int(sb)) 非绿非蓝，用色度距离抠")
    } else if isGreen {
        print("    背景色 R\(Int(sr)) G\(Int(sg)) B\(Int(sb))  绿通道优势 \(Int(greenAdv))，用绿幕判定")
    } else if isBlue {
        print("    背景色 R\(Int(sr)) G\(Int(sg)) B\(Int(sb))  蓝通道优势 \(Int(blueAdv))，用蓝幕判定")
    }

    // 优势阈值：<= t0 判为角色，>= t1 判为背景，中间线性过渡（保留软边）
    // 用背景实测值动态定 t1，避免不同饱和度的幕布需要手调
    // 阈值按实测背景优势值定，而且过渡带要窄：
    // 背景压缩噪点会让个别像素的优势值掉到 60% 左右，如果过渡带太宽，
    // 这些像素会留下 alpha≈0.1 的淡雾——肉眼看不见，但会把求并集的边界撑大，
    // 导致整体缩放算错（实测趴卧段因此被缩到 124px 宽）。
    let adv = isBlue ? blueAdv : greenAdv
    let t1 = max(22.0, min(adv * 0.58, 120.0))
    let t0 = max(12.0, t1 * 0.72)

    // 生成模型的视频四周常有一圈暗角（1~2px 的深绿过渡），抠完会留下一圈
    // alpha 0.3~0.9 的半透明边框，把求并集的框直接撑满整幅画面。按比例裁掉最外圈。
    let margin = max(2, Int(Double(min(w, h)) * 0.015))

    for y in 0..<h {
        let row = y * w * 4
        for x in 0..<w {
            let o = row + x * 4
            var b = Double(buf[o]), g = Double(buf[o + 1]), r = Double(buf[o + 2])
            let a0 = Double(buf[o + 3])
            if x < margin || y < margin || x >= w - margin || y >= h - margin {
                if a0 >= 250 {
                    buf[o] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0
                }
                continue
            }
            if a0 < 250 {
                // 源本身带 alpha（透明视频），不再按颜色处理
                continue
            }
            // 与背景「同色相、不同亮度」的像素必然是背景：视频边缘的暗角就是这样，
            // 它的绿通道优势值掉了，但 CbCr 和幕布几乎一致。用色度距离做硬判定补掉这一圈。
            let cb0 = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
            let cr0 = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
            let chromaD = ((cb0 - keyCb) * (cb0 - keyCb) + (cr0 - keyCr) * (cr0 - keyCr)).squareRoot()
            var a = 1.0
            if isGreen || isBlue {
                let d = isBlue ? (b - max(r, g)) : (g - max(r, b))
                a = min(max((t1 - d) / (t1 - t0), 0), 1)
                if chromaD < 18 { a = 0 }
                if isGreen, a < 1 { g = min(g, max(r, b) + 6) }   // despill
                if isBlue, a < 1 { b = min(b, max(r, g) + 6) }
            } else if false {
                let d = b - max(r, g)
                a = min(max((t1 - d) / (t1 - t0), 0), 1)
                if a < 1 { b = min(b, max(r, g) + 6) }
            } else if useChroma {
                let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
                let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
                let d = ((cb - keyCb) * (cb - keyCb) + (cr - keyCr) * (cr - keyCr)).squareRoot()
                a = min(max((d - 12.0) / (45.0 - 12.0), 0), 1)
            }
            if let cr = clearRect {
                // buf 是 CG 的下上坐标（row 0 在底部），传进来的矩形是左上原点
                let xn = Double(x) / Double(w)
                let yn = 1.0 - Double(y) / Double(h)
                if xn >= cr.minX, xn <= cr.maxX, yn >= cr.minY, yn <= cr.maxY { a = 0 }
            }
            // 淡于 25% 的一律归零：源视频边缘常有暗角/压缩噪点，
            // 会散出一堆 alpha≈0.1 的孤点，肉眼看不见但会把求并集的框撑满整幅画面。
            if a < 0.25 { a = 0 }
            if a >= 1 { continue }
            // 预乘 alpha 后写回
            buf[o] = UInt8(max(0, min(255, b * a)))
            buf[o + 1] = UInt8(max(0, min(255, g * a)))
            buf[o + 2] = UInt8(max(0, min(255, r * a)))
            buf[o + 3] = UInt8(max(0, min(255, 255 * a)))
        }
    }
    return ctx.makeImage()
}

/// 系统主体抠图（逐帧）。
let ciContext = CIContext(options: [.useSoftwareRenderer: false])
func matteOut(_ src: CGImage) -> CGImage? {
    let handler = VNImageRequestHandler(cgImage: src, options: [:])
    let req = VNGenerateForegroundInstanceMaskRequest()
    do {
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else { return nil }
        let mask = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        let ci = CIImage(cgImage: src)
        let maskCI = CIImage(cvPixelBuffer: mask).cropped(to: ci.extent)
        let clear = CIImage(color: CIColor.clear).cropped(to: ci.extent)
        let out = ci.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: maskCI,
        ])
        return ciContext.createCGImage(out, from: ci.extent)
    } catch {
        return nil
    }
}

func alphaBounds(_ cg: CGImage) -> CGRect? {
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    // 按 8×8 块统计占据，块内至少 5 个不透明像素才算「有内容」。
    // 直接取 min/max 会被单颗噪点毁掉：实测某帧只有 1 个孤点，
    // 就把主体框从 444 撑到 881，整个角色的缩放跟着算错。
    let bs = 8
    let cols = (w + bs - 1) / bs, rows = (h + bs - 1) / bs
    var occ = [Bool](repeating: false, count: cols * rows)
    for by in 0..<rows {
        for bx in 0..<cols {
            var c = 0
            for y in (by*bs)..<min(h, by*bs+bs) {
                let row = y * w
                for x in (bx*bs)..<min(w, bx*bs+bs) where buf[(row + x) * 4 + 3] > 40 { c += 1 }
            }
            occ[by*cols + bx] = c >= 5
        }
    }
    var minBx = cols, maxBx = -1, minBy = rows, maxBy = -1
    for by in 0..<rows { for bx in 0..<cols where occ[by*cols + bx] {
        minBx = min(minBx, bx); maxBx = max(maxBx, bx)
        minBy = min(minBy, by); maxBy = max(maxBy, by)
    }}
    guard maxBx >= minBx, maxBy >= minBy else { return nil }
    return CGRect(x: minBx*bs, y: minBy*bs,
                  width: min(w, (maxBx+1)*bs) - minBx*bs,
                  height: min(h, (maxBy+1)*bs) - minBy*bs)
}

print("==> 逐帧抠背景（\(useMatte ? "主体抠图" : keyMode == "none" ? "原样（源已有 alpha）" : "纯色 key: \(keyMode)"))")
var processed: [CGImage] = []
var unionBox = CGRect.null
let t0 = Date()
for (i, frame) in sourceFrames.enumerated() {
    var out: CGImage? = frame
    if useMatte {
        out = matteOut(frame) ?? frame
    } else if keyMode != "none" {
        out = keyOut(frame, mode: keyMode) ?? frame
    }
    guard let img = out else { continue }
    if let b = alphaBounds(img) {
        unionBox = unionBox.isNull ? b : unionBox.union(b)
    }
    if ProcessInfo.processInfo.environment["MAKECLIP_DEBUG"] != nil {
        let bb = alphaBounds(img)
        print("    [框] frame \(i): \(bb.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" } ?? "nil")")
        if ProcessInfo.processInfo.environment["MAKECLIP_DEBUG"] == "3" {
            // 按 64 行统计不透明像素，看那圈东西到底长什么样
            let cg = img
            let w2 = cg.width, h2 = cg.height
            var buf2 = [UInt8](repeating: 0, count: w2 * h2 * 4)
            if let c2 = CGContext(data: &buf2, width: w2, height: h2, bitsPerComponent: 8, bytesPerRow: w2 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                c2.draw(cg, in: CGRect(x: 0, y: 0, width: w2, height: h2))
                var bands: [Int] = []
                for band in 0..<((h2 + 63) / 64) {
                    var c = 0
                    for y in (band*64)..<min(h2, band*64+64) { for x in 0..<w2 {
                        if buf2[(y*w2+x)*4+3] > 40 { c += 1 }
                    }}
                    bands.append(c)
                }
                print("    [带] \(bands)")
            }
        }
    }
    if ProcessInfo.processInfo.environment["MAKECLIP_DEBUG"] == "2", i == 0, let cg = img as CGImage? {
        let w2 = cg.width, h2 = cg.height
        var buf2 = [UInt8](repeating: 0, count: w2 * h2 * 4)
        if let c2 = CGContext(data: &buf2, width: w2, height: h2, bitsPerComponent: 8, bytesPerRow: w2 * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) {
            c2.draw(cg, in: CGRect(x: 0, y: 0, width: w2, height: h2))
            var hist = [Int](repeating: 0, count: 6)   // 0, 1-16, 17-64, 65-128, 129-254, 255
            var lowBox = CGRect.null
            var mnX = w2, mnY = h2, mxX = -1, mxY = -1
            for y in 0..<h2 { for x in 0..<w2 {
                let a = Int(buf2[(y * w2 + x) * 4 + 3])
                let bin = a == 0 ? 0 : a <= 16 ? 1 : a <= 64 ? 2 : a <= 128 ? 3 : a <= 254 ? 4 : 5
                hist[bin] += 1
                if a > 0 && a <= 64 {
                    mnX = min(mnX, x); mnY = min(mnY, y); mxX = max(mxX, x); mxY = max(mxY, y)
                }
            }}
            if mxX >= 0 { lowBox = CGRect(x: mnX, y: mnY, width: mxX - mnX + 1, height: mxY - mnY + 1) }
            print("    [debug] alpha 直方图 0:\(hist[0]) 1-16:\(hist[1]) 17-64:\(hist[2]) 65-128:\(hist[3]) 129-254:\(hist[4]) 255:\(hist[5])")
            print("    [debug] 低 alpha(1-64) 范围 \(lowBox)")
            print("    [debug] 主体框 \(alphaBounds(cg) ?? .null)")
        }
    }
    processed.append(img)
    if i % 30 == 0 {
        print("    \(i)/\(sourceFrames.count)  \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    }
}
print("    完成 \(processed.count) 帧，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

guard !processed.isEmpty, !unionBox.isNull else {
    print("! 抠完什么都没有：背景色没匹配上？试试 --matte")
    exit(4)
}

// 全局统一摆位：用所有帧的并集算一次，避免逐帧跳动
let scale = scaleArg.isEmpty
    ? targetH / Double(unionBox.height)
    : (Double(scaleArg) ?? 0.321)
let drawW = Double(unionBox.width) * scale
let drawH = Double(unionBox.height) * scale
let drawRect = CGRect(x: 320 - drawW / 2, y: bottomGap, width: drawW, height: drawH)
print("    主体并集 \(Int(unionBox.width))x\(Int(unionBox.height)) → 摆位 \(Int(drawW))x\(Int(drawH))")

// MARK: - 时间线

var timeline: [Int] = []
let n = processed.count
switch fillMode {
case "once":
    timeline = Array(0..<min(n, outFrames))
case "loop":
    timeline = (0..<outFrames).map { $0 % n }
case "hold":
    timeline = (0..<outFrames).map { min($0, n - 1) }
default: // pingpong
    let cycle = max(1, n * 2 - 2)
    timeline = (0..<outFrames).map { i -> Int in
        let k = i % cycle
        return k < n ? k : cycle - k
    }
}

// MARK: - 编码

let outURL = animDir.appendingPathComponent("\(clipName).mov")
try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
    AVVideoWidthKey: CW,
    AVVideoHeightKey: CH,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 1_600_000,
        AVVideoMaxKeyFrameIntervalKey: fps,
    ],
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: CW,
    kCVPixelBufferHeightKey as String: CH,
]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
writer.add(input)
guard writer.startWriting() else {
    print("! 写不了: \(String(describing: writer.error))")
    exit(5)
}
writer.startSession(atSourceTime: .zero)

var pool: CVPixelBufferPool?
CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
let cs = CGColorSpaceCreateDeviceRGB()

print("==> 编码 \(timeline.count) 帧")
for (i, idx) in timeline.enumerated() {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
    guard let buf = pb else { break }
    CVPixelBufferLockBaseAddress(buf, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: CW, height: CH,
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)
    ctx?.clear(CGRect(x: 0, y: 0, width: CW, height: CH))
    // 帧里主体位置固定，按并集框等比映射到窗口
    if let c = ctx {
        let srcRect = CGRect(x: unionBox.minX, y: unionBox.minY,
                             width: unionBox.width, height: unionBox.height)
        if let cropped = processed[idx].cropping(to: srcRect) {
            c.draw(cropped, in: drawRect)
        } else {
            c.draw(processed[idx], in: drawRect)
        }
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    while !input.isReadyForMoreMediaData { usleep(1500) }
    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()

if writer.status != .completed {
    print("! 编码失败: \(String(describing: writer.error))")
    exit(6)
}
let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)??.intValue ?? 0
print("==> 完成 \(outURL.path)  \(bytes / 1024)KB  \(String(format: "%.2f", Double(timeline.count) / Double(fps)))s")
