import AppKit
import ServiceManagement

/// 右键菜单 + 顶部状态栏。
final class PetMenuController: NSObject {
    weak var brain: PetBrain?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?

    private let sizePresets: [(String, Double)] = [("小", 340), ("中", 440), ("大", 560)]

    init(brain: PetBrain) {
        self.brain = brain
        super.init()
        setupStatusItem()
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "桌宠")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Kujira 桌宠"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // MARK: - 右键菜单

    func popUp(event: NSEvent, in view: NSView) {
        brain?.setMenuOpen(true)
        let menu = buildMainMenu(contextual: true)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        brain?.setMenuOpen(false)
    }

    private func buildMainMenu(contextual: Bool) -> NSMenu {
        guard let brain else { return NSMenu() }
        let menu = NSMenu()

        if contextual {
            let actions = NSMenuItem(title: "换个动作", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for cat in brain.catalog.categories {
                let catItem = NSMenuItem(title: cat.id, action: nil, keyEquivalent: "")
                let catMenu = NSMenu()
                for name in cat.actions {
                    let mi = NSMenuItem(title: name, action: #selector(playAnim(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = name
                    catMenu.addItem(mi)
                }
                catItem.submenu = catMenu
                sub.addItem(catItem)
            }
            sub.addItem(.separator())
            for name in brain.catalog.whisper {
                let mi = NSMenuItem(title: name, action: #selector(playAnim(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = name
                sub.addItem(mi)
            }
            actions.submenu = sub
            menu.addItem(actions)

            menu.addItem(makeItem("走两步", #selector(walkAction)))
            menu.addItem(makeItem("转个身", #selector(turnAction)))
            menu.addItem(.separator())
            menu.addItem(makeItem(brain.sleeping ? "叫醒她" : "睡一会儿", #selector(toggleSleep)))
            menu.addItem(.separator())
        } else {
            menu.addItem(makeItem(brain.isVisible ? "隐藏桌宠" : "显示桌宠", #selector(toggleVisible)))
            menu.addItem(makeItem(brain.sleeping ? "叫醒她" : "睡一会儿", #selector(toggleSleep)))
            menu.addItem(.separator())
        }

        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (label, value) in sizePresets {
            let mi = NSMenuItem(title: label, action: #selector(changeSize(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = value
            mi.state = abs(Double(brain.panel.frame.width) - value) < 1 ? .on : .off
            sizeMenu.addItem(mi)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(buildCharacterMenu())

        if contextual {
            menu.addItem(makeItem("回到右下角", #selector(resetPosition)))
            menu.addItem(.separator())
            menu.addItem(makeItem("碎碎念", #selector(toggleChatter), state: Pref.chatter))
            menu.addItem(makeItem("点击音效", #selector(toggleSound), state: Pref.sound))
            menu.addItem(makeItem("始终置顶", #selector(toggleOnTop), state: Pref.onTop))
            menu.addItem(makeItem("开机自动启动", #selector(toggleLoginItem), state: isLoginItemEnabled))
            menu.addItem(.separator())
            menu.addItem(makeItem("关于 Kujira 桌宠", #selector(showAbout)))
        }

        menu.addItem(makeItem("退出", #selector(quit)))
        return menu
    }

    /// 角色包列表 + 打开角色文件夹的入口。
    private func buildCharacterMenu() -> NSMenuItem {
        let packs = Assets.availablePacks()
        let item = NSMenuItem(title: "更换角色", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        for id in packs {
            let mi = NSMenuItem(title: Assets.title(for: id), action: #selector(switchCharacter(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
            mi.state = id == Assets.packID ? .on : .off
            sub.addItem(mi)
        }

        if packs.count <= 1 {
            let hint = NSMenuItem(title: "还没有别的角色包", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
        }

        sub.addItem(.separator())
        let open = NSMenuItem(title: "打开角色文件夹…", action: #selector(openCharacterFolder), keyEquivalent: "")
        open.target = self
        sub.addItem(open)
        let guide = NSMenuItem(title: "把 makechar 生成的角色包放进去就会出现在上面", action: nil, keyEquivalent: "")
        guide.isEnabled = false
        sub.addItem(guide)

        item.submenu = sub
        return item
    }

    private func makeItem(_ title: String, _ selector: Selector, state: Bool = false) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        mi.target = self
        mi.state = state ? .on : .off
        return mi
    }

    // MARK: - 动作

    @objc private func playAnim(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        brain?.playNamed(name)
    }

    @objc private func walkAction() { brain?.forceWalk() }
    @objc private func turnAction() { brain?.forceTurn() }
    @objc private func toggleSleep() { brain?.toggleSleep() }
    @objc private func resetPosition() { brain?.resetPosition() }
    @objc private func toggleVisible() { brain?.toggleVisible() }
    @objc private func quit() { brain?.quit() }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        brain?.setWidth(value)
    }

    @objc private func switchCharacter(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if brain?.switchCharacter(id) == false {
            NSSound.beep()
        }
    }

    @objc private func openCharacterFolder() {
        let dir = Assets.prepareExternalRoot()
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    @objc private func toggleChatter() {
        Pref.chatter.toggle()
    }

    @objc private func toggleSound() {
        Pref.sound.toggle()
    }

    @objc private func toggleOnTop() {
        Pref.onTop.toggle()
        brain?.applyOnTop()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Kujira 桌宠",
            .credits: NSAttributedString(
                string: "基于 PC2005-cloud/dsh-pet 的动画素材与编排规则，用 Swift + AVFoundation 重写为 macOS 原生桌宠。",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }

    // MARK: - 开机自启

    private var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        do {
            if isLoginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法\(isLoginItemEnabled ? "关闭" : "开启")开机自动启动"
            alert.informativeText = "\(error.localizedDescription)\n\n建议先把 App 拖进「应用程序」文件夹再试。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

extension PetMenuController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        for item in buildMainMenu(contextual: false).items {
            menu.addItem(item)
        }
    }
}
