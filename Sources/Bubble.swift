import AppKit

/// 头顶气泡：一块自适应深浅色的毛玻璃，只显示文字，永不拦截鼠标。
final class BubbleWindow: NSPanel {
    private let effect = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    private let padX: CGFloat = 13
    private let padY: CGFloat = 9
    private let maxWidth: CGFloat = 210

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 12.5, weight: .regular)
        label.textColor = .labelColor
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.lineBreakMode = .byWordWrapping

        contentView = effect
        effect.addSubview(label)
    }

    func show(_ text: String, above frame: NSRect) {
        guard !text.isEmpty else { return }
        label.stringValue = text
        let font = label.font ?? .systemFont(ofSize: 12.5)
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let textW = min(maxWidth, max(28, ceil(bounding.width) + 2))
        let textH = max(16, ceil(bounding.height))
        let w = textW + padX * 2
        let h = textH + padY * 2

        label.frame = NSRect(x: padX, y: padY, width: textW, height: textH)

        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? frame
        var x = frame.midX - w / 2
        var y = frame.maxY - h * 0.30
        x = min(max(x, area.minX + 6), area.maxX - w - 6)
        if y + h > area.maxY { y = frame.minY + frame.height * 0.55 }
        y = max(y, area.minY + 4)

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            animator().alphaValue = 1
        }

        hideTimer?.invalidate()
        let t = Timer(timeInterval: 4.6, repeats: false) { [weak self] _ in self?.hide() }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    func hide() {
        hideTimer?.invalidate()
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}
