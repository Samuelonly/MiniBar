import AppKit
import SwiftUI

/// PRD §10 HUD 设置面板（C 档定稿视觉）：
/// NSPanel 不抢前台焦点 + 大圆角大阴影 + 等宽大写节标题。
/// 皮肤与主面板一致（PanelAppearance）：未手动跟随系统，手动后记住选择。
/// 纯 SwiftUI 勾选列表，勾选即实时生效（PRD §5），零 WebView。
final class SettingsPanel: NSPanel {
    static let width: CGFloat = 380
    private var skinObserver: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var keyMonitor: Any?
    /// 开窗时刻：用于吞掉「点设置菜单」同一次点击，避免刚弹出就被外部点击判定关掉
    private var shownAt = Date.distantPast

    init() {
        // 窗口尺寸 = 内容实测尺寸。宽度固定 380，高度取换行后的自然高度，
        // 以后加功能窗口自己长，不写死。
        let probe = NSHostingView(rootView: SettingsContent(onClose: {}))
        probe.translatesAutoresizingMaskIntoConstraints = false
        probe.widthAnchor.constraint(equalToConstant: SettingsPanel.width).isActive = true
        probe.layoutSubtreeIfNeeded()
        let raw = probe.fittingSize.height
        let contentH = (raw.isFinite && raw > 80) ? ceil(raw) : 420

        super.init(contentRect: NSRect(x: 0, y: 0,
                                        width: SettingsPanel.width,
                                        height: contentH),
                   // borderless：无 title bar 安全区；关闭走自绘 ✕
                   styleMask: [.borderless],
                   backing: .buffered, defer: false)

        // 窗口透明，背景/圆角由 AppKit 容器图层画
        isOpaque = false
        backgroundColor = .clear
        // 皮肤与主面板同一套规则（PanelAppearance）：未手动跟随系统，手动后记住选择
        appearance = PanelAppearance.current.nsAppearance
        hasShadow = true
        // 必须用 statusBar 层级：MiniBar 是 LSUIElement 后台 app，从不 active，
        // .floating 层级的面板会被系统排到前台 App 窗口之下（只能透过对方的
        // 半透明区域看到我们，视觉上就像被蒙了一层纱）。statusBar 层级不受
        // app 激活状态影响，永远在最前。
        level = .statusBar
        // NSPanel 默认 hidesOnDeactivate = true：MiniBar 是后台 app（LSUIElement）
        // 从不 active，窗口一显示就被系统自动隐藏（NSWindow.isVisible 仍是 true，
        // 但系统根本不合成它）。必须关掉。
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 背景用 AppKit 图层画，不依赖 SwiftUI 的 .background：
        // 实测在 borderless NSPanel 里 SwiftUI 的背景只画出底部一小块，
        // 其余区域 alpha=0（背后编辑器文字直接透出，用户看到的就是「透明度接近 0」）。
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: SettingsPanel.width, height: contentH))
        container.wantsLayer = true
        container.layer?.backgroundColor = PanelAppearance.current.backgroundNS.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = PanelAppearance.current.borderNS.cgColor

        let host = FirstMouseHostingView(rootView: SettingsContent(onClose: { [weak self] in self?.close() }))
        // 必须关掉 sizingOptions：默认行为会让 hosting view 用 intrinsic 尺寸反向改窗口，
        // 与固定的 contentRect 冲突后内容被压成 0（窗口 visible 却什么都不画）
        host.sizingOptions = []
        // NSHostingView 不继承窗口的 appearance，必须单独指定，与皮肤一致
        host.appearance = PanelAppearance.current.nsAppearance
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
        center()
        // 拖空白处即可移动（borderless 窗口默认不可拖）
        isMovableByWindowBackground = true

        // 手动换肤 → 立即重绘；系统深浅色变化 → 未手动时跟随（applySkin 内部判断）
        skinObserver = NotificationCenter.default.addObserver(
            forName: PanelAppearance.changed, object: nil, queue: .main
        ) { [weak self] _ in self?.applySkin() }
        NSApp.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)
        installDismissMonitors()
    }

    // MARK: - 点外部 / Esc 关闭（与主面板同一套交互）

    private func installDismissMonitors() {
        // 全局：其它 App 里的点击
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.isVisible, !HotkeyRecorder.isActive,
                  Date().timeIntervalSince(self.shownAt) > 0.2 else { return }
            if !self.frame.contains(NSEvent.mouseLocation) { self.close() }
        }
        // 本地：本 App 内（主面板）的点击
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, self.isVisible, !HotkeyRecorder.isActive,
                  Date().timeIntervalSince(self.shownAt) > 0.2 else { return event }
            if !self.frame.contains(NSEvent.mouseLocation) { self.close() }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, !HotkeyRecorder.isActive,
                  event.keyCode == 53 else { return event }
            self.close()
            return nil
        }
    }

    /// 应用当前有效皮肤：窗口/托管 appearance + 容器底色描边 + 重建内容（colorScheme 随之更新）
    private func applySkin() {
        let skin = PanelAppearance.current
        appearance = skin.nsAppearance
        contentView?.layer?.backgroundColor = skin.backgroundNS.cgColor
        contentView?.layer?.borderColor = skin.borderNS.cgColor
        if let host = contentView?.subviews.first as? NSHostingView<SettingsContent> {
            host.appearance = skin.nsAppearance
            host.rootView = SettingsContent(onClose: { [weak self] in self?.close() })
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" { applySkin() }
    }

    deinit {
        NSApp.removeObserver(self, forKeyPath: "effectiveAppearance")
        if let skinObserver { NotificationCenter.default.removeObserver(skinObserver) }
        for monitor in [globalClickMonitor, localClickMonitor, keyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    /// nonactivatingPanel 不会 becomeKey，系统红 X 不派发 action
    /// 这里 override close 让 SwiftUI 自定义按钮能正确关窗
    override func close() {
        orderOut(nil)
    }

    /// nonactivating：弹出不抢前台 App 焦点（PRD §10 遥控器哲学的物理体现）
    func show() {
        shownAt = Date()
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

// MARK: - 快捷键行（调节与场景共用）

private struct HotkeyRow: View {
    let title: String
    let binding: HotkeyBinding?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: action) {
                Text(binding?.display ?? L("settings.scene.unset"))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - 快捷键录制

/// 设置面板是 borderless 非 key 窗口，收不到键盘事件；录制用一个临时可成为 key 的小窗口 + 模态循环
final class HotkeyRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum HotkeyRecorder {
    enum Outcome { case set(HotkeyBinding), clear, cancel }

    /// 录制期间设置面板的「点外部 / Esc 关闭」要先让路
    private(set) static var isActive = false
    private static var controller: RecorderController?

    static func present(actionName: String, current: HotkeyBinding?,
                        hostFrame: NSRect?,
                        completion: @escaping (Outcome) -> Void) {
        let controller = RecorderController(actionName: actionName, current: current,
                                            hostFrame: hostFrame)
        self.controller = controller
        isActive = true
        controller.begin { [weak self] outcome in
            self?.isActive = false
            self?.controller = nil
            completion(outcome)
        }
    }
}

private final class RecorderController: NSObject {
    private let panel: HotkeyRecorderPanel
    private let hostFrame: NSRect?
    private var monitor: Any?
    private var finished = false
    private var outcome: HotkeyRecorder.Outcome?

    init(actionName: String, current: HotkeyBinding?, hostFrame: NSRect?) {
        self.hostFrame = hostFrame
        panel = HotkeyRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 132),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = String(format: L("settings.scene.record"), actionName)
        panel.isReleasedWhenClosed = false
        // 设置面板在 statusBar 层级，录制窗必须同层才能浮在它上面
        panel.level = .statusBar
        panel.hidesOnDeactivate = false

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 340, height: 132))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        stack.autoresizingMask = [.width, .height]

        let hint = NSTextField(wrappingLabelWithString:
            String(format: L("settings.scene.recording"),
                   current?.display ?? L("settings.scene.unset")))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let clear = NSButton(title: L("settings.scene.clear"), target: self,
                             action: #selector(clearTapped))
        let cancel = NSButton(title: L("common.cancel"), target: self,
                              action: #selector(cancelTapped))
        clear.bezelStyle = .rounded
        cancel.bezelStyle = .rounded
        buttons.addArrangedSubview(clear)
        buttons.addArrangedSubview(cancel)
        stack.addArrangedSubview(buttons)

        panel.contentView = stack
    }

    /// 异步 non-modal：不用 runModal（它会阻塞主线程，在 SwiftUI Button 回调里调用等于死锁）
    func begin(completion: @escaping (HotkeyRecorder.Outcome) -> Void) {
        self.completion = completion
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        // 相对于 SettingsPanel 居中（不是屏幕中心）
        if let hostFrame {
            let x = hostFrame.midX - panel.frame.width / 2
            let y = hostFrame.midY - panel.frame.height / 2
            panel.setFrameOrigin(NSPoint(x: max(20, x), y: max(20, y)))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        // 录制期间让出全局热键，否则按下已注册的组合会被热键直接吞掉
        SceneStore.shared.suspendHotkeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        // 点面板外部也视为取消
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, !self.finished else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) {
                self.finish(.cancel)
            }
        }
    }

    private var completion: ((HotkeyRecorder.Outcome) -> Void)?
    private var clickMonitor: Any?

    /// 只接受「修饰键 + 一个普通键」；纯修饰键不会产生 keyDown
    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { finish(.cancel); return true }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.isEmpty else { NSSound.beep(); return true }
        finish(.set(HotkeyBinding(keyCode: event.keyCode, modifiers: flags.rawValue)))
        return true
    }

    private func finish(_ result: HotkeyRecorder.Outcome) {
        guard !finished else { return }
        finished = true
        outcome = result
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        SceneStore.shared.resumeHotkeys()
        panel.orderOut(nil)
        panel.close()
        completion?(result)
        completion = nil
    }

    @objc private func clearTapped() { finish(.clear) }
    @objc private func cancelTapped() { finish(.cancel) }
}

// MARK: - 面板内容

struct SettingsContent: View {
    let onClose: () -> Void

    @AppStorage("module.display") private var display = true
    @AppStorage("module.state") private var state = true
    @AppStorage("module.power") private var power = true
    @AppStorage("module.audio") private var audio = true
    @AppStorage("module.storage") private var storage = true

    /// PRD §10：仅 0.15s 级微淡入
    @State private var appeared = false
    /// 场景增删改 / 改键后刷新列表
    @State private var revision = 0

    private var store: SceneStore { SceneStore.shared }

    /// 打开录制窗口；冲突/占用时提示并回滚。调节与场景共用同一套交互。
    private func record(_ scene: Scene) {
        record(name: scene.displayName, current: store.binding(for: scene)) {
            store.setBinding($0, for: scene.id)
        }
    }

    private func record(_ adjustment: DisplayAdjustment) {
        record(name: adjustment.displayName, current: store.binding(for: adjustment)) {
            store.setBinding($0, for: adjustment)
        }
    }

    private func record(name: String, current: HotkeyBinding?,
                        update: @escaping (HotkeyBinding?) -> SceneStore.BindingResult) {
        let hostFrame = NSApp.windows.first(where: { $0 is SettingsPanel })?.frame
        HotkeyRecorder.present(actionName: name, current: current,
                               hostFrame: hostFrame) { outcome in
            switch outcome {
            case .cancel:
                break
            case .clear:
                _ = update(nil)
            case .set(let binding):
                switch update(binding) {
                case .ok: break
                case .duplicate, .unavailable:
                    SceneDialogs.info(L("settings.scene.conflict"))
                }
            }
            revision &+= 1
        }
    }

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
            // 标题行：borderless 面板无系统红 X，关闭走「点外部 / Esc」
            HStack(alignment: .top) {
                Text(L("settings.title"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 2)
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

            Text(L("settings.section.hotkeys"))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(.tertiary)

            Text(L("settings.section.adjustments"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                let _ = revision
                ForEach(DisplayAdjustment.allCases, id: \.self) { adjustment in
                    HotkeyRow(title: adjustment.displayName,
                              binding: store.binding(for: adjustment)) { record(adjustment) }
                }
            }

            Text(L("settings.section.scenes"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(spacing: 4) {
                ForEach(store.scenes) { scene in
                    HotkeyRow(title: scene.displayName,
                              binding: store.binding(for: scene)) { record(scene) }
                }
            }

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
                    .foregroundStyle(.link)
                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                Link("github.com/Samuelonly/MiniBar",
                     destination: URL(string: "https://github.com/Samuelonly/MiniBar")!)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.link)
                Spacer()
            }
        }
        // HTML：.panel{padding:10px} + .mod-row/.p-note{padding:6px} = 16
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 20)
        // 宽度固定 380，高度由内容决定（窗口尺寸 = 这里的尺寸）
        .frame(width: SettingsPanel.width, alignment: .leading)
        // 背景与圆角：颜色随皮肤（容器图层也画了一遍底色，双保险不透明）
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(PanelAppearance.current.background)
        )
        // 文字、次级文字、分隔线、开关全部由 colorScheme 驱动，两套皮肤真切换
        .environment(\.colorScheme, PanelAppearance.current.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: SceneStore.changed)) { _ in
            revision &+= 1
        }
        // 不做淡入动画：NSHostingView 在 borderless 窗口里 onAppear 时机不稳定
    }
}
