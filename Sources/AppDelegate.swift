import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let shell = MenuBarShell()
    private var panel: SettingsPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // —— 单实例检测：同 bundle ID 已在跑就激活旧实例，自退 ——
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate(options: [.activateAllWindows])
                NSLog("[MiniBar] 已有实例 PID=\(existing.processIdentifier) 在跑，自退")
                NSApp.terminate(nil)
                exit(0)
                return
            }
        }

        shell.install()
        NotificationCenter.default.addObserver(
            self, selector: #selector(modulesChanged),
            name: ModuleEvent.modulesChanged, object: nil)
    }

    /// 懒人模块化：设置面板勾选变化 → 实时加载/销毁对应模块
    @objc private func modulesChanged() {
        shell.syncModules()
    }

    @objc func showSettings() {
        if panel == nil { panel = SettingsPanel() }
        panel?.show()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
