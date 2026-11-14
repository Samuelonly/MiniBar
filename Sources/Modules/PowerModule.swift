import AppKit

/// 电源管理模块（PRD §3.3，文案直白：关闭屏幕 / 系统休眠 / 防休眠）
final class PowerModule: NSObject, MiniBarModule {
    var name: String { "power" }

    private var keepAwakeProcess: Process?

    func activate() {}
    func deactivate() { stopKeepAwake() }

    /// 关闭屏幕（主机继续运行）
    @objc func screenSleep() {
        runDetached("/usr/bin/pmset", ["displaysleepnow"])
    }

    @objc func systemSleep() {
        runDetached("/usr/bin/pmset", ["sleepnow"])
    }

    /// 防休眠：独立 caffeinate 进程，App 退出后依然生效（PRD §6 特例）
    @objc func toggleKeepAwake(_ sender: NSMenuItem) {
        if keepAwakeProcess?.isRunning == true {
            stopKeepAwake()
            sender.state = .off
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-i"]
            try? process.run()
            keepAwakeProcess = process
            sender.state = .on
        }
    }

    private func stopKeepAwake() {
        keepAwakeProcess?.terminate()
        keepAwakeProcess = nil
    }

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }
        return [sectionHeader("电源"),
                menuItem("关闭屏幕", symbol: "display",
                         action: #selector(screenSleep), target: self),
                menuItem("系统休眠", symbol: "moon.zzz",
                         action: #selector(systemSleep), target: self),
                menuItem("防休眠", symbol: "bolt",
                         action: #selector(toggleKeepAwake), target: self,
                         state: keepAwakeProcess?.isRunning == true ? .on : .off)]
    }
}
