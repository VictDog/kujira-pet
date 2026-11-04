import AppKit

// 用一帧角色素材生成 .icns：浅色圆角卡片 + 角色居中，风格跟着系统图标走。
let src = CommandLine.arguments
guard src.count >= 3 else {
    print("用法: genicon <角色.png> <输出.iconset目录>")
    exit(1)
}
let charImage = NSImage(contentsOfFile: src[1])
guard let charImage else {
    print("读不到角色图")
    exit(1)
}
let outDir = src[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> Data? {
    let px = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let full = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    full.fill()

    // macOS 图标留白约 10%
    let inset = size * 0.085
    let card = full.insetBy(dx: inset, dy: inset)
    let radius = card.width * 0.2237
    let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = size * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 卡面：极淡的上下渐变，只用来分出层次，不抢角色
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let grad = NSGradient(
        starting: NSColor(calibratedRed: 0.99, green: 0.99, blue: 1.0, alpha: 1),
        ending: NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.97, alpha: 1)
    )
    grad?.draw(in: card, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSColor(calibratedWhite: 0, alpha: 0.06).setStroke()
    path.lineWidth = max(1, size * 0.004)
    path.stroke()

    // 角色：按高度撑满卡片内部
    var box = charImage.size
    if box.width <= 0 || box.height <= 0 { box = NSSize(width: 640, height: 360) }
    let targetH = card.height * 0.94
    let targetW = targetH * (box.width / box.height)
    let rect = NSRect(
        x: card.midX - targetW / 2 + size * 0.004,
        y: card.midY - targetH / 2,
        width: targetW, height: targetH
    )
    charImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                   respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in specs {
    guard let data = render(size) else { continue }
    try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("iconset 生成完成")
