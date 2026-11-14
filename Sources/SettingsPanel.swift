import AppKit
import SwiftUI

/// PRD §10 HUD 设置面板（C 档定稿视觉）：
/// NSPanel 不抢前台焦点 + hudWindow 实时背景模糊 + 大圆角大阴影，
/// 等宽大写节标题 / 键帽 chip / 0.15s 微淡入，外观跟随系统深浅色。
/// 纯 SwiftUI 勾选列表，勾选即实时生效（PRD §5），零 WebView。
final class SettingsPanel: NSPanel {
    static let size = NSSize(width: 380, height: 356)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0,
                                       width: SettingsPanel.size.width,
                                       height: SettingsPanel.size.height),
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

        let content = NSView(frame: NSRect(x: 0, y: 0,
                                           width: SettingsPanel.size.width,
                                           height: SettingsPanel.size.height))
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

// MARK: - 键帽 chip（PRD §10 借 NIL 的设计语言）

private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.10)))
    }
}

// MARK: - 模块行

private struct ModuleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var enabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: enabled) { _, _ in
                    NotificationCenter.default.post(name: .miniBarModulesChanged, object: nil)
                }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 面板内容

struct SettingsContent: View {
    @AppStorage("module.display") private var display = true
    @AppStorage("module.state") private var state = true
    @AppStorage("module.power") private var power = true
    @AppStorage("module.audio") private var audio = true
    @AppStorage("module.storage") private var storage = true

    /// PRD §10：仅 0.15s 级微淡入
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行：等宽大写 + 键帽（NIL 同款）
            HStack {
                Text("MINIBAR · 设置")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Keycap(text: "⌘ ,")
            }
            Divider()

            Text("模块")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(.tertiary)

            ModuleRow(icon: "sun.max", title: "显示控制",
                      subtitle: "亮度 · 对比度 · 旋转（鼠标所在屏路由）", enabled: $display)
            ModuleRow(icon: "moon", title: "状态与色彩",
                      subtitle: "深色 · 夜览", enabled: $state)
            ModuleRow(icon: "bolt", title: "电源管理",
                      subtitle: "关闭屏幕 · 系统休眠 · 防休眠", enabled: $power)
            ModuleRow(icon: "hifispeaker", title: "音频路由",
                      subtitle: "全局静音 · 扬声器/麦克风切换", enabled: $audio)
            ModuleRow(icon: "externaldrive", title: "存储管理",
                      subtitle: "逐盘安全弹出 · 重新挂载", enabled: $storage)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("勾选即加载，取消即彻底销毁：零监听 · 零 Timer · 零唤醒。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("v0.1.0 · 仅适配 macOS 15–27 · Apple Silicon")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) { appeared = true }
        }
    }
}
