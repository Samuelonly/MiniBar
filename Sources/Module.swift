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
func sectionHeader(_ title: String) -> NSMenuItem {
    NSMenuItem.sectionHeader(title: title)
}

func iconView(_ symbol: String) -> NSImageView {
    let view = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
    view.contentTintColor = .secondaryLabelColor
    return view
}

/// 悬停反馈行（PRD §12.1 定稿：悬停点亮 + 柔和外阴影，不做缩放——
/// 密排菜单里缩放是干扰项，阴影给"卡片浮起"的掌控感）
final class HoverCardView: NSView {
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            layer?.shadowOpacity = 0.28
            layer?.shadowRadius = 5
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.shadowOpacity = 0
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

extension Notification.Name {
    static let miniBarModulesChanged = Notification.Name("miniBarModulesChanged")
}
