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

/// 整份动画目录，来自 Resources/catalog.json。
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
