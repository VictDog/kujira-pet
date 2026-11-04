// makechar —— 把「一张角色图」变成桌宠能播的整套 HEVC + alpha 动画包。
//
// 用法：
//   makechar <图片路径> <角色包名> [输出目录]
//
// 做什么：
//   1. 图带透明通道就直接用；不透明就用系统主体抠图（Vision）抠掉背景。
//   2. 裁到主体边界，按原角色的占位（高 290px、底边距下 28px、水平居中）摆进 640×360。
//   3. 逐帧做程序化变换（呼吸 / 跳跃 / 摇晃 / 入睡 …），用 AVAssetWriter 编成
//      HEVC with alpha 的 .mov，颜色与 alpha 都是 8bit，软边不会糊。
//   4. 顺手写出这个角色包自己的 catalog.json。

import AVFoundation
import AppKit
import Vision

// MARK: - 参数

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: makechar <图片路径> <角色包名> [输出目录]")
    exit(1)
}
let inputPath = args[1]
let packName = args[2]
let rootDir = args.count > 3 ? args[3] : "Resources/characters"
let packDir = URL(fileURLWithPath: rootDir).appendingPathComponent(packName, isDirectory: true)
let animDir = packDir.appendingPathComponent("animations", isDirectory: true)

let CW = 640, CH = 360
let FPS = 30
let FRAMES = 301               // 10.03s，和原素材的 10.04s 对齐
let TARGET_H = 290.0           // 角色高度
let BOTTOM_GAP = 28.0          // 脚底距画面下边
let CENTER_X = 320.0

// MARK: - 一张图的姿态

struct Pose {
    var dx: Double = 0
    var dy: Double = 0
    var sx: Double = 1
    var sy: Double = 1
    var rot: Double = 0     // 弧度，正数逆时针

    init(dx: Double = 0, dy: Double = 0, sx: Double = 1, sy: Double = 1, rot: Double = 0) {
        self.dx = dx; self.dy = dy; self.sx = sx; self.sy = sy; self.rot = rot
    }
}

struct Clip {
    let name: String
    let pose: (Double) -> Pose
}

private func hop(_ u: Double, _ h: Double) -> Double {
    guard u > 0, u < 1 else { return 0 }
    return 4 * h * u * (1 - u)
}

private func smooth(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}

// 每个片段的动作曲线，都保证 t=0 与 t=1 姿态一致，循环无跳变。
let clipsCore: [Clip] = [
    // —— 待机 / 转向 / 拖拽：替换原素材的三个必需槽位 ——
    Clip(name: "待机呼吸休闲") { (t: Double) -> Pose in
        let s = sin(2 * .pi * t)
        return Pose(dy: 2.2 * s, sx: 1 - 0.006 * s, sy: 1 + 0.014 * s)
    },
    Clip(name: "东张西望") { (t: Double) -> Pose in
        let s = sin(2 * .pi * t)
        return Pose(dx: 7 * s, dy: 1.4 * sin(4 * .pi * t), rot: 0.020 * s)
    },
    Clip(name: "被鼠标拖拽悬空反馈") { (t: Double) -> Pose in
        Pose(dx: 4 * sin(2 * .pi * 1.5 * t), dy: 4 * sin(2 * .pi * 3 * t), rot: 0.065 * sin(2 * .pi * 1.5 * t))
    },
    Clip(name: "原地漂浮踏步") { (t: Double) -> Pose in
        let s = sin(2 * .pi * t)
        return Pose(dy: 7 * s + 2, sy: 1 + 0.008 * s, rot: 0.014 * s)
    },
    Clip(name: "螃蟹走路") { (t: Double) -> Pose in
        let s = sin(2 * .pi * t), b = abs(sin(2 * .pi * 2 * t))
        return Pose(dx: 13 * s, dy: 3.5 * b, rot: 0.030 * sin(4 * .pi * t))
    },

    // —— 点击回应 ——
    Clip(name: "点击回应-开心跃动") { (t: Double) -> Pose in
        let u = (t * 2).truncatingRemainder(dividingBy: 1)
        let up = hop(u, 52)
        let s = sin(u * .pi)
        return Pose(dy: up, sx: 1 - 0.035 * s, sy: 1 + 0.055 * s)
    },
    Clip(name: "点击回应-元气挥手") { (t: Double) -> Pose in
        Pose(dx: 3 * sin(2 * .pi * 3 * t), dy: 11 * abs(sin(2 * .pi * 1.5 * t)), rot: 0.035 * sin(2 * .pi * 3 * t))
    },
    Clip(name: "点击回应-傲娇生气") { (t: Double) -> Pose in
        Pose(dx: 5 * sin(2 * .pi * 10 * t) * (0.55 + 0.45 * cos(2 * .pi * t)), dy: 1.5 * sin(2 * .pi * 5 * t), sx: 1.025, sy: 0.985, rot: 0.02 * sin(2 * .pi * 5 * t))
    },
    Clip(name: "点击回应-害羞惊讶") { (t: Double) -> Pose in
        let s = sin(2 * .pi * t)
        return Pose(dy: 2 * s, sx: 1 - 0.045 * max(0, s), sy: 1 - 0.045 * max(0, s), rot: -0.02 * max(0, s))
    },
    Clip(name: "点击回应-挠痒咯咯笑") { (t: Double) -> Pose in
        Pose(dx: 4 * sin(2 * .pi * 7 * t), dy: 3 * abs(sin(2 * .pi * 3.5 * t)), sx: 1 + 0.02 * abs(sin(2 * .pi * 3.5 * t)), sy: 1 - 0.02 * abs(sin(2 * .pi * 3.5 * t)))
    },

]

let clipsSleep: [Clip] = [
    // —— 睡觉三段 ——
    Clip(name: "睡觉-开始") { (t: Double) -> Pose in
        let p = smooth(t)
        return Pose(dy: -10 * p, sx: 1 + 0.02 * p, sy: 1 - 0.07 * p, rot: 0.055 * p)
    },
    Clip(name: "睡觉-循环") { (t: Double) -> Pose in
        let s = sin(2 * .pi * t)
        return Pose(dy: -10 + 1.6 * s, sx: 1.02, sy: 0.93 + 0.006 * s, rot: 0.055)
    },
    Clip(name: "睡觉-起来") { (t: Double) -> Pose in
        // 带一点过冲的弹回
        let p = smooth(t)
        let over = sin(p * .pi) * 0.02
        return Pose(dy: -10 * (1 - p), sx: 1.02 - 0.02 * p, sy: 0.93 + 0.07 * p + over, rot: 0.055 * (1 - p))
    },

]

let clipsPlay: [Clip] = [
    // —— 随机小动作 ——
    Clip(name: "伸懒腰") { (t: Double) -> Pose in
        let p = pow(sin(.pi * t), 2)
        return Pose(dy: 9 * p, sx: 1 - 0.03 * p, sy: 1 + 0.11 * p, rot: 0.012 * sin(2 * .pi * t))
    },
    Clip(name: "打哈欠") { (t: Double) -> Pose in
        let p = pow(sin(.pi * t), 2)
        return Pose(dy: 5 * p, sx: 1 + 0.02 * p, sy: 1 + 0.07 * p, rot: -0.022 * p)
    },
    Clip(name: "抖一抖") { (t: Double) -> Pose in
        let env = 0.5 + 0.5 * cos(2 * .pi * t)
        return Pose(dx: 7 * sin(2 * .pi * 12 * t) * env, rot: 0.012 * sin(2 * .pi * 12 * t) * env)
    },
    Clip(name: "原地摇晃") { (t: Double) -> Pose in
        let s = sin(2 * .pi * t)
        return Pose(dx: 6 * s, dy: 1.2 * sin(4 * .pi * t), rot: 0.030 * s)
    },
    Clip(name: "摇头晃脑") { (t: Double) -> Pose in
        Pose(dx: 4 * sin(4 * .pi * t), dy: 2 * abs(sin(4 * .pi * t)), rot: 0.055 * sin(4 * .pi * t))
    },
    Clip(name: "蹦蹦跳") { (t: Double) -> Pose in
        let u = (t * 4).truncatingRemainder(dividingBy: 1)
        let s: Double = sin(u * .pi)
        let up: Double = hop(u, 26)
        let sx: Double = 1 - 0.03 * s
        let sy: Double = 1 + 0.045 * s
        return Pose(dy: up, sx: sx, sy: sy)
    },
    Clip(name: "转圈圈") { (t: Double) -> Pose in
        Pose(dy: 3 * abs(sin(2 * .pi * t)), sx: cos(4 * .pi * t))
    },
    Clip(name: "探头看") { (t: Double) -> Pose in
        let p = pow(sin(.pi * t), 2)
        return Pose(dy: -6 * p, sx: 1 + 0.05 * p, sy: 1 + 0.05 * p)
    },
]

let clips: [Clip] = clipsCore + clipsSleep + clipsPlay

// MARK: - 读图 / 抠图

func loadImage(_ path: String) -> CGImage? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

/// 取 alpha 通道里的不透明包围盒；全透明或没有 alpha 返回 nil。
func alphaBounds(_ cg: CGImage) -> CGRect? {
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        let row = y * w * 4
        for x in 0..<w where buf[row + x * 4 + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    // CGImage 的裁剪坐标原点在左上，和位图扫描顺序一致，不用翻转
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// 系统主体抠图（macOS 14+），返回带 alpha 的图。
func matte(_ cg: CGImage) -> CGImage? {
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let req = VNGenerateForegroundInstanceMaskRequest()
    do {
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
            print("  ! 没找到主体，退回原图")
            return nil
        }
        let mask = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        let src = CIImage(cgImage: cg)
        let maskCI = CIImage(cvPixelBuffer: mask).cropped(to: src.extent)
        let clear = CIImage(color: CIColor.clear).cropped(to: src.extent)
        let out = src.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: maskCI,
        ])
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(out, from: src.extent)
    } catch {
        print("  ! 抠图失败 \(error.localizedDescription)")
        return nil
    }
}

// MARK: - 编码

func encode(url: URL, writeFrame: (CGContext, Int) -> Void) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
        AVVideoWidthKey: CW,
        AVVideoHeightKey: CH,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 1_400_000,
            AVVideoMaxKeyFrameIntervalKey: FPS,
        ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: CW,
        kCVPixelBufferHeightKey as String: CH,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "write", code: 1) }
    writer.startSession(atSourceTime: .zero)

    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    let cs = CGColorSpaceCreateDeviceRGB()

    for i in 0..<FRAMES {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
        guard let buf = pb else { throw NSError(domain: "pool", code: 2) }
        CVPixelBufferLockBaseAddress(buf, [])
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: CW, height: CH,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buf, [])
            throw NSError(domain: "ctx", code: 3)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: CW, height: CH))
        writeFrame(ctx, i)
        CVPixelBufferUnlockBaseAddress(buf, [])
        while !input.isReadyForMoreMediaData { usleep(1500) }
        adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS)))
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    if writer.status != .completed {
        throw writer.error ?? NSError(domain: "finish", code: 4)
    }
}

// MARK: - 主流程

print("==> 读图 \(inputPath)")
guard let raw = loadImage(inputPath) else {
    print("! 读不到图片"); exit(1)
}
print("    原始尺寸 \(raw.width)x\(raw.height) alpha=\(raw.alphaInfo.rawValue)")

var subject = raw
var hasRealAlpha = false
if let b = alphaBounds(raw) {
    // 主体覆盖面积小于 92% 才算真的透明底，否则当作白底/不透明图去抠
    let cover = (b.width * b.height) / CGFloat(raw.width * raw.height)
    hasRealAlpha = cover < 0.92
    print("    alpha 主体框 \(Int(b.width))x\(Int(b.height)) 覆盖 \(Int(cover * 100))%")
}

if !hasRealAlpha {
    print("==> 没有透明背景，调用系统主体抠图")
    if let m = matte(raw) {
        subject = m
        print("    抠图完成")
    }
}

var body = subject
if let b = alphaBounds(subject), let c = subject.cropping(to: b.integral) {
    body = c
}
print("    主体边界 \(body.width)x\(body.height)")

// 摆位：等比缩放到 TARGET_H，脚底对齐 BOTTOM_GAP，水平居中
let scale = TARGET_H / Double(body.height)
let drawW = Double(body.width) * scale
let drawH = Double(body.height) * scale
let drawRect = CGRect(x: CENTER_X - drawW / 2, y: BOTTOM_GAP, width: drawW, height: drawH)
print("    摆位 宽\(Int(drawW)) 高\(Int(drawH)) 底边\(Int(BOTTOM_GAP))")

try? FileManager.default.createDirectory(at: animDir, withIntermediateDirectories: true)

// 竖版图会被拉得很宽，提示一下
if drawW > Double(CW) * 0.95 {
    print("    提示：角色偏宽，左右可能贴边")
}

print("==> 逐段编码（\(clips.count) 段 × \(FRAMES) 帧）")
var made: [String] = []
for (idx, clip) in clips.enumerated() {
    let url = animDir.appendingPathComponent("\(clip.name).mov")
    let t0 = Date()
    do {
        try encode(url: url) { ctx, i in
            let t = Double(i) / Double(FRAMES)
            let p = clip.pose(t)
            let anchor = CGPoint(x: CENTER_X + p.dx, y: BOTTOM_GAP + p.dy)
            ctx.saveGState()
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: p.rot)
            ctx.scaleBy(x: p.sx, y: p.sy)
            ctx.translateBy(x: -anchor.x, y: -anchor.y)
            ctx.draw(body, in: drawRect)
            ctx.restoreGState()
        }
        made.append(clip.name)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0
        print("    [\(idx + 1)/\(clips.count)] \(clip.name)  "
            + String(format: "%.1fs", Date().timeIntervalSince(t0)) + "  \(bytes / 1024)KB")
    } catch {
        print("    [\(idx + 1)] \(clip.name) 失败: \(error)")
    }
}

// 封面板图，方便快速看一眼
do {
    let pv = packDir.appendingPathComponent("preview.png")
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: CW, pixelsHigh: CH,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: CW, height: CH).fill()
    NSGraphicsContext.current?.cgContext.draw(body, in: drawRect)
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: pv)
    }
}

// MARK: - 这个角色包自己的 catalog.json

let actionClips = ["伸懒腰", "打哈欠", "抖一抖", "原地摇晃", "摇头晃脑", "探头看"]
let playClips = ["蹦蹦跳", "转圈圈"]

let catalog: [String: Any] = [
    "idle": ["待机呼吸休闲"],
    "turn": ["东张西望"],
    "drag": ["被鼠标拖拽悬空反馈"],
    "clicks": ["点击回应-开心跃动", "点击回应-元气挥手", "点击回应-傲娇生气", "点击回应-害羞惊讶", "点击回应-挠痒咯咯笑"],
    "moves": [
        "default": ["minDist": 60, "maxDist": 240, "margin": 20, "leadSec": 2, "tailSec": 2],
        "actions": [
            ["name": "螃蟹走路"],
            ["name": "原地漂浮踏步", "params": ["minDist": 40, "maxDist": 120]],
        ],
    ],
    "categories": [
        ["id": "小动作", "weight": 20, "actions": actionClips],
        ["id": "玩耍", "weight": 20, "actions": playClips],
    ],
    "sleep": ["start": ["睡觉-开始"], "loop": ["睡觉-循环"], "end": ["睡觉-起来"]],
    "whisper": ["原地摇晃"],
    "weights": ["idle": 12, "turn": 6, "move": 6],
    "physics": ["gravity": 1400, "restitution": 0.78, "groundFriction": 2.5, "throwPower": 1.0],
    "refWidth": 462,
    "sleepStartTexts": ["困了，先眯一会儿…"],
    "sleepEndTexts": ["睡醒啦～"],
    "sleepRefuseTexts": ["我在睡觉，别烦我……"],
]
let json = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
try json.write(to: packDir.appendingPathComponent("catalog.json"))

let total = (try? FileManager.default.contentsOfDirectory(atPath: animDir.path))?.count ?? 0
print("==> 完成：\(packDir.path)")
print("    片段 \(total) 段，catalog.json 已写入")
