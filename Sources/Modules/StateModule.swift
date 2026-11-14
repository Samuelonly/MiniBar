import AppKit

/// 状态与色彩模块（PRD §3.2）
/// 深色模式走 osascript（一次性 Automation 授权已批准，PRD §9-2）；
/// 夜览 TODO(1.0)：私有 CoreBrightness CBBlueLightClient（已批准，PRD §9-3）。
final class StateModule: NSObject, MiniBarModule {
    var name: String { "state" }

    func activate() {}
    func deactivate() {}

    private var isDark: Bool {
        let value = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString,
                                              "NSGlobalDomain" as CFString)
        return (value as? String) == "Dark"
    }

    @objc private func toggleDark(_ sender: NSButton) {
        let target = !isDark
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(target)"
        runDetached("/usr/bin/osascript", ["-e", script])
        sender.state = target ? .on : .off
    }

    @objc private func toggleNight(_ sender: NSButton) {
        sender.state = sender.state == .on ? .off : .on
    }

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }

        let dark = NSButton(title: " 深色", target: self, action: #selector(toggleDark(_:)))
        dark.bezelStyle = .rounded
        dark.setButtonType(.pushOnPushOff)
        dark.controlSize = .small
        dark.font = NSFont.systemFont(ofSize: 11)
        dark.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        dark.imagePosition = .imageLeading
        dark.state = isDark ? .on : .off

        let night = NSButton(title: " 夜览", target: self, action: #selector(toggleNight(_:)))
        night.bezelStyle = .rounded
        night.setButtonType(.pushOnPushOff)
        night.controlSize = .small
        night.font = NSFont.systemFont(ofSize: 11)
        night.image = NSImage(systemSymbolName: "moon", accessibilityDescription: nil)
        night.imagePosition = .imageLeading

        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = menuRow(height: 28, subviews: [dark, night])

        return [sectionHeader("状态"), item]
    }
}
