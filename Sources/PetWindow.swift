import AppKit

protocol PetViewDelegate: AnyObject {
    func petDidPress(_ event: NSEvent)
    func petDidDrag(_ event: NSEvent)
    func petDidRelease(_ event: NSEvent)
    func petDidRightClick(_ event: NSEvent)
}

/// 宠物窗口的内容视图：只在自己的身体范围内接受鼠标，其余区域让给桌面上真正的应用。
final class PetContentView: NSView {
    weak var delegate: PetViewDelegate?

    /// 身体区域（归一化 0~1）。素材里角色只占画面中间一块，边上是透明特效区。
    var bodyRect = CGRect(x: 0.29, y: 0.06, width: 0.43, height: 0.80)

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let norm = CGRect(
            x: (point.x - bounds.minX) / max(1, bounds.width),
            y: (point.y - bounds.minY) / max(1, bounds.height),
            width: 0, height: 0
        )
        return bodyRect.contains(norm.origin) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            // 双击：甩起来一下，当作玩耍。
            delegate?.petDidPress(event)
            delegate?.petDidRelease(event)
            return
        }
        delegate?.petDidPress(event)
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.petDidDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.petDidRelease(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.petDidRightClick(event)
    }
}

/// 无边框透明置顶小窗；不抢焦点（非激活面板）。
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        animationBehavior = .none
        ignoresMouseEvents = true
    }
}
