import AppKit
import SwiftUI

/// 自绘 HUD 菜单（1.0.2 渲染器 v2：SwiftUI 渲染）：
/// 模块仍以 NSMenu 树申报（menuSection() 零改动），NSHostingView 把树转成声明式布局——
/// 浮层堆栈 / 开关行 / 阻尼 hover / 数值角标全部确定性，不再手排坐标。
/// NSMenu 仅作为数据模型存在，不再显示。
final class HUDMenuPanel: NSPanel {
    static let width: CGFloat = 320

    private var monitors: [Any] = []
    private var hintObserver: NSObjectProtocol?
    weak var shell: MenuBarShell?

    init(shell: MenuBarShell) {
        self.shell = shell
        super.init(contentRect: NSRect(x: 0, y: 0, width: HUDMenuPanel.width, height: 120),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "MiniBar"
        level = .floating
        isMovableByWindowBackground = false
    }

    /// 面板内容：毛玻璃层（AppKit）+ SwiftUI 内容层
    private func installContent(menu: NSMenu) {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.frame = NSRect(x: 0, y: 0, width: HUDMenuPanel.width, height: 120)
        blur.autoresizingMask = [.width, .height]

        var content = HUDMenuContent(menu: menu)
        content.onDismiss = { [weak self] in self?.dismiss() }
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: HUDMenuPanel.width, height: 120)
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = [.minSize, .maxSize, .intrinsicContentSize]

        let container = NSView(frame: blur.frame)
        container.addSubview(blur)
        container.addSubview(host)
        contentView = container
    }

    // MARK: - 显示 / 收起

    func showUnderButton(_ buttonFrame: NSRect?) {
        guard let menu = shell?.buildMenuModel() else { return }
        installContent(menu: menu)

        let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        contentView?.layoutSubtreeIfNeeded()
        var height = min((contentView?.fittingSize.height ?? 200) + 2, available.height - 40)
        height = max(height, 120)

        var frame = NSRect(x: 0, y: 0, width: HUDMenuPanel.width, height: height)
        if let buttonFrame {
            frame.origin.x = buttonFrame.midX - frame.width / 2
            frame.origin.y = buttonFrame.minY - 6 - height
        }
        frame.origin.x = max(available.minX + 8, min(frame.origin.x, available.maxX - frame.width - 8))
        if frame.origin.y < available.minY + 8 { frame.origin.y = available.minY + 8 }
        setFrame(frame, display: false)
        orderFrontRegardless()
        installMonitors()
    }

    func dismiss() {
        orderOut(nil)
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let hintObserver {
            NotificationCenter.default.removeObserver(hintObserver)
            self.hintObserver = nil
        }
    }

    // MARK: - 关闭监听（面板外点击 / Esc）

    private func installMonitors() {
        let clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let location = NSEvent.mouseLocation
            if let buttonFrame = shell?.statusButtonFrame(), buttonFrame.contains(location) { return }
            if !self.frame.contains(location) { self.dismiss() }
        }
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == 53 else { return event } // Esc
            self.dismiss()
            return nil
        }
        monitors = [clickMonitor, keyMonitor as Any]

        // 模块行内提示（阻断警示等）：桥接进 SwiftUI 状态
        hintObserver = NotificationCenter.default.addObserver(
            forName: ModuleEvent.rowHint, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isVisible,
                  let item = note.userInfo?["item"] as? NSMenuItem,
                  let text = note.userInfo?["text"] as? String else { return }
            let warn = (note.userInfo?["warn"] as? Bool) ?? false
            guard let host = (contentView as? NSView)?.subviews.compactMap({ $0 as? NSHostingView<HUDMenuContent> }).first else { return }
            var root = host.rootView
            root.hintItem = ObjectIdentifier(item)
            root.hintText = text
            root.hintWarn = warn
            host.rootView = root
        }
    }
}

// MARK: - SwiftUI 内容

private struct HUDMenuContent: View {
    let menu: NSMenu
    var onDismiss: (() -> Void)?

    @State private var expandedID: ObjectIdentifier?
    @State private var appeared = false
    // 行内提示（阻断警示），按 item 定位
    var hintItem: ObjectIdentifier?
    var hintText: String = ""
    var hintWarn = false

    private let itemSpacing: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: itemSpacing) {
                ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
                    row(item)
                }
            }
            // 浮层卡片：z 轴堆栈，锚在展开行下方，不推挤面板
            if let expander = expandedItem {
                overlayCard(expander)
                    .offset(y: offsetForOverlay(expander))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: HUDMenuPanel.width, alignment: .topLeading)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) { appeared = true }
        }
        .background(Color.clear.onTapGesture {
            expandedID = nil   // 点面板内其他区域：浮层收起
        })
    }

    private var expandedItem: NSMenuItem? {
        menu.items.first { ObjectIdentifier($0) == expandedID }
    }

    /// 浮层 y 偏移 = 展开行上方所有行的累计高度（行高全部固定，可精确计算）
    private func offsetForOverlay(_ expander: NSMenuItem) -> CGFloat {
        var offset: CGFloat = 6
        for item in menu.items {
            if ObjectIdentifier(item) == expandedID { break }
            offset += rowHeight(item) + itemSpacing
        }
        return offset + rowHeight(expander) + 2
    }

    private func rowHeight(_ item: NSMenuItem) -> CGFloat {
        if item.isSeparatorItem { return 1 }
        if item.identifier?.rawValue == "minibar.sectionHeader" { return 22 }
        if item.view != nil { return 30 }
        return 26
    }

    // MARK: - 行分发

    @ViewBuilder private func row(_ item: NSMenuItem) -> some View {
        if item.isSeparatorItem {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        } else if item.identifier?.rawValue == "minibar.sectionHeader" {
            Text(item.title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let view = item.view {
            AppKitRow(view: view)
        } else if item.submenu != nil {
            ExpanderRow(item: item,
                        isExpanded: ObjectIdentifier(item) == expandedID,
                        hasHint: hintItem == ObjectIdentifier(item),
                        onToggle: {
                            expandedID = (expandedID == ObjectIdentifier(item)) ? nil : ObjectIdentifier(item)
                        })
        } else if item.identifier?.rawValue == "minibar.confirmEjectAll" {
            ConfirmEjectAllRow(item: item) { dismissPanel() }
        } else if item.identifier?.rawValue == "minibar.switch" {
            MenuSwitchRow(item: item, showsCheck: false,
                          onFlip: { flipped in send(item, flipped) })
        } else {
            ActionRow(item: item,
                      hasHint: hintItem == ObjectIdentifier(item),
                      hintText: hintItem == ObjectIdentifier(item) ? hintText : "",
                      hintWarn: hintWarn,
                      onAction: {
                          send(item, true)
                          dismissPanel()
                      })
        }
    }

    private func send(_ item: NSMenuItem, _ flipped: Bool) {
        if let target = item.target, let action = item.action {
            NSApp.sendAction(action, to: target, from: item)
        }
    }

    private func dismissPanel() {
        onDismiss?()
    }

    // MARK: - 浮层卡片

    @ViewBuilder private func overlayCard(_ expander: NSMenuItem) -> some View {
        if let submenu = expander.submenu {
            VStack(alignment: .leading, spacing: itemSpacing) {
                ForEach(Array(submenu.items.enumerated()), id: \.offset) { _, child in
                    if !child.isSeparatorItem {
                        MenuSwitchRow(item: child, showsCheck: false,
                                      onFlip: { flipped in send(child, flipped) })
                    }
                }
            }
            .padding(4)
            .frame(width: HUDMenuPanel.width - 56, alignment: .leading)
            .background(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.88))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.09)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.5), radius: 12)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }
}

// MARK: - 行组件

/// 悬停阻尼 + 点击行
private struct Hoverable<Content: View>: View {
    let content: Content
    var onClick: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background(hovering ? Color.white.opacity(0.08) : Color.clear)
            .shadow(color: .black.opacity(hovering ? 0.3 : 0), radius: hovering ? 5 : 0)
            .animation(.easeOut(duration: 0.22), value: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { onClick?() }
    }
}

/// 开关行（菜单行真开关，PRD §3.6）
private struct MenuSwitchRow: View {
    let item: NSMenuItem
    var showsCheck = true
    var onFlip: (Bool) -> Void

    @State private var isOn: Bool

    init(item: NSMenuItem, showsCheck: Bool, onFlip: @escaping (Bool) -> Void) {
        self.item = item
        self.showsCheck = showsCheck
        self.onFlip = onFlip
        _isOn = State(initialValue: item.state == .on)
    }

    var body: some View {
        Hoverable(content:
            HStack(spacing: 8) {
                if let image = item.image {
                    Image(nsImage: image).resizable().frame(width: 15, height: 15)
                        .foregroundStyle(.secondary)
                }
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: isOn) { _, newValue in onFlip(newValue) }
            }
        )
    }
}

/// 普通动作行
private struct ActionRow: View {
    let item: NSMenuItem
    var hasHint: Bool
    var hintText: String
    var hintWarn: Bool
    var onAction: () -> Void

    @State private var hovering = false

    var body: some View {
        Hoverable(content:
            HStack(spacing: 8) {
                if let image = item.image {
                    Image(nsImage: image).resizable().frame(width: 15, height: 15)
                        .foregroundStyle(.secondary)
                }
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                if hasHint {
                    Text(hintText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(hintWarn ? Color(red: 1, green: 0.71, blue: 0.33)
                                                  : Color(red: 0.49, green: 0.89, blue: 0.66))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(4)
                        .transition(.opacity)
                } else if !item.keyEquivalent.isEmpty {
                    Text("⌘\(item.keyEquivalent.uppercased())")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        ) { onAction() }
        .animation(.easeOut(duration: 0.2), value: hasHint)
    }

    init(item: NSMenuItem, hasHint: Bool, hintText: String, hintWarn: Bool,
         onAction: @escaping () -> Void) {
        self.item = item
        self.hasHint = hasHint
        self.hintText = hintText
        self.hintWarn = hintWarn
        self.onAction = onAction
    }
}

/// 展开行（向下箭头）
private struct ExpanderRow: View {
    let item: NSMenuItem
    let isExpanded: Bool
    var hasHint = false
    var onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Hoverable(content:
            HStack(spacing: 8) {
                if let image = item.image {
                    Image(nsImage: image).resizable().frame(width: 15, height: 15)
                        .foregroundStyle(.secondary)
                }
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(.easeOut(duration: 0.22), value: isExpanded)
            }
        ) { onToggle() }
    }
}

/// 破坏性动作二段确认行（PRD §3.6）
private struct ConfirmEjectAllRow: View {
    let item: NSMenuItem
    var onConfirmed: () -> Void

    @State private var confirming = false
    @State private var timer: Timer?

    var body: some View {
        Hoverable(content:
            HStack(spacing: 8) {
                if let image = item.image {
                    Image(nsImage: image).resizable().frame(width: 15, height: 15)
                        .foregroundStyle(.secondary)
                }
                Text(confirming ? NSLocalizedString("menu.storage.ejectAllConfirm", comment: "")
                                : item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(confirming ? Color(red: 1, green: 0.71, blue: 0.33) : .primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .background(confirming ? Color(red: 1, green: 0.55, blue: 0.2).opacity(0.15) : Color.clear)
        ) {
            if confirming {
                timer?.invalidate()
                confirming = false
                onConfirmed()
            } else {
                confirming = true
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                    confirming = false
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: confirming)
    }
}

/// 嵌入模块申报的 AppKit 视图（滑杆行：滚轮+角标）
private struct AppKitRow: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
