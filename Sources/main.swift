import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var brain: PetBrain?
    private var menu: PetMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动参数 --character <包名>：直接换角色启动，方便脚本调用。
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--character"), i + 1 < argv.count {
            Pref.character = argv[i + 1]
        }

        let b = PetBrain()
        let m = PetMenuController(brain: b)
        b.menuController = m
        brain = b
        menu = m

        // 诊断：PET_SWITCH_TEST=<包名> 时启动 3 秒后自动切一次角色包。
        if let id = ProcessInfo.processInfo.environment["PET_SWITCH_TEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak b] in
                NSLog("[pet] 自检切换 → \(id)")
                b?.switchCharacter(id)
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screensChanged() {
        brain?.clampIntoWorkArea()
    }

    func applicationWillTerminate(_ notification: Notification) {
        brain?.savePosition()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 不占 Dock，只在顶部状态栏留一个爪印。
app.setActivationPolicy(.accessory)
app.run()
