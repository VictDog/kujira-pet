import AVFoundation
import AppKit

/// 视频动画台：A/B 两个 AVPlayerLayer 轮换。
///
/// 切换时新片段先在后台解码，等首帧真正就绪（isReadyForDisplay）再原子换面，
/// 所以不会出现黑场或中间空隙；旧的一帧留到最后一刻，切过去就是干净的硬切。
final class AnimationStage {
    /// 承载两个视频层的容器；挤压（squash）与镜像都作用在它下面。
    let container = CALayer()

    private var slots: [AVPlayerLayer] = []
    private var items: [AVPlayerItem?] = [nil, nil]
    private var players: [AVPlayer?] = [nil, nil]
    private var loopers: [AVPlayerLooper?] = [nil, nil]
    private var front = 0
    private var generation = 0

    private var endObserver: NSObjectProtocol?
    private var readyObservation: NSKeyValueObservation?
    private var revealFallback: Timer?

    /// 非循环片段播完时回调（参数是动画名）。
    var onFinished: ((String) -> Void)?

    private(set) var currentName = ""
    private(set) var currentDuration = Assets.fallbackDuration
    private(set) var isLooping = false

    /// 朝向：true = 镜像（朝右）。
    var mirrored = false {
        didSet { if mirrored != oldValue { applyMirror() } }
    }

    init() {
        container.masksToBounds = false
        container.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]

        for _ in 0..<2 {
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = NSColor.clear.cgColor
            layer.isOpaque = false
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer.isHidden = true
            slots.append(layer)
            container.addSublayer(layer)
        }
    }

    /// 尺寸随窗口变化（窗口缩放 / 换屏）。
    func layout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = bounds
        // 挤压锚在角色脚下（素材里脚底约在画面高度 8.3% 处），不是窗口底边。
        let footY = bounds.height * 0.083
        container.anchorPoint = CGPoint(x: 0.5, y: 0.083)
        container.position = CGPoint(x: bounds.midX, y: footY)
        for slot in slots {
            slot.bounds = bounds
            slot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
        applyMirror()
    }

    // MARK: - 播放

    func play(_ name: String, loop: Bool) {
        guard let url = Assets.url(name) else { return }
        generation += 1
        let gen = generation

        currentName = name
        isLooping = loop
        currentDuration = Assets.duration(name)

        let idx = 1 - front
        teardown(idx)

        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .pause
        // 关键：桌宠不该拦住屏幕休眠。
        queue.preventsDisplaySleepDuringVideoPlayback = false

        let template = AVPlayerItem(url: url)
        if loop {
            loopers[idx] = AVPlayerLooper(player: queue, templateItem: template)
        } else {
            queue.replaceCurrentItem(with: template)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: template, queue: .main
            ) { [weak self] _ in
                guard let self, gen == self.generation else { return }
                self.onFinished?(name)
            }
        }
        players[idx] = queue
        items[idx] = template
        slots[idx].player = queue
        slots[idx].isHidden = true
        queue.play()

        // 首帧就绪即换面；万一解码慢就给个兜底，别让旧画面冻太久。
        readyObservation = slots[idx].observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard let self, gen == self.generation, layer.isReadyForDisplay else { return }
            self.reveal(idx)
        }
        revealFallback?.invalidate()
        revealFallback = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self, gen == self.generation else { return }
            self.reveal(idx)
        }
        RunLoop.main.add(revealFallback!, forMode: .common)
    }

    private func reveal(_ idx: Int) {
        guard idx != front else { return }
        revealFallback?.invalidate()
        readyObservation = nil

        if let item = items[idx] {
            let d = CMTimeGetSeconds(item.duration)
            if d.isFinite, d > 0.2 { Assets.record(currentName, d) }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slots[front].isHidden = true
        players[front]?.pause()
        slots[idx].isHidden = false
        CATransaction.commit()

        front = idx
        NSLog("[pet] 首帧就绪 \(currentName) \(Int(slots[idx].bounds.width))x\(Int(slots[idx].bounds.height))")
    }

    private func teardown(_ idx: Int) {
        slots[idx].isHidden = true
        slots[idx].player = nil
        players[idx]?.pause()
        players[idx] = nil
        items[idx] = nil
        loopers[idx] = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func applyMirror() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let t = CATransform3DMakeScale(mirrored ? -1 : 1, 1, 1)
        for slot in slots { slot.transform = t }
        CATransaction.commit()
    }

    // MARK: - 挤压

    func setSquash(x: CGFloat, y: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.transform = CATransform3DMakeScale(x, y, 1)
        CATransaction.commit()
    }

    func setPaused(_ paused: Bool) {
        guard let p = players[front] else { return }
        paused ? p.pause() : p.play()
    }

    func stop() {
        generation += 1
        for i in 0..<2 { teardown(i) }
    }
}
