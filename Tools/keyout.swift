// keyout —— 把纯色背景的立绘转成透明 PNG。
//
// 用法：
//   keyout <输入图> <输出图> [--mode white|green|blue] [--tol 26] [--bottom 0]
//
// 为什么不用「全局颜色替换」：角色身上经常有大片与背景相近的浅色（白猫的肚子、
// 奶油色柴犬的胸口），直接按颜色清会把身体抠穿。这里从画布四边做泛洪填充，
// 只删掉「与边缘连通」的背景像素；身体内部被深色描边围住，泛洪进不去。
//
// --bottom 用来裁掉生成服务加在右下角的水印（按像素裁掉底部一条）。

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

var raw = Array(CommandLine.arguments.dropFirst())
func take(_ name: String, _ def: String) -> String {
    guard let i = raw.firstIndex(of: name), i + 1 < raw.count else { return def }
    let v = raw[i + 1]
    raw.removeSubrange(i...(i + 1))
    return v
}
let mode = take("--mode", "white")
let tol = Double(take("--tol", "26"))!
let cropBottom = Int(take("--bottom", "0"))!
let whiteFloor = Double(take("--floor", "232"))!

guard raw.count >= 2 else {
    print("用法: keyout <输入> <输出> [--mode white|green|blue] [--tol N] [--bottom N] [--floor N]")
    exit(1)
}

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: raw[0]) as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("! 读不了 \(raw[0])"); exit(2)
}

// 先裁水印，再抠背景
var image = original
if cropBottom > 0 {
    let rect = CGRect(x: 0, y: 0,
                      width: original.width,
                      height: max(1, original.height - cropBottom)).integral
    if let c = original.cropping(to: rect) { image = c }
}
let w = image.width, h = image.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                              | CGBitmapInfo.byteOrder32Little.rawValue) else {
    print("! 建位图失败"); exit(3)
}
ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

@inline(__always) func isBackground(_ i: Int) -> Bool {
    let p = i * 4
    let b = Double(buf[p]), g = Double(buf[p + 1]), r = Double(buf[p + 2])
    switch mode {
    case "green":
        // 绿通道优势：低饱和绿幕与奶油白在色度上只差一点点，这个判据更稳
        return g - max(r, b) > tol && g > 100
    case "blue":
        return b - max(r, g) > tol && b > 100
    default:
        let mn = min(r, g, b), mx = max(r, g, b)
        return mn >= whiteFloor && (mx - mn) <= tol
    }
}

var bg = [UInt8](repeating: 0, count: w * h)
var stack = [Int]()
stack.reserveCapacity(min(w * h, 1 << 20))

@inline(__always) func seed(_ i: Int) {
    if bg[i] == 0, isBackground(i) {
        bg[i] = 1
        stack.append(i)
    }
}
for x in 0..<w { seed(x); seed((h - 1) * w + x) }
for y in 0..<h { seed(y * w); seed(y * w + w - 1) }

while let i = stack.popLast() {
    let x = i % w
    if x > 0 { seed(i - 1) }
    if x + 1 < w { seed(i + 1) }
    if i >= w { seed(i - w) }
    if i + w < w * h { seed(i + w) }
}

var cleared = 0
for i in 0..<(w * h) where bg[i] == 1 {
    let p = i * 4
    buf[p] = 0; buf[p + 1] = 0; buf[p + 2] = 0; buf[p + 3] = 0
    cleared += 1
}

guard let outCtx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                 | CGBitmapInfo.byteOrder32Little.rawValue),
      let out = outCtx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: raw[1]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    print("! 输出失败"); exit(4)
}
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { print("! 写文件失败"); exit(5) }

print("完成：\(w)×\(h)，清掉 \(cleared) 个背景像素（\(String(format: "%.1f", Double(cleared) / Double(w * h) * 100))%）→ \(raw[1])")
