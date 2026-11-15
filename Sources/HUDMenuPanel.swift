import AppKit
import SwiftUI

/// 自绘 HUD 菜单（1.0.2 渲染器 v3，层级定稿）：
/// 层级关系 = Section > Block > 行。
///   Section：6 个分区（节标题 + 分界线），永远完整呈现；
///   Block：Section 内的可展开块（画质模式/扬声器/麦克风），展开 = 就地插入子行，手风琴单开；
///   行：开关行 / 动作行 / 滑杆行。
/// 模块仍以 NSMenu 树申报（menuSection() 零改动），SwiftUI 声明式渲染。
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

    // MARK: - 监听（面板外点击 / Esc / 行内提示桥接）

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

        // 模块行内提示（阻断警示等）：桥接进 SwiftUI 状态，1.4s 自动清除
        hintObserver = NotificationCenter.default.addObserver(
            forName: ModuleEvent.rowHint, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isVisible,
                  let item = note.userInfo?["item"] as? NSMenuItem,
                  let text = note.userInfo?["text"] as? String else { return }
            let warn = (note.userInfo?["warn"] as? Bool) ?? false
            guard let host = (contentView as? NSView)?.subviews
                .compactMap({ $0 as? NSHostingView<HUDMenuContent> }).first else { return }
            var root = host.rootView
            root.hintItem = ObjectIdentifier(item)
            root.hintText = text
            root.hintWarn = warn
            host.rootView = root
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                var cleared = host.rootView
                guard cleared.hintItem == ObjectIdentifier(item) else { return }
                cleared.hintItem = nil
                cleared.hintText = ""
                host.rootView = cleared
            }
        }
    }
}

// MARK: - SwiftUI 内容（Section > Block > 行）

private struct HUDMenuContent: View {
    let menu: NSMenu
    var onDismiss: (() -> Void)?

    @State private var expandedBlockID: ObjectIdentifier?
    @State private var appeared = false
    var hintItem: ObjectIdentifier?
    var hintText: String = ""
    var hintWarn = false

    // MARK: 层级解析：Section > Block > 行

    private struct Block {
        let item: NSMenuItem
        let children: [NSMenuItem]
    }

    private struct SectionData {
        var title: String?
        var rows: [NSMenuItem] = []
        var blocks: [Block] = []
        var isEmpty: Bool { title == nil && rows.isEmpty && blocks.isEmpty }
    }

    private var sections: [(section: SectionData, isFooter: Bool)] {
        var result: [(SectionData, Bool)] = []
        var current = SectionData()
        var isFooter = false
        for item in menu.items {
            if item.identifier?.rawValue == "minibar.sectionHeader" {
                if !current.isEmpty { result.append((current, isFooter)) }
                current = SectionData()
                current.title = item.title
                isFooter = false
            } else if item.isSeparatorItem {
                if !current.isEmpty { result.append((current, isFooter)) }
                current = SectionData()
                isFooter = true // 分界线之后是设置/退出锚点区
            } else if item.submenu != nil {
                let children = (item.submenu?.items.filter { !$0.isSeparatorItem }) ?? []
                current.blocks.append(Block(item: item, children: children))
            } else {
                current.rows.append(item)
            }
        }
        if !current.isEmpty { result.append((current, isFooter)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, pair in
                if let title = pair.section.title {
                    sectionHeader(title)
                }
                ForEach(Array(pair.section.rows.enumerated()), id: \.offset) { _, item in
                    row(item)
                }
                ForEach(Array(pair.section.blocks.enumerated()), id: \.offset) { _, block in
                    blockHeader(block.item)
                    if expandedBlockID == ObjectIdentifier(block.item) {
                        ForEach(Array(block.children.enumerated()), id: \.offset) { _, child in
                            childRow(child, siblings: block.children)
                        }
                    }
                }
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
            expandedBlockID = nil   // 点面板内其他区域：Block 收起
        })
        .animation(.easeOut(duration: 0.2), value: expandedBlockID)
    }

    // MARK: - 行分发

    @ViewBuilder private func row(_ item: NSMenuItem) -> some View {
        if item.isSeparatorItem {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        } else if item.view != nil {
            AppKitRow(view: item.view!)
        } else if item.identifier?.rawValue == "minibar.confirmEjectAll" {
            ConfirmEjectAllRow(item: item) { onDismiss?() }
        } else if item.identifier?.rawValue == "minibar.switch" {
            MenuSwitchRow(item: item,
                          hint: hintItem == ObjectIdentifier(item) ? hintText : nil,
                          hintWarn: hintWarn,
                          onFlip: { _ in send(item) })
        } else {
            ActionRow(item: item,
                      hasHint: hintItem == ObjectIdentifier(item),
                      hintText: hintItem == ObjectIdentifier(item) ? hintText : "",
                      hintWarn: hintWarn,
                      onAction: {
                          send(item)
                          onDismiss?()
                      })
        }
    }

    private func send(_ item: NSMenuItem) {
        if let target = item.target, let action = item.action {
            NSApp.sendAction(action, to: target, from: item)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Block 头：名称 + 向下箭头，点击就地展开/收起子行
    @ViewBuilder private func blockHeader(_ item: NSMenuItem) -> some View {
        let expanded = expandedBlockID == ObjectIdentifier(item)
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
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
        ) { expandedBlockID = expanded ? nil : ObjectIdentifier(item) }
    }

    /// Block 子行：右侧开关，单选互斥（输出设备/旋转/画质模式天然只有一个）
    @ViewBuilder private func childRow(_ child: NSMenuItem, siblings: [NSMenuItem]) -> some View {
        MenuSwitchRow(item: child,
                      hint: nil, hintWarn: false,
                      onFlip: { flipped in
                          send(child)
                          if flipped {
                              for sibling in siblings where sibling !== child {
                                  sibling.state = .off
                              }
                          }
                      })
    }
}

// MARK: - 行组件

/// 悬停阻尼 + 点击
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
    var hint: String?
    var hintWarn = false
    var onFlip: (Bool) -> Void

    @State private var isOn: Bool

    init(item: NSMenuItem, hint: String?, hintWarn: Bool, onFlip: @escaping (Bool) -> Void) {
        self.item = item
        self.hint = hint
        self.hintWarn = hintWarn
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
                if let hint {
                    Text(hint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(hintWarn ? Color(red: 1, green: 0.71, blue: 0.33)
                                                  : Color(red: 0.49, green: 0.89, blue: 0.66))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(4)
                        .transition(.opacity)
                }
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: isOn) { _, newValue in onFlip(newValue) }
            }
        )
        .animation(.easeOut(duration: 0.2), value: hint != nil)
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
