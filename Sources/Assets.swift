import AVFoundation
import AppKit

/// 素材定位与时长缓存。
///
/// 素材按「角色包」组织：`Resources/characters/<包名>/` 下面有 `animations/`
/// 和属于这个角色自己的 `catalog.json`。换角色 = 换目录，不用重新编译。
///
/// 时长不做事前批量扫描：一次开上百个 AVURLAsset 会把媒体 I/O 占满，
/// 首帧解码要等十几秒。真播过哪段再把它记下来修正。
enum Assets {
    static let fallbackDuration: Double = 10.04

    /// 当前角色包 id。
    private(set) static var packID: String = Pref.character

    static var charactersRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("characters", isDirectory: true)
    }

    /// 用户自己的角色包目录：放这儿不用改 App、不用重新编译。
    static var externalRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DSH桌宠/characters", isDirectory: true)
    }

    /// 外置目录优先，同名时用户自己的覆盖内置的。
    private static var roots: [URL] {
        [externalRoot, charactersRoot].compactMap { $0 }
    }

    /// 包目录（必须有 catalog.json 才算数）。
    static func packURL(_ id: String) -> URL? {
        for root in roots {
            let u = root.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("catalog.json").path) {
                return u
            }
        }
        return nil
    }

    /// 所有可用角色包，按名字排序。
    static func availablePacks() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for id in items.sorted() where !id.hasPrefix(".") && !seen.contains(id) && packURL(id) != nil {
                seen.insert(id)
                out.append(id)
            }
        }
        return out
    }

    /// 菜单里显示的名字：包目录里有 title.txt 就用它。
    static func title(for id: String) -> String {
        guard let dir = packURL(id),
              let raw = try? String(contentsOf: dir.appendingPathComponent("title.txt"), encoding: .utf8),
              let first = raw.split(separator: "\n").first else { return id }
        let t = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? id : t
    }

    /// 把外置目录准备好并返回，供菜单「打开角色文件夹」用。
    @discardableResult
    static func prepareExternalRoot() -> URL {
        let u = externalRoot
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 当前包根目录；找不到就退回旧的平铺布局（Resources/animations）。
    static var root: URL? { packURL(packID) ?? Bundle.main.resourceURL }

    private static var directory: URL? { root?.appendingPathComponent("animations", isDirectory: true) }

    static var catalogURL: URL? { root?.appendingPathComponent("catalog.json") }

    private static var cache: [String: URL] = [:]
    private(set) static var durations: [String: Double] = [:]

    /// 切包：必须清缓存，否则视频还指着上一个角色的文件。
    static func setPack(_ id: String) {
        packID = id
        cache.removeAll()
        durations.removeAll()
    }

    static func url(_ name: String) -> URL? {
        if let hit = cache[name] { return hit }
        guard let dir = directory else { return nil }
        let u = dir.appendingPathComponent(name).appendingPathExtension("mov")
        guard FileManager.default.fileExists(atPath: u.path) else {
            NSLog("[pet] 素材缺失: \(name).mov")
            return nil
        }
        cache[name] = u
        return u
    }

    static func duration(_ name: String) -> Double {
        durations[name] ?? fallbackDuration
    }

    static func record(_ name: String, _ seconds: Double) {
        guard seconds.isFinite, seconds > 0.2 else { return }
        durations[name] = seconds
    }

    static var clickSound: URL? {
        Bundle.main.url(forResource: "click-duck", withExtension: "wav")
    }
}
