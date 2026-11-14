import AppKit

/// 自绘 HUD 菜单（1.0.2 菜单渲染层换血，PRD §11 渲染器定稿）：
/// 模块仍以 NSMenu 树申报（menuSection() 零改动），本渲染器把树转成
/// 向下堆栈展开的 HUD 面板——内联卡片 / hover 反馈 / 贴边约束全部自有。
/// NSMenu 仅作为数据模型存在，不再显示。
final class HUDMenuPanel: NSPanel {
    static let width: CGFloat = 320

    private var expandedIDs = Set<ObjectIdentifier>()
    private var monitors: [Any] = []
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
        title = "MiniBar"
        level = .floating
        isMovableByWindowBackground = false

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 8, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        let content = NSView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.width, height: 120))
        blur.frame = content.bounds
        blur.autoresizingMask = [.width, .height]
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(blur)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        contentView = content
    }

    // MARK: - 显示 / 收起

    func showUnderButton(_ buttonFrame: NSRect?) {
        rebuildContent()
        let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        contentView?.layoutSubtreeIfNeeded()
        var height = min((documentStack()?.fittingSize.height ?? 200) + 14, available.height - 40)
        height = max(height, 120)

        var frame = NSRect(x: 0, y: 0, width: HUDMenuPanel.width, height: height)
        if let buttonFrame {
            frame.origin.x = buttonFrame.midX - frame.width / 2
            frame.origin.y = buttonFrame.minY - 6 - height
        }
        // 贴边约束：左右不越界
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
        expandedIDs.removeAll()
    }

    /// 展开状态变化后重排：保持顶边位置，只改高度
    private func relayout() {
        contentView?.layoutSubtreeIfNeeded()
        let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var height = min((documentStack()?.fittingSize.height ?? 200) + 14, available.height - 40)
        height = max(height, 120)
        var frame = self.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        setFrame(frame, display: true)
    }

    private func documentStack() -> NSStackView? {
        (contentView as? NSView)?.subviews
            .compactMap { $0 as? NSScrollView }
            .first?.documentView as? NSStackView
    }

    // MARK: - 渲染：NSMenu 树 → 堆栈行

    private func rebuildContent() {
        guard let stack = documentStack() else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let menu = shell?.buildMenuModel() else { return }
        for item in menu.items {
            render(item: item, submenu: nil, into: stack)
        }
    }

    private func render(item: NSMenuItem, submenu: NSMenu?, into stack: NSStackView) {
        if item.isSeparatorItem {
            stack.addArrangedSubview(divider())
            return
        }
        if item.identifier?.rawValue == "minibar.sectionHeader" {
            stack.addArrangedSubview(headerRow(item.title))
            return
        }
        if let view = item.view {
            stack.addArrangedSubview(wrap(view))
            return
        }
        if let submenu {
            stack.addArrangedSubview(expandableRow(item, submenu: submenu))
            let isExpanded = expandedIDs.contains(ObjectIdentifier(item))
            if isExpanded {
                for child in submenu.items {
                    render(item: child, submenu: child.submenu, into: stack)
                }
            }
            return
        }
        stack.addArrangedSubview(actionRow(item))
    }

    private func expandableRow(_ item: NSMenuItem, submenu: NSMenu) -> NSView {
        let expanded = expandedIDs.contains(ObjectIdentifier(item))
        let row = rowBase(item: item, chevron: expanded ? "chevron.up" : "chevron.down")
        row.onClick = { [weak self] in
            guard let self else { return }
            let id = ObjectIdentifier(item)
            if expanded { self.expandedIDs.remove(id) } else { self.expandedIDs.insert(id) }
            self.rebuildContent()
            self.relayout()
        }
        return row
    }

    private func actionRow(_ item: NSMenuItem) -> NSView {
        let row = rowBase(item: item, chevron: nil)
        let hasAction = item.action != nil && (item.target != nil || item.isEnabled)
        if hasAction {
            row.onClick = { [weak self] in
                if let target = item.target, let action = item.action {
                    NSApp.sendAction(action, to: target, from: item)
                }
                self?.dismiss()
            }
        }
        return row
    }

    // MARK: - 行构造

    private func rowBase(item: NSMenuItem, chevron: String?) -> HoverCardView {
        let row = HoverCardView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.width - 12, height: 26))

        let icon = NSImageView(image: item.image ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let iconWidth: CGFloat = item.image == nil ? 0 : 18
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title)
        title.font = NSFont.systemFont(ofSize: 13)
        title.textColor = item.isEnabled ? .labelColor : .tertiaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, title])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconWidth),
        ])

        if item.state == .on {
            let check = NSTextField(labelWithString: "✓")
            check.font = NSFont.systemFont(ofSize: 12)
            check.textColor = .secondaryLabelColor
            check.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(check)
            NSLayoutConstraint.activate([
                check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            stack.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -6).isActive = true
            check.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10).isActive = true
        } else if !item.keyEquivalent.isEmpty {
            let key = NSTextField(labelWithString: "⌘\(item.keyEquivalent.uppercased())")
            key.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            key.textColor = .tertiaryLabelColor
            key.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(key)
            NSLayoutConstraint.activate([
                key.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                key.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            ])
        }

        if let chevron {
            let arrow = NSImageView(image: NSImage(systemSymbolName: chevron,
                                                   accessibilityDescription: nil)!)
            arrow.contentTintColor = .tertiaryLabelColor
            arrow.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(arrow)
            NSLayoutConstraint.activate([
                arrow.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                arrow.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                arrow.widthAnchor.constraint(equalToConstant: 12),
            ])
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.trailingAnchor.constraint(lessThanOrEqualTo: arrow.leadingAnchor, constant: -6).isActive = true
        } else {
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -10).isActive = true
        }
        return row
    }

    private func wrap(_ view: NSView) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.width - 12, height: view.frame.height))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func headerRow(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let container = NSView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.width - 12, height: 22))
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func divider() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.width - 12, height: 1))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return view
    }

    // MARK: - 关闭监听

    private func installMonitors() {
        let clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let location = NSEvent.mouseLocation
            // 点在菜单栏图标上：交给 toggle 逻辑，不重复关闭
            if let buttonFrame = shell?.statusButtonFrame(), buttonFrame.contains(location) { return }
            if !self.frame.contains(location) { self.dismiss() }
        }
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == 53 else { return event } // Esc
            self.dismiss()
            return nil
        }
        monitors = [clickMonitor, keyMonitor as Any]
    }
}
