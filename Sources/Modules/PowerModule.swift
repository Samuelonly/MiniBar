import AppKit

/// 电源管理模块（PRD §3.3/§3.6，文案直白：屏幕休眠 / 系统休眠 / 防休眠）
/// 三行全部是开关；屏幕休眠状态经 NSWorkspace screensDidSleep/Wake 与真实状态同步；
/// 防休眠 = 独立 caffeinate 进程（PRD §6 特例）；图标用咖啡杯（caffeinate 命名梗）。
final class PowerModule: NSObject, MiniBarModule {
    var name: String { "power" }

    private var keepAwakeProcess: Process?
    private var sleepObservers: [NSObjectProtocol] = []
    private var screenAsleep = false

    func activate() {
        guard sleepObservers.isEmpty else { return }
        let center = NotificationCenter.default
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenAsleep = true
            // 通知 HUD 面板重建 model → 开关自动变成蓝色 on
            center.post(name: ModuleEvent.menuRefresh, object: nil)
        })
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenAsleep = false
            // 屏幕被用户唤醒了 → 开关自动归位
            center.post(name: ModuleEvent.menuRefresh, object: nil)
        })
    }

    func deactivate() {
        stopKeepAwake()
        sleepObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sleepObservers.removeAll()
        screenAsleep = false
    }

    /// 屏幕休眠开关：开=关闭屏幕；用户唤醒屏幕后开关自动归位（screensDidWake 同步）
    /// 关键：先 dismiss HUD 面板再 displaysleepnow，否则面板重绘会把显示器立刻唤醒
    /// （实测：displaysleepnow 刚睡 0.1s，HUD 的 menuRefresh 触发 window update → 显示器又醒了）
    @objc func toggleScreenSleep(_ sender: NSMenuItem) {
        if screenAsleep {
            runDetached("/usr/bin/caffeinate", ["-u", "-t", "2"])
            screenAsleep = false
            sender.state = .off
        } else {
            // 只 dismiss HUD 面板，然后让显示器睡。
            // 实测（pmset -g log）：statusItem 窗口存在时 displaysleepnow 能稳定保持休眠，
            // 之前的 NSApp.hide(nil) 会把焦点交给别的 App，那次激活被系统当成用户活动 →
            // 显示器立刻唤醒（off/on 同一秒），这才是"闪一下"的根因。已移除。
            NotificationCenter.default.post(name: Notification.Name("minibar.willSleep"), object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.screenAsleep = true
                sender.state = .on
                // displaysleepnow：让显示器睡，Mac mini 本身不睡
                runDetached("/usr/bin/pmset", ["displaysleepnow"])
            }
        }
    }

    /// 系统休眠开关：被防休眠阻断时发行内警示（PRD §3.6 "要提醒就都提醒"）
    @objc func toggleSystemSleep(_ sender: NSMenuItem) {
        if keepAwakeProcess?.isRunning == true {
            NotificationCenter.default.post(name: ModuleEvent.rowHint, object: nil, userInfo: [
                "item": sender,
                "text": L("menu.hint.blockedByKeepAwake"),
                "warn": true,
            ])
            sender.state = .off
        } else {
            sender.state = .on
            runDetached("/usr/bin/pmset", ["sleepnow"])
        }
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

        func switchRow(_ title: String, symbol: String, action: Selector, state: NSControl.StateValue) -> NSMenuItem {
            let item = menuItem(title, symbol: symbol, action: action, target: self, state: state)
            item.identifier = NSUserInterfaceItemIdentifier("minibar.switch")
            return item
        }

        return [sectionHeader(L("menu.section.power")),
                switchRow(L("menu.power.screenSleep"), symbol: "display",
                          action: #selector(toggleScreenSleep(_:)),
                          state: screenAsleep ? .on : .off),
                switchRow(L("menu.power.systemSleep"), symbol: "moon.zzz",
                          action: #selector(toggleSystemSleep(_:)),
                          state: .off),
                switchRow(L("menu.power.keepAwake"), symbol: "cup.and.saucer",
                          action: #selector(toggleKeepAwake(_:)),
                          state: keepAwakeProcess?.isRunning == true ? .on : .off)]
    }
}
