import AppKit
import SwiftUI

/// PRD §10 HUD 设置面板（C 档定稿视觉）：
/// NSPanel 不抢前台焦点 + hudWindow 实时背景模糊 + 大圆角大阴影，
/// 等宽大写节标题 / 键帽 chip / 0.15s 微淡入，外观跟随系统深浅色。
/// 纯 SwiftUI 勾选列表，勾选即实时生效（PRD §5），零 WebView。
final class SettingsPanel: NSPanel {
    static let size = NSSize(width: 380, height: 400)

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
        titleVisibility = .hidden
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
                    NotificationCenter.default.post(name: ModuleEvent.modulesChanged, object: nil)
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

    // MARK: - 检查更新（GitHub Releases，零依赖）

    private enum UpdateStatus {
        case idle
        case checking
        case latest(String)
        case available(String, URL)
        case noRelease
        case networkError
    }

    @State private var updateStatus: UpdateStatus = .idle

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    @ViewBuilder private var updateView: some View {
        switch updateStatus {
        case .idle:
            Button(L("settings.version.check")) { checkForUpdate() }
                .font(.system(size: 10, design: .monospaced))
                .buttonStyle(.link)
        case .checking:
            Text(L("settings.version.checking"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        case .latest(let version):
            Text(String(format: L("settings.version.latest"), version))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        case .available(let tag, let url):
            Link(String(format: L("settings.version.available"), tag), destination: url)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        case .noRelease:
            Text(L("settings.version.none"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        case .networkError:
            Button(L("settings.version.retry")) { checkForUpdate() }
                .font(.system(size: 10, design: .monospaced))
                .buttonStyle(.link)
        }
    }

    private func checkForUpdate() {
        updateStatus = .checking
        Task {
            var status = UpdateStatus.networkError
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/Samuelonly/MiniBar/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 404 {
                    status = .noRelease
                } else if statusCode == 200,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let tag = json["tag_name"] as? String {
                    let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                    if isNewer(remote, than: currentVersion) {
                        status = .available(tag, URL(string: "https://github.com/Samuelonly/MiniBar/releases/latest")!)
                    } else {
                        status = .latest(remote)
                    }
                }
            } catch {
                status = .networkError
            }
            await MainActor.run { updateStatus = status }
        }
    }

    private func isNewer(_ candidate: String, than baseline: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = baseline.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行：等宽大写（NIL 同款）；不放键帽——面板是平的，无返回概念
            Text(L("settings.title"))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(.secondary)
            Divider()

            // PRD §10 文案纪律：功能说明置顶，用户语言，两行
            VStack(alignment: .leading, spacing: 4) {
                Text(L("settings.note.effective"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(L("settings.note.noResident"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Text(L("settings.section.modules"))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(.tertiary)

            ModuleRow(icon: "sun.max", title: L("module.display.title"),
                      subtitle: L("module.display.subtitle"), enabled: $display)
            ModuleRow(icon: "moon", title: L("module.state.title"),
                      subtitle: L("module.state.subtitle"), enabled: $state)
            ModuleRow(icon: "bolt", title: L("module.power.title"),
                      subtitle: L("module.power.subtitle"), enabled: $power)
            ModuleRow(icon: "hifispeaker", title: L("module.audio.title"),
                      subtitle: L("module.audio.subtitle"), enabled: $audio)
            ModuleRow(icon: "externaldrive", title: L("module.storage.title"),
                      subtitle: L("module.storage.subtitle"), enabled: $storage)

            Divider()
            // 版本行：与底部 GitHub 行同款居中逻辑，`·` 间隔
            HStack(spacing: 6) {
                Spacer()
                Text("v\(currentVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                updateView
                Spacer()
            }
            HStack(spacing: 4) {
                Spacer()
                Link("@Samuelonly", destination: URL(string: "https://github.com/Samuelonly")!)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                Link("github.com/Samuelonly/MiniBar",
                     destination: URL(string: "https://github.com/Samuelonly/MiniBar")!)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
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

}
