import AppKit
import AVFoundation
import QuartzCore

/// 偏好持久化。
enum Pref {
    private static let ud = UserDefaults.standard

    static var width: Double {
        get { ud.object(forKey: "pet.width") as? Double ?? 440 }
        set { ud.set(newValue, forKey: "pet.width") }
    }
    static var originX: Double? {
        get { ud.object(forKey: "pet.x") as? Double }
        set { ud.set(newValue, forKey: "pet.x") }
    }
    static var originY: Double? {
        get { ud.object(forKey: "pet.y") as? Double }
        set { ud.set(newValue, forKey: "pet.y") }
    }
    static var mirrored: Bool {
        get { ud.bool(forKey: "pet.mirrored") }
        set { ud.set(newValue, forKey: "pet.mirrored") }
    }
    static var chatter: Bool {
        get { ud.object(forKey: "pet.chatter") as? Bool ?? true }
        set { ud.set(newValue, forKey: "pet.chatter") }
    }
    static var sound: Bool {
        get { ud.object(forKey: "pet.sound") as? Bool ?? true }
        set { ud.set(newValue, forKey: "pet.sound") }
    }
    static var onTop: Bool {
        get { ud.object(forKey: "pet.onTop") as? Bool ?? true }
        set { ud.set(newValue, forKey: "pet.onTop") }
    }
    /// 当前角色包 id。
    static var character: String {
        get { ud.string(forKey: "pet.character") ?? "dsh" }
        set { ud.set(newValue, forKey: "pet.character") }
    }
}

private struct Flight {
    var vx: Double
    var vy: Double
    var onGround: Bool = false
    var rest: Double = 0
}

private struct Walk {
    var fromX: CGFloat
    var toX: CGFloat
    var y: CGFloat
    var start: CFTimeInterval
    var lead: Double
    var tail: Double
    var duration: Double
}

/// 桌宠本体：动画编排 + 物理 + 交互，全部跑在主线程。
final class PetBrain: NSObject, PetViewDelegate {
    private(set) var catalog = Catalog.load()
    let panel: PetPanel
    let content = PetContentView()
    let stage = AnimationStage()
    let bubble = BubbleWindow()

    enum Mode { case idle, action, turn, move, click, drag, fly, sleepStart, sleepLoop, sleepWake }

    private(set) var mode: Mode = .idle
    private(set) var sleeping = false
    private(set) var mirrored = Pref.mirrored

    private var tick: Timer?
    private var lastTick: CFTimeInterval = 0
    private var lastActionName = ""

    // 拖拽
    private var dragging = false
    private var dragOffset = NSPoint.zero
    private var pressPoint = NSPoint.zero
    private var pressOrigin = NSPoint.zero
    private var samples: [(t: CFTimeInterval, p: NSPoint)] = []

    // 物理
    private var flight: Flight?
    private var walk: Walk?
    private var squash: Double = 1
    private var squashVel: Double = 0

    // 碎碎念 / 点击性格
    private var chatterTimer: Timer?
    private var menuOpen = false
    private var clickSound: NSSound?
    private var pesterCount = 0
    private var lastClickAt: CFTimeInterval = 0

    override init() {
        let w = CGFloat(Pref.width)
        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: w * 9 / 16))
        super.init()

        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.masksToBounds = false
        content.layer?.addSublayer(stage.container)
        content.delegate = self
        panel.contentView = content
        panel.level = Pref.onTop ? .floating : .normal

        stage.layout(bounds: content.bounds)
        stage.mirrored = mirrored
        stage.onFinished = { [weak self] name in self?.handleFinished(name) }

        restorePosition()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        startTicking()
        playIdle()
        scheduleChatter()
        NSLog("[pet] 就位 frame=\(NSStringFromRect(panel.frame)) size=\(Int(panel.frame.width))")
    }

    // MARK: - 屏幕

    private var screen: NSScreen {
        panel.screen ?? NSScreen.main ?? NSScreen.screens.first!
    }
    private var workArea: NSRect { screen.visibleFrame }

    private func restorePosition() {
        var origin: NSPoint
        if let x = Pref.originX, let y = Pref.originY {
            origin = NSPoint(x: x, y: y)
        } else {
            origin = NSPoint(x: workArea.maxX - panel.frame.width - 48, y: workArea.minY + 6)
        }
        // 屏幕变化后可能跑到画面外，拉回来
        origin.x = min(max(origin.x, workArea.minX), workArea.maxX - panel.frame.width)
        origin.y = min(max(origin.y, workArea.minY), workArea.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
    }

    func clampIntoWorkArea() {
        var o = panel.frame.origin
        o.x = min(max(o.x, workArea.minX), workArea.maxX - panel.frame.width)
        o.y = min(max(o.y, workArea.minY), workArea.maxY - panel.frame.height)
        panel.setFrameOrigin(o)
    }

    // MARK: - 节拍

    private var busy: Bool {
        dragging || flight != nil || walk != nil
            || abs(squash - 1) > 0.002 || abs(squashVel) > 0.01
    }

    private func startTicking() {
        tick?.invalidate()
        lastTick = CACurrentMediaTime()
        let interval = busy ? 1.0 / 60 : 1.0 / 30
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func refreshTickRate() {
        guard let t = tick else { return startTicking() }
        let want = busy ? 1.0 / 60 : 1.0 / 30
        if abs(t.timeInterval - want) > 0.001 {
            startTicking()
        }
    }

    private func step() {
        let now = CACurrentMediaTime()
        var dt = now - lastTick
        lastTick = now
        if dt > 0.1 { dt = 0.1 }
        if dt <= 0 { return }

        stepSquash(dt)
        stepFlight(dt)
        stepWalk()
        pollMouse()
        renderSquash()
        refreshTickRate()
    }

    private func stepSquash(_ dt: Double) {
        guard abs(squash - 1) > 0.0005 || abs(squashVel) > 0.005 else { return }
        // 弹簧回弹：落地压扁之后自己弹回来，带一点过冲
        squashVel += (-320 * (squash - 1) - 22 * squashVel) * dt
        squash += squashVel * dt
        if abs(squash - 1) < 0.002 && abs(squashVel) < 0.02 {
            squash = 1
            squashVel = 0
        }
    }

    private func renderSquash() {
        var sy = squash
        if let f = flight, !f.onGround {
            sy *= 1 + min(0.14, abs(f.vy) / 9000)
        }
        let sx = 1 + (1 - sy) * 0.7
        stage.setSquash(x: max(0.6, sx), y: max(0.6, sy))
    }

    private func squashImpulse(_ speed: Double) {
        squash = 1 - min(0.30, speed / 5200)
        squashVel = 0
    }

    // MARK: - 物理

    private func stepFlight(_ dt: Double) {
        guard var f = flight else { return }
        let p = catalog.physics
        f.vy -= p.gravity * dt
        f.vx *= exp(-(f.onGround ? p.groundFriction : 0.40) * dt)

        let w = panel.frame.width
        let h = panel.frame.height
        let area = workArea
        var o = panel.frame.origin
        o.x += f.vx * dt
        o.y += f.vy * dt

        if o.y <= area.minY {
            o.y = area.minY
            if abs(f.vy) > 90 {
                squashImpulse(abs(f.vy))
                f.vy = -f.vy * p.restitution
                f.vx *= 0.94
            } else {
                f.vy = 0
                f.onGround = true
            }
        }
        if o.y + h >= area.maxY {
            o.y = area.maxY - h
            f.vy = -abs(f.vy) * p.restitution
        }
        if o.x <= area.minX {
            o.x = area.minX
            f.vx = -f.vx * p.restitution
        }
        if o.x + w >= area.maxX {
            o.x = area.maxX - w
            f.vx = -f.vx * p.restitution
        }
        panel.setFrameOrigin(o)

        if f.onGround && abs(f.vx) < 60 {
            f.rest += dt
            if f.rest > 0.10 {
                flight = nil
                mode = .idle
                savePosition()
                playIdle()
                return
            }
        } else {
            f.rest = 0
        }
        flight = f
    }

    private func stepWalk() {
        guard let m = walk else { return }
        let span = max(0.2, m.duration - m.lead - m.tail)
        let elapsed = CACurrentMediaTime() - m.start
        var progress = (elapsed - m.lead) / span
        progress = min(1, max(0, progress))
        let x = m.fromX + (m.toX - m.fromX) * CGFloat(progress)
        panel.setFrameOrigin(NSPoint(x: x, y: m.y))
        if progress >= 1 { walk = nil }
    }

    private func pollMouse() {
        guard !dragging, !menuOpen else { return }
        let p = NSEvent.mouseLocation
        let body = bodyRectOnScreen(padding: 0)
        let padded = bodyRectOnScreen(padding: 10)
        if panel.ignoresMouseEvents {
            if body.contains(p) { panel.ignoresMouseEvents = false }
        } else if !padded.contains(p) {
            panel.ignoresMouseEvents = true
        }
    }

    private func bodyRectOnScreen(padding: CGFloat) -> NSRect {
        let f = panel.frame
        let b = content.bodyRect
        return NSRect(
            x: f.minX + f.width * b.minX - padding,
            y: f.minY + f.height * b.minY - padding,
            width: f.width * b.width + padding * 2,
            height: f.height * b.height + padding * 2
        )
    }

    func savePosition() {
        Pref.originX = Double(panel.frame.origin.x)
        Pref.originY = Double(panel.frame.origin.y)
    }

    // MARK: - 动画编排

    private func allAnimationNames() -> [String] {
        var names = catalog.idle + catalog.turn + catalog.drag + catalog.clicks
        names += catalog.moves.actions.map(\.name)
        names += catalog.categories.flatMap(\.actions)
        names += catalog.whisper
        names += catalog.sleep.start + catalog.sleep.loop + catalog.sleep.end
        return names
    }

    private func playIdle() {
        guard let name = Pick.one(catalog.idle, avoid: nil) else { return }
        mode = .idle
        stage.play(name, loop: false)
    }

    private func pickNext() {
        guard !sleeping, !dragging, flight == nil else { return }
        let r = Double.random(in: 0..<1)
        let w = catalog.weights
        let idleEnd = w.idle / 100
        let turnEnd = (w.idle + w.turn) / 100
        let moveEnd = turnEnd + w.move / 100

        if r < idleEnd { playIdle(); return }
        if r < turnEnd { playTurn(); return }
        if r < moveEnd, tryWalk() { return }
        playRandomAction()
    }

    private func playTurn() {
        guard let name = Pick.one(catalog.turn) else { return playRandomAction() }
        mode = .turn
        stage.play(name, loop: false)
    }

    private func setMirrored(_ value: Bool) {
        mirrored = value
        Pref.mirrored = value
        stage.mirrored = value
    }

    @discardableResult
    private func tryWalk() -> Bool {
        guard let spec = Pick.one(catalog.moves.actions.map { $0.name }),
              let chosen = catalog.moves.actions.first(where: { $0.name == spec }) else { return false }
        let d = catalog.moves.default
        let p = chosen.params
        let scale = Double(panel.frame.width) / catalog.refWidth
        let minD = (p?.minDist ?? d.minDist ?? 60) * scale
        let maxD = max(minD, (p?.maxDist ?? d.maxDist ?? 240) * scale)
        let dir: CGFloat = mirrored ? 1 : -1
        let dist = CGFloat(Double.random(in: minD...maxD))

        let area = workArea
        let w = panel.frame.width
        let fromX = panel.frame.minX
        var toX = fromX + dir * dist
        toX = min(max(toX, area.minX + 2), area.maxX - w - 2)
        guard abs(toX - fromX) > 12 else { return false }

        walk = Walk(
            fromX: fromX, toX: toX, y: panel.frame.minY,
            start: CACurrentMediaTime(),
            lead: p?.leadSec ?? d.leadSec ?? 2,
            tail: p?.tailSec ?? d.tailSec ?? 2,
            duration: Assets.duration(chosen.name)
        )
        mode = .move
        stage.play(chosen.name, loop: false)
        NSLog("[pet] 走位 \(chosen.name) \(Int(fromX))→\(Int(toX))")
        return true
    }

    private func playRandomAction() {
        let cat = Pick.category(catalog.categories, mirrored: mirrored)
        guard let name = Pick.one(cat?.actions ?? catalog.idle, avoid: lastActionName) else { return }
        lastActionName = name
        mode = .action
        stage.play(name, loop: false)
        NSLog("[pet] 动作 [\(cat?.id ?? "-")] \(name)")
    }

    private func handleFinished(_ name: String) {
        switch mode {
        case .drag, .fly:
            return
        case .sleepStart:
            mode = .sleepLoop
            if let loop = catalog.sleep.loop.first { stage.play(loop, loop: true) }
        case .sleepWake:
            sleeping = false
            mode = .idle
            playIdle()
        case .turn:
            setMirrored(!mirrored)
            mode = .idle
            pickNext()
        case .move:
            walk = nil
            savePosition()
            mode = .idle
            pickNext()
        case .click:
            playIdle()
        case .sleepLoop:
            return
        case .idle, .action:
            pickNext()
        }
    }

    // MARK: - 交互

    func petDidPress(_ event: NSEvent) {
        pressPoint = NSEvent.mouseLocation
        pressOrigin = panel.frame.origin
        dragOffset = NSPoint(x: pressPoint.x - pressOrigin.x, y: pressPoint.y - pressOrigin.y)
        samples = []
    }

    func petDidDrag(_ event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging {
            guard hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 4 else { return }
            dragging = true
            flight = nil
            walk = nil
            menuOpen = false
            // 被拎起来就醒了，否则睡着的状态会和物理打架
            sleeping = false
            panel.ignoresMouseEvents = false
            mode = .drag
            if let dragAnim = Pick.one(catalog.drag) {
                stage.play(dragAnim, loop: true)
            }
        }
        let origin = NSPoint(x: p.x - dragOffset.x, y: p.y - dragOffset.y)
        panel.setFrameOrigin(origin)
        samples.append((CACurrentMediaTime(), origin))
        if samples.count > 16 { samples.removeFirst() }
    }

    func petDidRelease(_ event: NSEvent) {
        guard dragging else {
            handleClick()
            // 双击：再补一个向上的抛起，手感上就是"高兴地蹦一下"
            if event.clickCount >= 2 { hop() }
            return
        }
        dragging = false

        let now = CACurrentMediaTime()
        let recent = samples.filter { now - $0.t <= 0.10 }
        var vx: Double = 0
        var vy: Double = 0
        if recent.count >= 2, let first = recent.first, let last = recent.last {
            let dt = last.t - first.t
            if dt > 0.008 {
                vx = Double((last.p.x - first.p.x) / CGFloat(dt))
                vy = Double((last.p.y - first.p.y) / CGFloat(dt))
            }
        }
        let cap = 3200.0
        let speed = hypot(vx, vy)
        if speed > cap {
            vx *= cap / speed
            vy *= cap / speed
        }
        let power = catalog.physics.throwPower
        flight = Flight(vx: vx * power, vy: vy * power)
        mode = .fly
        savePosition()
    }

    private func handleClick() {
        if sleeping { wakeUp(); return }
        if mode == .sleepWake { return }

        // 挤压和音效每次都给，这样「被无视」也有点击手感，不像点空了。
        squashImpulse(700)
        playClickSound()

        // 连点戳太多次会炸毛；pesterThreshold 为 0 的角色包关闭这个行为。
        let now = CACurrentMediaTime()
        pesterCount = (now - lastClickAt <= catalog.pesterWindowSec) ? pesterCount + 1 : 1
        lastClickAt = now
        if catalog.pesterThreshold > 0, pesterCount >= catalog.pesterThreshold {
            pesterCount = 0
            let pool = catalog.pesterActions.isEmpty ? catalog.clicks : catalog.pesterActions
            if let name = Pick.one(pool) {
                mode = .action
                stage.play(name, loop: false)
            }
            if let text = Pick.one(catalog.pesterTexts) { say(text, anim: false) }
            return
        }

        // 概率无视：多半继续待机或东张西望，偶尔才甩一句。
        if Double.random(in: 0..<1) < catalog.clickIgnoreRate {
            let pool = catalog.ignoreActions.isEmpty ? catalog.idle : catalog.ignoreActions
            if let name = Pick.one(pool) {
                mode = .action
                stage.play(name, loop: false)
            }
            if let text = Pick.one(catalog.ignoreTexts), Double.random(in: 0..<1) < 0.45 {
                say(text, anim: false)
            }
            return
        }

        guard let name = Pick.one(catalog.clicks) else { return }
        mode = .click
        stage.play(name, loop: false)
    }

    private func playClickSound() {
        guard Pref.sound else { return }
        if clickSound == nil, let url = Assets.clickSound {
            clickSound = NSSound(contentsOf: url, byReference: true)
        }
        clickSound?.stop()
        clickSound?.play()
    }

    /// 双击时往上抛一下。
    private func hop() {
        guard flight == nil, !sleeping else { return }
        walk = nil
        flight = Flight(vx: 0, vy: 760)
        mode = .fly
        squashImpulse(420)
    }

    func petDidRightClick(_ event: NSEvent) {
        showMenu()
    }

    // MARK: - 睡觉

    func sleepNow() {
        guard !sleeping else { return }
        sleeping = true
        flight = nil
        walk = nil
        mode = .sleepStart
        say(catalog.sleepStartTexts.randomElement() ?? "好困……", anim: false)
        if let start = Pick.one(catalog.sleep.start) {
            stage.play(start, loop: false)
        } else {
            handleFinished("")
        }
    }

    func wakeUp() {
        guard sleeping else { return }
        sleeping = false
        mode = .sleepWake
        say(catalog.sleepEndTexts.randomElement() ?? "我醒了。", anim: false)
        if let end = Pick.one(catalog.sleep.end) {
            stage.play(end, loop: false)
        } else {
            playIdle()
        }
    }

    func toggleSleep() {
        sleeping ? wakeUp() : sleepNow()
    }

    // MARK: - 碎碎念

    private func scheduleChatter() {
        chatterTimer?.invalidate()
        let delay = Double.random(in: catalog.chatterRange)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.chatter()
        }
        RunLoop.main.add(t, forMode: .common)
        chatterTimer = t
    }

    private func chatter() {
        scheduleChatter()
        guard Pref.chatter, !sleeping, !dragging, flight == nil, walk == nil, mode != .sleepWake else { return }
        say(catalog.chatterLines.randomElement() ?? "", anim: true)
    }

    func say(_ text: String, anim: Bool) {
        guard !text.isEmpty else { return }
        bubble.show(text, above: panel.frame)
        guard anim, !sleeping else { return }
        guard let name = Pick.one(catalog.whisper) else { return }
        mode = .action
        stage.play(name, loop: false)
    }

    // MARK: - 尺寸 / 显隐

    func setWidth(_ w: Double) {
        Pref.width = w
        let size = NSSize(width: w, height: w * 9 / 16)
        var frame = panel.frame
        let centerX = frame.midX
        frame.size = size
        frame.origin.x = centerX - size.width / 2
        frame.origin.y = max(workArea.minY, frame.minY)
        panel.setFrame(frame, display: true)
        stage.layout(bounds: CGRect(origin: .zero, size: size))
        clampIntoWorkArea()
        savePosition()
    }

    func resetPosition() {
        panel.setFrameOrigin(NSPoint(
            x: workArea.maxX - panel.frame.width - 48,
            y: workArea.minY + 6
        ))
        savePosition()
    }

    func toggleVisible() {
        if panel.isVisible {
            panel.orderOut(nil)
            stage.setPaused(true)   // 藏起来就别解码了
            bubble.hide()
        } else {
            panel.orderFrontRegardless()
            stage.setPaused(false)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func applyOnTop() {
        panel.level = Pref.onTop ? .floating : .normal
    }

    func setMenuOpen(_ open: Bool) {
        menuOpen = open
        if !open { pollMouse() }
    }

    // MARK: - 菜单入口

    weak var menuController: PetMenuController?

    func showMenu() {
        guard let view = panel.contentView, let menu = menuController,
              let event = NSApp.currentEvent else { return }
        menu.popUp(event: event, in: view)
    }

    /// 点播一段指定动画（菜单里选的那种）。
    func playNamed(_ name: String) {
        if sleeping {
            say(catalog.sleepRefuseTexts.randomElement() ?? "我在睡觉……", anim: false)
            return
        }
        flight = nil
        walk = nil
        dragging = false
        lastActionName = name
        mode = .action
        stage.play(name, loop: false)
    }

    func forceWalk() {
        if sleeping {
            say(catalog.sleepRefuseTexts.randomElement() ?? "我在睡觉……", anim: false)
            return
        }
        guard flight == nil else { return }
        if !tryWalk() { playRandomAction() }
    }

    func forceTurn() {
        if sleeping {
            say(catalog.sleepRefuseTexts.randomElement() ?? "我在睡觉……", anim: false)
            return
        }
        guard flight == nil else { return }
        playTurn()
    }

    /// 换角色包：清缓存、重读 catalog、重置状态，再播一段待机。
    @discardableResult
    func switchCharacter(_ id: String) -> Bool {
        guard id != Assets.packID, Assets.packURL(id) != nil else { return false }
        let previous = Assets.packID
        Pref.character = id
        Assets.setPack(id)
        guard let next = Catalog.tryLoad() else {
            NSLog("[pet] 角色包 \(id) 读不了，回滚")
            Pref.character = previous
            Assets.setPack(previous)
            return false
        }

        catalog = next
        chatterTimer?.invalidate()
        chatterTimer = nil
        flight = nil
        walk = nil
        dragging = false
        sleeping = false
        menuOpen = false
        bubble.hide()
        stage.stop()
        lastActionName = ""
        playIdle()
        scheduleChatter()
        NSLog("[pet] 换角色 → \(id)（\(next.idle.count + next.clicks.count + next.categories.flatMap(\.actions).count) 段可用）")
        return true
    }

    func quit() {
        savePosition()
        NSApp.terminate(nil)
    }
}
