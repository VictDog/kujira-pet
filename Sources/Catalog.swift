import Foundation

/// 单次走位可覆盖的参数（缺省取 default）。
struct MoveParams: Decodable {
    var minDist: Double?
    var maxDist: Double?
    var leadSec: Double?
    var tailSec: Double?
}

struct MoveSpec: Decodable {
    var name: String
    var params: MoveParams?
}

struct MovesConfig: Decodable {
    var `default`: MoveParams
    var actions: [MoveSpec]
}

/// 随机动作分类（带权重）。
struct Category: Decodable {
    var id: String
    var weight: Double
    var noMirror: Bool?
    var actions: [String]

    var mirrorsAllowed: Bool { !(noMirror ?? false) }
}

/// 睡觉三段：入睡过渡 / 睡姿循环 / 醒来过渡。
struct SleepConfig: Decodable {
    var start: [String]
    var loop: [String]
    var end: [String]
}

struct PhysicsConfig: Decodable {
    var gravity: Double
    var restitution: Double
    var groundFriction: Double
    var throwPower: Double
}

/// 顶层权重（百分比）：idle / turn / move，剩余归入随机动作。
struct Weights: Decodable {
    var idle: Double
    var turn: Double
    var move: Double
}

/// 角色性格。所有字段可选：不写就沿用内置的通用设定，
/// 这样 dsh / shiba 这些早期角色包不用改一个字也能继续跑。
struct Personality: Decodable {
    /// 日常碎碎念台词。
    var chatterLines: [String]?
    /// 说话间隔（秒）的随机区间，越不爱说话就调越大。
    var chatterMinSec: Double?
    var chatterMaxSec: Double?
    /// 点击被无视的概率，0~1。
    var clickIgnoreRate: Double?
    /// 被无视时播的动作（多半是「假装没发生」的待机/张望）。
    var ignoreActions: [String]?
    /// 被无视时冒出的话，可为空。
    var ignoreTexts: [String]?
    /// 短时间内被连点几次会炸毛；0 或不写 = 关闭。
    var pesterThreshold: Int?
    var pesterWindowSec: Double?
    var pesterActions: [String]?
    var pesterTexts: [String]?
}

/// 整份动画目录，来自角色包里的 catalog.json。
struct Catalog: Decodable {
    var idle: [String]
    var turn: [String]
    var drag: [String]
    var clicks: [String]
    var moves: MovesConfig
    var categories: [Category]
    var sleep: SleepConfig
    var whisper: [String]
    var weights: Weights
    var physics: PhysicsConfig
    var refWidth: Double
    var sleepStartTexts: [String]
    var sleepEndTexts: [String]
    var sleepRefuseTexts: [String]
    /// 可选：不写就是「通用暖心桌宠」的默认性格。
    var personality: Personality?

    // MARK: - 性格（一律带缺省值，早期角色包不用改）

    static let defaultChatterLines = [
        "写代码记得喝水哦～", "主人，眼睛累了吧？", "我在这儿陪着你呢。",
        "摸鱼一时爽，一直摸鱼一直爽。", "要不要伸个懒腰？", "今天的 bug 会自己跑掉的。",
        "我先替你看着桌面。", "唔……有点想吃小饼干。", "加油，快写完了！",
        "坐久了站起来走两步吧。", "主人不理我，我就自己玩。", "灵感通常在站起来之后才来。",
        "别熬夜呀。", "要不要喝杯咖啡？", "这个需求……真的不改了吗？"
    ]

    var chatterLines: [String] {
        guard let lines = personality?.chatterLines, !lines.isEmpty else {
            return Self.defaultChatterLines
        }
        return lines
    }

    var chatterRange: ClosedRange<Double> {
        let lo = personality?.chatterMinSec ?? 150
        let hi = personality?.chatterMaxSec ?? 300
        guard lo > 0, hi >= lo else { return 150...300 }
        return lo...hi
    }

    var clickIgnoreRate: Double { min(max(personality?.clickIgnoreRate ?? 0, 0), 1) }
    var ignoreActions: [String] { personality?.ignoreActions ?? [] }
    var ignoreTexts: [String] { personality?.ignoreTexts ?? [] }

    var pesterThreshold: Int { max(0, personality?.pesterThreshold ?? 0) }
    var pesterWindowSec: Double { personality?.pesterWindowSec ?? 1.6 }
    var pesterActions: [String] { personality?.pesterActions ?? [] }
    var pesterTexts: [String] { personality?.pesterTexts ?? [] }

    static func load() -> Catalog {
        if let c = tryLoad() { return c }
        fatalError("catalog.json 缺失或格式不对：检查 Resources/characters/<包名>/catalog.json")
    }

    /// 切角色包时用这个，失败可以回滚，不至于直接崩。
    static func tryLoad() -> Catalog? {
        guard let url = Assets.catalogURL, let data = try? Data(contentsOf: url) else {
            NSLog("[pet] catalog.json 读不到: \(Assets.catalogURL?.path ?? "-")")
            return nil
        }
        do {
            return try JSONDecoder().decode(Catalog.self, from: data)
        } catch {
            NSLog("[pet] catalog.json 解析失败：\(error)")
            return nil
        }
    }
}

// MARK: - 随机抽取

enum Pick {
    /// 等概率抽一个，尽量避开刚播过的那一段。
    static func one<T: Equatable>(_ pool: [T], avoid: T? = nil) -> T? {
        guard !pool.isEmpty else { return nil }
        if let avoid {
            let filtered = pool.filter { $0 != avoid }
            if !filtered.isEmpty { return filtered.randomElement() }
        }
        return pool.randomElement()
    }

    /// 按权重抽分类；镜像朝向下排除 noMirror 的分类。
    static func category(_ categories: [Category], mirrored: Bool) -> Category? {
        let usable = categories.filter { !$0.actions.isEmpty }
        guard !usable.isEmpty else { return nil }
        let eligible = mirrored ? usable.filter { $0.mirrorsAllowed } : usable
        let pool = eligible.isEmpty ? usable : eligible
        let total = pool.reduce(0.0) { $0 + max(0, $1.weight) }
        guard total > 0 else { return pool.first }
        var t = Double.random(in: 0..<total)
        for c in pool {
            t -= max(0, c.weight)
            if t <= 0 { return c }
        }
        return pool.last
    }
}
