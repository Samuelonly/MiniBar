import AppKit

/// 微内核模块协议（PRD §11 三条腿）：
/// activate() 注册并启动工作；deactivate() 彻底销毁（注销监听/Timer/子进程）；
/// menuSection() 申报菜单片段，未启用返回 nil（菜单长度 = 用户勾选数的函数）。
protocol MiniBarModule: AnyObject {
    var name: String { get }
    func activate()
    func deactivate()
    func menuSection() -> [NSMenuItem]?
}

/// 懒人模块化（PRD §5）：勾选即加载，取消即销毁。默认全开。
func isEnabled(_ module: MiniBarModule) -> Bool {
    UserDefaults.standard.object(forKey: "module.\(module.name)") as? Bool ?? true
}

/// 通用工厂：带单色 Template 图标的菜单项（PRD §10 图标一致性：每一行必有图标）
func menuItem(_ title: String, symbol: String, action: Selector? = nil, target: NSObject? = nil,
              state: NSControl.StateValue = .off, submenu: NSMenu? = nil, rep: Any? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
        item.image = image
    }
    item.target = target
    item.state = state
    if let submenu { item.submenu = submenu }
    if let rep { item.representedObject = rep }
    return item
}

/// 节标题（等宽大写灰字，PRD §10 NIL 同款视觉）
/// identifier 标记供自绘 HUD 渲染器识别节标题
func sectionHeader(_ title: String) -> NSMenuItem {
    let item = NSMenuItem.sectionHeader(title: title)
    item.identifier = NSUserInterfaceItemIdentifier("minibar.sectionHeader")
    return item
}

func iconView(_ symbol: String) -> NSImageView {
    let view = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
    view.contentTintColor = .secondaryLabelColor
    return view
}

/// 悬停反馈行（PRD §12.1 定稿：悬停点亮 + 柔和外阴影，不做缩放——
/// 密排菜单里缩放是干扰项，阴影给"卡片浮起"的掌控感）
/// 自绘菜单里兼任可点击行：onClick 由渲染器注入。
final class HoverCardView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func viewDidMoveToWindow() {
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = NSSize(width: 0, height: 1)
        layer?.shadowOpacity = 0
        layer?.masksToBounds = false
        guard window != nil else { return }
        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
    }

    override func mouseEntered(with event: NSEvent) {
        // PRD §12.1 阻尼：慢减速曲线（吧嗒吧嗒的机械质感）
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1))
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 5
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1))
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.shadowOpacity = 0
        CATransaction.commit()
    }
}

/// 滑杆行（PRD §3.1 定稿）：滚轮上=减(向左)、下=增(向右)；数值角标拖动/滚动时浮现、停手即隐
final class SliderRowView: NSView {
    private let slider: NSSlider
    private let valueTag: NSTextField
    private var hideTimer: Timer?

    init(title: String, symbol: String, slider: NSSlider, rowWidth: CGFloat) {
        self.slider = slider
        valueTag = NSTextField(labelWithString: "")
        valueTag.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        valueTag.textColor = .white
        valueTag.wantsLayer = true
        valueTag.layer?.backgroundColor = NSColor(red: 0.30, green: 0.61, blue: 1.0, alpha: 1).cgColor
        valueTag.layer?.cornerRadius = 4
        valueTag.alignment = .center
        valueTag.alphaValue = 0
        super.init(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 30))

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        slider.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [icon, label, slider])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(valueTag)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func scrollWheel(with event: NSEvent) {
        // 滚轮上(deltaY>0)=减(向左)，下=增(向右)
        let delta: Double = event.deltaY > 0 ? -2 : 2
        let clamped = max(slider.minValue, min(slider.maxValue, slider.doubleValue + delta))
        slider.doubleValue = clamped
        slider.target?.perform(slider.action, with: slider)
        showValueTag()
    }

    /// 数值角标：旋钮上方浮现 0~100，0.7s 无操作即隐
    private func showValueTag() {
        let pct = CGFloat((slider.doubleValue - slider.minValue)
            / max(slider.maxValue - slider.minValue, 0.001))
        let trackStart: CGFloat = 6 + 15 + 8 + 40 + 8
        let trackWidth = max(bounds.width - trackStart - 12, 10)
        let x = trackStart + trackWidth * pct
        valueTag.stringValue = String(Int(pct * 100))
        valueTag.sizeToFit()
        let tagWidth = max(valueTag.frame.width + 10, 30)
        valueTag.frame = NSRect(x: min(max(x - tagWidth / 2, 8), bounds.width - tagWidth - 8),
                                y: bounds.height - 2, width: tagWidth, height: 16)
        valueTag.alphaValue = 1
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.valueTag.alphaValue = 0
        }
    }
}

/// 自定义 view 行（滑杆行/图标 Grid 行共用的容器）
func menuRow(height: CGFloat, subviews: [NSView]) -> NSView {
    let container = HoverCardView(frame: NSRect(x: 0, y: 0, width: 280, height: height))
    let stack = NSStackView(views: subviews)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    return container
}

/// 滑杆行（PRD §10 控件映射：连续量 → 滑杆）
func sliderRow(_ title: String, symbol: String, slider: NSSlider) -> NSMenuItem {
    let label = NSTextField(labelWithString: title)
    label.font = NSFont.systemFont(ofSize: 12)
    label.textColor = .secondaryLabelColor
    label.setContentHuggingPriority(.required, for: .horizontal)
    slider.setContentHuggingPriority(.init(1), for: .horizontal)
    slider.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    item.view = menuRow(height: 28, subviews: [iconView(symbol), label, slider])
    return item
}

/// 设备名超长时中间截断（PRD §3.4）
func middleTruncate(_ string: String, max: Int = 30) -> String {
    guard string.count > max, string.count > 4 else { return string }
    let half = max / 2
    return String(string.prefix(half)) + "…" + String(string.suffix(half - 1))
}

/// 阻塞执行并返回退出码（用于 diskutil unmount 需要判断成败的场景）
func runCommand(_ path: String, _ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// 发射后不管（用于 pmset 等不关心结果的指令）
func runDetached(_ path: String, _ args: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    try? process.run()
}

/// 传达室事件总线（架构定稿）：
/// 单进程，总线住在 MenuBarShell 里，模块只广播/订阅、互相不 import；
/// 唯一外派进程是 caffeinate（哑巴工人，只干防休眠，永不兼职调度）。
enum ModuleEvent {
    /// DisplayModule 滑杆变化，userInfo["value"] = 新亮度 0~1
    static let sliderDidChange = Notification.Name("minibar.sliderDidChange")
    /// 设置面板模块勾选变化（勾选即加载，取消即销毁）
    static let modulesChanged = Notification.Name("minibar.modulesChanged")
    /// 模块 → 渲染器的行内提示（阻断警示等）
    /// userInfo: "item" = NSMenuItem（定位行），"text" = String，"warn" = Bool
    static let rowHint = Notification.Name("minibar.rowHint")
}
