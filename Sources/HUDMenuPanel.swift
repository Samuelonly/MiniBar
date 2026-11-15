import AppKit

/// 自绘 HUD 菜单（1.0.2 渲染器定稿）：
/// 模块仍以 NSMenu 树申报（menuSection() 零改动），本渲染器把树转成 HUD 面板。
/// 堆栈 = z 轴浮层：子卡片浮在下方行之上，父行与面板高度纹丝不动（PRD §11 二次定稿）。
/// 行布局采用手动排布（行高全部固定值，确定性最高）——不与 NSStackView 混用。
/// NSMenu 仅作为数据模型存在，不再显示。
final class HUDMenuPanel: NSPanel {
    static let width: CGFloat = 320
    /// 行/hover/点击热区宽 = 面板宽 − 两侧安全区各 10pt（PRD §11 行内缩）
    static let rowWidth: CGFloat = width - 20

    private var expanded: ObjectIdentifier?
    private var monitors: [Any] = []
    weak var shell: MenuBarShell?

    private var contentRows: [NSView] = []
    private var rowsById: [ObjectIdentifier: NSView] = [:]
    private var expanderArrows: [ObjectIdentifier: NSImageView] = [:]
    private var switchMap: [ObjectIdentifier: (sw: NSSwitch, item: NSMenuItem)] = [:]
    private var overlayCard: NSView?
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
        titleVisibility = .hidden
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
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = FlippedView()
        scroll.documentView = container

        let content = NSView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.width, height: 120))
        blur.frame = content.bounds
        blur.autoresizingMask = [.width, .height]
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

    /// 翻转坐标：y 从顶部起算，行排布直觉化
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private var rowContainer: FlippedView? {
        (contentView as? NSView)?.subviews.compactMap { $0 as? NSScrollView }
            .first?.documentView as? FlippedView
    }

    // MARK: - 显示 / 收起

    func showUnderButton(_ buttonFrame: NSRect?) {
        expanded = nil
        rebuildContent()
        let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var height = min((rowContainer?.frame.height ?? 200) + 14, available.height - 40)
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

    // MARK: - 渲染：NSMenu 树 → 行（子树走浮层，不参与行排布）

    private func rebuildContent() {
        guard let container = rowContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        rowsById.removeAll()
        expanderArrows.removeAll()
        switchMap.removeAll()
        contentRows.removeAll()
        hideOverlay()

        guard let menu = shell?.buildMenuModel() else { return }
        for item in menu.items {
            render(item: item, into: container)
        }
        layoutRows(in: container)
        installHintObserver()
    }

    /// 手动排布：行高全部固定值，从顶部逐行往下放
    private func layoutRows(in container: NSView) {
        var y: CGFloat = 6
        for row in contentRows {
            row.frame = NSRect(x: 10, y: y, width: HUDMenuPanel.rowWidth, height: row.frame.height)
            y += row.frame.height + 1
        }
        container.frame = NSRect(x: 0, y: 0, width: HUDMenuPanel.width, height: y + 8)
    }

    private func render(item: NSMenuItem, into container: NSView) {
        if item.isSeparatorItem {
            container.addSubview(divider())
            return
        }
        if item.identifier?.rawValue == "minibar.sectionHeader" {
            container.addSubview(headerRow(item.title))
            return
        }
        if let view = item.view {
            container.addSubview(view)
            return
        }
        if item.submenu != nil {
            let row = expanderRow(item)
            rowsById[ObjectIdentifier(item)] = row
            container.addSubview(row)
            return
        }
        let row = actionRow(item)
        rowsById[ObjectIdentifier(item)] = row
        container.addSubview(row)
    }

    // MARK: - 浮层卡片（z 轴堆栈：不推挤面板，浮在后续行之上）

    private func showOverlay(for item: NSMenuItem) {
        guard let submenu = item.submenu, let container = rowContainer,
              let anchorRow = rowsById[ObjectIdentifier(item)] else { return }
        hideOverlay()

        let card = FlippedView()
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

        let cardWidth = HUDMenuPanel.rowWidth - 26
        var y: CGFloat = 4
        for child in submenu.items where !child.isSeparatorItem {
            let row = overlayRow(child, rowWidth: cardWidth - 8)
            row.frame = NSRect(x: 4, y: y, width: cardWidth - 8, height: row.frame.height)
            y += row.frame.height + 1
            card.addSubview(row)
        }
        card.frame = NSRect(x: 40, y: 0, width: cardWidth, height: y + 4)

        container.addSubview(card, positioned: .above, relativeTo: nil)
        // 定位：锚行正下方，浮在后续行之上（容器翻转坐标：origin.y 即视觉顶部）
        let anchorFrame = anchorRow.frame
        card.frame.origin.y = anchorFrame.maxY + 2
        overlayCard = card

        // 浮层锚行箭头翻转
        if let arrow = expanderArrows[ObjectIdentifier(item)] {
            arrow.layer?.transform = CATransform3DMakeRotation(.pi, 0, 0, 1)
        }

        // 点浮层外（面板内）自动收起
        overlayMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.overlayCard != nil else { return event }
            let inWindow = event.window === self ? event.locationInWindow : NSEvent.mouseLocation
            let inContainer = container.convert(inWindow, from: nil)
            let inCard = card.frame.contains(inContainer)
            let inAnchor = anchorRow.frame.contains(inContainer)
            if !inCard && !inAnchor {
                self.collapseOverlay()
            }
            return event
        }
    }

    private func collapseOverlay() {
        if let item = rowsById.first(where: { $0.value === overlayCard }).map({ $0.key }) { _ = item }
        if let arrow = expanderArrows.first(where: { ObjectIdentifier($1) == expanded }).map({ $1 }) {
            arrow.layer?.transform = CATransform3DIdentity
        }
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
        expanderArrows.values.forEach { $0.layer?.transform = CATransform3DIdentity }
    }

    /// 浮层行：图标 + 名称 + 标签 + 右侧开关（单选互斥在点击后同步）
    private func overlayRow(_ item: NSMenuItem, rowWidth: CGFloat) -> NSView {
        let height: CGFloat = 24
        let row = HoverCardView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: height))

        let icon = NSImageView(image: item.image ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 8, y: (height - 13) / 2, width: 13, height: 13)

        // 设备行标题格式 "名称 · 类型"：类型拆出来放右侧（开关左侧）
        let parts = item.title.components(separatedBy: " · ")
        let nameText = parts.first ?? item.title
        let tagText: String? = parts.count > 1 ? parts.last : nil

        let title = NSTextField(labelWithString: nameText)
        title.font = NSFont.systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle

        let sw = NSSwitch()
        sw.controlSize = .mini
        sw.state = item.state == .on ? .on : .off
        let swSize = sw.intrinsicContentSize
        sw.frame = NSRect(x: rowWidth - swSize.width - 6, y: (height - swSize.height) / 2,
                          width: swSize.width, height: swSize.height)
        switchMap[ObjectIdentifier(sw)] = (sw, item)
        sw.target = self
        sw.action = #selector(switchFlipped(_:))

        row.addSubview(icon)
        row.addSubview(title)
        row.addSubview(sw)

        if let tagText {
            let tag = NSTextField(labelWithString: tagText)
            tag.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            tag.textColor = .tertiaryLabelColor
            tag.frame = NSRect(x: sw.frame.minX - 64, y: (height - 13) / 2, width: 58, height: 13)
            tag.alignment = .right
            row.addSubview(tag)
            title.frame.size.width = sw.frame.minX - 64 - 26 - 8
        } else {
            title.frame.size.width = sw.frame.minX - 26 - 8
        }
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
        let arrow = row.subviews.compactMap { $0 as? NSImageView }.last
        if let arrow { expanderArrows[ObjectIdentifier(item)] = arrow }
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
        let height: CGFloat = 26
        let row = HoverCardView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.rowWidth, height: height))
        row.wantsLayer = true

        let icon = NSImageView(image: item.image ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let iconWidth: CGFloat = item.image == nil ? 0 : 16
        icon.frame = NSRect(x: 10, y: (height - 15) / 2, width: iconWidth, height: 15)

        var textX = 10 + iconWidth + (iconWidth > 0 ? 8 : 0)
        let title = NSTextField(labelWithString: item.title)
        title.font = NSFont.systemFont(ofSize: 13)
        title.textColor = item.isEnabled ? .labelColor : .tertiaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle

        var trailingReservation: CGFloat = 10
        if !item.keyEquivalent.isEmpty {
            let key = NSTextField(labelWithString: "⌘\(item.keyEquivalent.uppercased())")
            key.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            key.textColor = .tertiaryLabelColor
            key.frame = NSRect(x: HUDMenuPanel.rowWidth - 40, y: (height - 13) / 2, width: 34, height: 13)
            key.alignment = .right
            row.addSubview(key)
            trailingReservation = 48
        }
        if let chevron {
            let arrow = NSImageView(image: NSImage(systemSymbolName: chevron,
                                                   accessibilityDescription: nil)!)
            arrow.contentTintColor = .tertiaryLabelColor
            arrow.frame = NSRect(x: HUDMenuPanel.rowWidth - 24, y: (height - 11) / 2, width: 12, height: 11)
            row.addSubview(arrow)
            trailingReservation = max(trailingReservation, 28)
        }

        let textWidth = HUDMenuPanel.rowWidth - textX - trailingReservation
        title.frame = NSRect(x: textX, y: (height - 16) / 2, width: max(textWidth, 40), height: 16)
        row.addSubview(icon)
        row.addSubview(title)
        return row
    }

    private func headerRow(_ title: String) -> NSView {
        let height: CGFloat = 22
        let container = NSView(frame: NSRect(x: 0, y: 0, width: HUDMenuPanel.rowWidth, height: height))
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: 10, y: (height - 13) / 2, width: HUDMenuPanel.rowWidth - 20, height: 13)
        container.addSubview(label)
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
            flash.frame = NSRect(x: row.frame.width - 150, y: 4, width: 140, height: 18)
            flash.alignment = .center
            row.addSubview(flash)
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
