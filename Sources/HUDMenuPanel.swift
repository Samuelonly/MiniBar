import AppKit

/// 自绘 HUD 菜单（1.0.2 渲染器定稿）：
/// 模块仍以 NSMenu 树申报（menuSection() 零改动），本渲染器把树转成 HUD 面板。
/// 堆栈 = z 轴浮层：子卡片浮在下方行之上，父行与面板高度纹丝不动（PRD §11 二次定稿）。
/// 开关行（identifier "minibar.switch"）右侧真开关；"minibar.confirmEjectAll" 走二段行内确认。
/// NSMenu 仅作为数据模型存在，不再显示。
final class HUDMenuPanel: NSPanel {
    static let width: CGFloat = 320
    /// 行/hover/点击热区宽 = 面板宽 − 两侧安全区各 10pt（PRD §11 行内缩）
    static let rowWidth: CGFloat = width - 20

    private var expanded: ObjectIdentifier?
    private var monitors: [Any] = []
    weak var shell: MenuBarShell?

    private var rowsById: [ObjectIdentifier: NSView] = [:]
    private var switchMap: [ObjectIdentifier: (sw: NSSwitch, item: NSMenuItem)] = [:]
    private var overlayCard: NSView?
    private var overlayItem: NSMenuItem?
    private var overlayMonitor: Any?
    private var hintObserver: NSObjectProtocol?

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

        // 行容器：stack 负责常规行；浮层卡片加在 container 上（z 轴，不参与布局）
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        scroll.documentView = container

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

    private var rowContainer: NSView? { documentStack()?.superview }
    private func documentStack() -> NSStackView? {
        guard let content = contentView as? NSView,
              let scroll = content.subviews.compactMap({ $0 as? NSScrollView }).first,
              let container = scroll.documentView as? NSView else { return nil }
        return container.subviews.compactMap { $0 as? NSStackView }.first
    }

    // MARK: - 显示 / 收起

    func showUnderButton(_ buttonFrame: NSRect?) {
        expanded = nil
        rebuildContent()
        let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        contentView?.layoutSubtreeIfNeeded()
        var height = min((rowContainer?.fittingSize.height ?? 200) + 14, available.height - 40)
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
        expanded = nil
        hideOverlay()
    }

    // MARK: - 渲染：NSMenu 树 → 行（子树走浮层）

    private func rebuildContent() {
        guard let stack = documentStack(), let container = rowContainer else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hideOverlay()
        rowsById.removeAll()
        switchMap.removeAll()

        guard let menu = shell?.buildMenuModel() else { return }
        for item in menu.items {
            render(item: item, into: stack)
        }
        installHintObserver()
    }

    private func render(item: NSMenuItem, into stack: NSStackView) {
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
        if item.submenu != nil {
            let row = expanderRow(item)
            rowsById[ObjectIdentifier(item)] = row
            stack.addArrangedSubview(row)
            return
        }
        let row = actionRow(item)
        rowsById[ObjectIdentifier(item)] = row
        stack.addArrangedSubview(row)
    }

    // MARK: - 浮层卡片（z 轴堆栈：不推挤面板，浮在后续行之上）

    private func showOverlay(for item: NSMenuItem) {
        guard let submenu = item.submenu, let container = rowContainer,
              let anchorRow = rowsById[ObjectIdentifier(item)] else { return }
        hideOverlay()

        let card = NSView()
        card.wantsLayer = true
        // 比主面板深一档（不 100% 不透明），重叠处文字仍清晰
        card.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 0.88).cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        card.layer?.borderWidth = 1
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 12
        card.layer?.masksToBounds = false

        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 1
        cardStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        let cardWidth = HUDMenuPanel.rowWidth - 26
        for child in submenu.items where !child.isSeparatorItem {
            cardStack.addArrangedSubview(overlayRow(child, cardWidth: cardWidth - 8))
        }

        container.addSubview(card, positioned: .above, relativeTo: nil)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 30),
            card.widthAnchor.constraint(equalToConstant: cardWidth),
        ])
        overlayCard = card

        // 定位：锚行正下方，浮在后续行之上
        container.layoutSubtreeIfNeeded()
        let cardHeight = cardStack.fittingSize.height + 8
        let anchorFrame = anchorRow.convert(anchorRow.bounds, to: container)
        card.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true
        card.topAnchor.constraint(equalTo: container.topAnchor,
                                  constant: anchorFrame.maxY + 2).isActive = true

        // 点浮层外（面板内）自动收起
        overlayMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.overlayCard != nil else { return event }
            let inWindow = event.window === self ? event.locationInWindow : NSEvent.mouseLocation
            let inContainer = container.convert(inWindow, from: nil)
            let inCard = card.frame.contains(inContainer)
            let inAnchor = anchorRow.frame.contains(inContainer)
            if !inCard && !inAnchor { self.collapseOverlay() }
            return event
        }
    }

    private func collapseOverlay() {
        expanded = nil
        hideOverlay()
    }

    private func hideOverlay() {
        overlayCard?.removeFromSuperview()
        overlayCard = nil
        if let overlayMonitor {
            NSEvent.removeMonitor(overlayMonitor)
            self.overlayMonitor = nil
        }
    }

    /// 浮层行：图标 + 名称 + 标签 + 右侧开关（单选互斥在点击后同步）
    private func overlayRow(_ item: NSMenuItem, cardWidth: CGFloat) -> NSView {
        let row = HoverCardView(frame: NSRect(x: 0, y: 0, width: cardWidth, height: 24))

        let icon = NSImageView(image: item.image ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: item.title)
        title.font = NSFont.systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [icon, title])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)

        let sw = NSSwitch()
        sw.controlSize = .mini
        sw.state = item.state == .on ? .on : .off
        sw.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(sw)
        switchMap[ObjectIdentifier(sw)] = (sw, item)
        sw.target = self
        sw.action = #selector(switchFlipped(_:))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -6),
            sw.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sw.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
        ])
        return row
    }

    /// 浮层内开关：派发回模块（from: 菜单项），随后组内单选互斥 + 以模块回写状态为准
    @objc private func switchFlipped(_ sender: NSSwitch) {
        guard let entry = switchMap.first(where: { $0.value.sw === sender })?.value else { return }
        let item = entry.item
        if let target = item.target, let action = item.action {
            NSApp.sendAction(action, to: target, from: item)
        }
        // 单选互斥：同卡片内点亮的保持，其余熄灭
        for (_, other) in switchMap where other.sw !== sender && other.sw.superview === entry.sw.superview {
            if other.sw.state == .on { other.sw.state = .off }
        }
        // 旋转方向等模块会回写 item.state——以模块为准
        sender.state = item.state == .on ? .on : .off
    }

    // MARK: - 常规行

    private func expanderRow(_ item: NSMenuItem) -> NSView {
        let row = rowBase(item: item, chevron: "chevron.down")
        row.onClick = { [weak self] in
            guard let self else { return }
            let id = ObjectIdentifier(item)
            if expanded == id {
                collapseOverlay()
            } else {
                expanded = id
                showOverlay(for: item)
            }
        }
        return row
    }

    private func actionRow(_ item: NSMenuItem) -> NSView {
        if item.identifier?.rawValue == "minibar.confirmEjectAll" {
            return confirmRow(item)
        }
        let row = rowBase(item: item, chevron: nil)
        if item.action != nil {
            row.onClick = { [weak self] in
                if let target = item.target, let action = item.action {
                    NSApp.sendAction(action, to: target, from: item)
                }
                self?.dismiss()
            }
        }
        return row
    }

    /// 破坏性动作二段行内确认（PRD §3.6）：点击 → "确认弹出全部？" → 再点执行；2 秒未点自动还原
    private func confirmRow(_ item: NSMenuItem) -> NSView {
        let row = rowBase(item: item, chevron: nil)
        let label = row.subviews.compactMap { $0 as? NSTextField }.first
        var confirmTimer: Timer?
        row.onClick = { [weak row, weak self] in
            guard let row, let self else { return }
            if row.layer?.backgroundColor == NSColor(red: 1, green: 0.55, blue: 0.2, alpha: 0.15).cgColor {
                confirmTimer?.invalidate()
                row.layer?.backgroundColor = NSColor.clear.cgColor
                if let target = item.target, let action = item.action {
                    NSApp.sendAction(action, to: target, from: item)
                }
                self.dismiss()
            } else {
                confirmTimer?.invalidate()
                row.layer?.backgroundColor = NSColor(red: 1, green: 0.55, blue: 0.2, alpha: 0.15).cgColor
                label?.stringValue = L("menu.storage.ejectAllConfirm")
                label?.textColor = NSColor(red: 1, green: 0.71, blue: 0.33, alpha: 1)
                confirmTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                    row.layer?.backgroundColor = NSColor.clear.cgColor
                    label?.stringValue = L("menu.storage.ejectAll")
                    label?.textColor = .labelColor
                }
            }
        }
        return row
    }

    // MARK: - 行构造

    private func rowBase(item: NSMenuItem, chevron: String?) -> HoverCardView {
        let row = HoverCardView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.rowWidth, height: 26))
        row.wantsLayer = true

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
            stack.trailingAnchor.constraint(lessThanOrEqualTo: arrow.leadingAnchor, constant: -6).isActive = true
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
        } else {
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -10).isActive = true
        }
        return row
    }

    private func wrap(_ view: NSView) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.rowWidth, height: view.frame.height))
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.rowWidth, height: 22))
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func divider() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.rowWidth, height: 1))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return view
    }

    // MARK: - 行内提示（阻断警示等，模块经 ModuleEvent.rowHint 发来）

    private func installHintObserver() {
        guard hintObserver == nil else { return }
        hintObserver = NotificationCenter.default.addObserver(
            forName: ModuleEvent.rowHint, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isVisible,
                  let item = note.userInfo?["item"] as? NSMenuItem,
                  let text = note.userInfo?["text"] as? String else { return }
            let warn = (note.userInfo?["warn"] as? Bool) ?? false
            guard let row = self.rowsById[ObjectIdentifier(item)] else { return }
            row.subviews.filter { $0.identifier?.rawValue == "minibar.flash" }
                .forEach { $0.removeFromSuperview() }
            let flash = NSTextField(labelWithString: text)
            flash.identifier = NSUserInterfaceItemIdentifier("minibar.flash")
            flash.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            flash.textColor = warn ? NSColor(red: 1, green: 0.71, blue: 0.33, alpha: 1)
                                   : NSColor(red: 0.49, green: 0.89, blue: 0.66, alpha: 1)
            flash.wantsLayer = true
            flash.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
            flash.layer?.cornerRadius = 4
            flash.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(flash)
            NSLayoutConstraint.activate([
                flash.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                flash.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                flash.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            ])
            Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
                flash.removeFromSuperview()
            }
        }
    }

    // MARK: - 关闭监听

    private func installMonitors() {
        installHintObserver()
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
    }
}
