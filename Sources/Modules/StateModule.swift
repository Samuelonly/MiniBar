import AppKit

/// 状态与色彩模块（PRD §3.2）
/// 深浅色 chip 只切 MiniBar 面板皮肤（PanelAppearance：跟随系统/浅色/深色三态，可回退）；
/// 夜览走私有 CoreBrightness CBBlueLightClient（已批准，PRD §9-3）。
final class StateModule: NSObject, MiniBarModule {
    var name: String { "state" }

    private lazy var nightShift = NightShiftController()

    func activate() {}
    func deactivate() {}

    @objc private func toggleDark(_ sender: NSMenuItem) {
        PanelAppearance.toggleManual()
    }

    /// 显式回到自动：跟随系统深浅色，之后系统切换时面板继续跟着变
    @objc private func useSystemAppearance(_ sender: NSMenuItem) {
        PanelAppearance.setMode(.system)
    }

    @objc private func toggleNight(_ sender: NSMenuItem) {
        guard let nightShift else { return }
        let target = !nightShift.isEnabled
        nightShift.setEnabled(target)
        sender.state = target ? .on : .off
    }

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }

        // HTML .grid-row：一行两枚 .chip（高度 30 / 圆角 8 / 字号 12），
        // 带 submenu 的父行只为装下两枚 chip，identifier 让渲染器按 chip 行而非 Block 处理。
        let chips = NSMenu()
        chips.autoenablesItems = false

        // 「跟随系统」排第一：显式可回退的自动态，选中态直接告诉用户当前是否为自动。
        let system = NSMenuItem(title: L("settings.appearance.system"),
                                action: #selector(useSystemAppearance(_:)), keyEquivalent: "")
        system.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                               accessibilityDescription: nil)
        system.target = self
        system.state = PanelAppearance.mode == .system ? .on : .off
        system.identifier = NSUserInterfaceItemIdentifier("minibar.skinAuto")
        chips.addItem(system)

        // 文案语义 = "点我切换到 XX"，按 MiniBar 面板的有效皮肤判断：
        // 面板深色 → chip 显示「白天」；面板浅色 → chip 显示「深色」。chip 是按钮，无选中态。
        let darkChipTitle = PanelAppearance.current == .dark
            ? L("menu.appearance.light") : L("menu.appearance.dark")
        let dark = NSMenuItem(title: darkChipTitle, action: #selector(toggleDark(_:)), keyEquivalent: "")
        dark.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        dark.target = self
        chips.addItem(dark)

        let night = NSMenuItem(title: L("menu.nightshift"), action: #selector(toggleNight(_:)), keyEquivalent: "")
        night.image = NSImage(systemSymbolName: "moon", accessibilityDescription: nil)
        night.target = self
        night.state = (nightShift?.isEnabled ?? false) ? .on : .off
        chips.addItem(night)

        let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        row.identifier = NSUserInterfaceItemIdentifier("minibar.chipRow")
        row.submenu = chips

        return [sectionHeader(L("menu.section.appearance")), row]
    }
}
