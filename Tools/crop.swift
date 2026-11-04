// crop —— 裁掉图片边缘（常用来干掉生成服务加的水印）。
//
// 用法：
//   crop <输入图> <输出图> [--bottom 70] [--top 0] [--left 0] [--right 0]
//
// 后三者按像素计，从对应边裁掉。

import AppKit

var args = Array(CommandLine.arguments.dropFirst())
func takeValue(_ name: String, _ def: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else { return def }
    args.removeSubrange(i...(i + 1))
    return v
}
let bottom = takeValue("--bottom", 0)
let top = takeValue("--top", 0)
let left = takeValue("--left", 0)
let right = takeValue("--right", 0)

guard args.count >= 2 else {
    print("用法: crop <输入> <输出> [--bottom N] [--top N] [--left N] [--right N]")
    exit(1)
}
let inURL = URL(fileURLWithPath: args[0])
let outURL = URL(fileURLWithPath: args[1])

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("! 读不了 \(args[0])"); exit(2)
}
let w = img.width, h = img.height
let rect = CGRect(x: left, y: top,
                  width: w - left - right,
                  height: h - top - bottom).integral
guard rect.width > 8, rect.height > 8, let cut = img.cropping(to: rect) else {
    print("! 裁没了：原图 \(w)x\(h)，四边裁 \(top)/\(bottom)/\(left)/\(right)"); exit(3)
}

let rep = NSBitmapImageRep(cgImage: cut)
guard let data = rep.representation(using: .png, properties: [:]) else {
    print("! 编码失败"); exit(4)
}
try? data.write(to: outURL)
print("==> \(w)x\(h) → \(cut.width)x\(cut.height)  \(outURL.lastPathComponent)")
