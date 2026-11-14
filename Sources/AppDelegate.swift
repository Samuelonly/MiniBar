import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let shell = MenuBarShell()
    private var panel: SettingsPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
