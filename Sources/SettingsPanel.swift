import AppKit
import SwiftUI

/// PRD §10 HUD 设置面板：NSPanel + hudWindow 毛玻璃 + nonactivating 不抢前台焦点。
/// 纯 SwiftUI 勾选列表，勾选即实时生效（PRD §5），不引入任何 WebView 技术。
final class SettingsPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 280),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        title = "MiniBar 设置"
        level = .floating
        isMovableByWindowBackground = true

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 280))
        blur.frame = content.bounds
        blur.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: SettingsContent())
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(blur)
        content.addSubview(host)
        contentView = content
        center()
    }

    /// nonactivating：弹出不抢前台 App 焦点（PRD §10 遥控器哲学的物理体现）
    func show() {
        orderFrontRegardless()
    }
}

struct SettingsContent: View {
    @AppStorage("module.display") private var display = true
    @AppStorage("module.state") private var state = true
    @AppStorage("module.power") private var power = true
    @AppStorage("module.audio") private var audio = true
    @AppStorage("module.storage") private var storage = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模块")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(.secondary)
            Toggle("显示控制", isOn: $display)
            Toggle("状态与色彩", isOn: $state)
            Toggle("电源管理", isOn: $power)
            Toggle("音频路由", isOn: $audio)
            Toggle("存储管理", isOn: $storage)
            Divider()
            Text("勾选即加载，取消即彻底销毁：零监听、零 Timer、零唤醒。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .onChange(of: display) { _, _ in notify() }
        .onChange(of: state) { _, _ in notify() }
        .onChange(of: power) { _, _ in notify() }
        .onChange(of: audio) { _, _ in notify() }
        .onChange(of: storage) { _, _ in notify() }
    }

    private func notify() {
        NotificationCenter.default.post(name: .miniBarModulesChanged, object: nil)
    }
}
