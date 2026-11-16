import AppKit
import SwiftUI

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
    private var labelWidthConstraint: NSLayoutConstraint?

    // MARK: i18n 标签宽度（所有滑杆行共享，两条轨道同起点）
    // 按当前语言实测所有已注册标签取最大值：长语言标签完整显示、滑杆相应变短，
    // 行内间距不变。下限 40（HTML .lbl 定稿），上限 141 = 行内容宽 280
    // - 图标 15 - 间距 12×2 - 滑杆最小 100：极端长语言标签截断，绝不与滑杆粘上。
    private static var labelWidths: [String: CGFloat] = [:]
    static var sharedLabelWidth: CGFloat {
        min(max(labelWidths.values.max() ?? 40, 40), 141)
    }
    static func registerLabel(_ title: String) {
        let w = ceil((title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
        labelWidths[title] = w
    }

    /// 渲染层以这两个值在 SwiftUI 里重建同样的滑杆行（不再把本视图塞进视图树）
    let rowTitle: String
    let rowSymbol: String

    var sliderMin: Double { slider.minValue }
    var sliderMax: Double { slider.maxValue }
    var sliderValue: Double { slider.doubleValue }

    /// SwiftUI 滑杆改动 → 写回 NSSlider 并触发模块原有 action（target/action 不动）
    func commit(_ value: Double) {
        let clamped = max(slider.minValue, min(slider.maxValue, value))
        slider.doubleValue = clamped
        slider.target?.perform(slider.action, with: slider)
    }

    init(title: String, symbol: String, slider: NSSlider, rowWidth: CGFloat) {
        self.slider = slider
        rowTitle = title
        rowSymbol = symbol
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
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        // 标签宽度 = 当前语言实测共享值（i18n：长语言完整显示，短语言保持 HTML 的 40）
        Self.registerLabel(title)
        let labelWidth = label.widthAnchor.constraint(equalToConstant: Self.sharedLabelWidth)
        labelWidth.isActive = true
        labelWidthConstraint = labelWidth
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        slider.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [icon, label, slider])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12 // 用户定稿：行内 gap 12（UI 微调，不再锚定 HTML 的 9）
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(valueTag)
        // HTML input[type=range]：已走过的轨道是强调色，其余是 18% 白
        applyAccentTrack(to: slider)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // HTML .ic{width:15px;height:15px}
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        // 所有滑杆行在菜单构建期先后注册标签；布局时统一成最终共享宽度，保证轨道同起点
        labelWidthConstraint?.constant = Self.sharedLabelWidth
        super.layout()
    }

    override func scrollWheel(with event: NSEvent) {
        // 滚轮灵敏度：每 1px 滚轮位移只走滑杆范围的 0.5%
        // deltaY 是累计值（滚一圈 = 好几十），所以必须按比例而不是硬加常量
        let span = slider.maxValue - slider.minValue
        let step = span * 0.005 * abs(event.deltaY)
        let delta: Double = event.deltaY > 0 ? -step : step
        let clamped = max(slider.minValue, min(slider.maxValue, slider.doubleValue + delta))
        slider.doubleValue = clamped
        slider.target?.perform(slider.action, with: slider)
        showValueTag()
    }

    /// 数值角标：旋钮上方浮现 0~100，0.7s 无操作即隐
    private func showValueTag() {
        let pct = CGFloat((slider.doubleValue - slider.minValue)
            / max(slider.maxValue - slider.minValue, 0.001))
        // 轨道起点 = padding 6 + 图标15 + gap12 + 共享标签宽 + gap12；旋钮宽 14
        let trackStart: CGFloat = 6 + 15 + 12 + Self.sharedLabelWidth + 12
        let trackWidth = max(bounds.width - trackStart - 14, 10)
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

/// 自绘渲染器需要的行级元数据（caption 显示文案，payload 承载机器可读值）。
/// 原先这些信息散在 NSMenuItem.title / representedObject 里，渲染层拿不到，
/// 统一收口到这个结构体，模块侧通过 `representedObject` 挂在 item 上。
struct MenuRowMeta {
    var caption: String
    var payload: Any?
}

/// HTML input[type=range] 轨道：4px 圆角，已走过的部分是强调色，其余是 18% 前景色。
/// NSSlider 的 trackFillColor 只在少数外观下生效，这里直接接管 bar 绘制。
final class AccentSliderCell: NSSliderCell {
    private let accent = NSColor(red: 77 / 255, green: 157 / 255, blue: 255 / 255, alpha: 1)

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        // HTML：轨道 height 4px / border-radius 2px
        let height: CGFloat = 4
        let bar = NSRect(x: rect.minX, y: rect.midY - height / 2,
                         width: rect.width, height: height)
        let radius = height / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        let span = maxValue - minValue
        let fraction = span > 0 ? (doubleValue - minValue) / span : 0
        let width = bar.width * max(0, min(1, fraction))
        guard width > 0.5 else { return }
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                         width: width, height: bar.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

/// 把现成 NSSlider 的 cell 换成自绘轨道的（值 / 目标 / 动作原样搬过去）
func applyAccentTrack(to slider: NSSlider) {
    guard let old = slider.cell as? NSSliderCell, !(old is AccentSliderCell) else { return }
    let cell = AccentSliderCell()
    cell.minValue = old.minValue
    cell.maxValue = old.maxValue
    cell.doubleValue = old.doubleValue
    cell.sliderType = old.sliderType
    cell.numberOfTickMarks = old.numberOfTickMarks
    cell.target = old.target
    cell.action = old.action
    cell.isContinuous = old.isContinuous
    slider.cell = cell
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
    /// HUD 菜单 model 需要重建（屏幕睡/醒、盘挂载/弹出等外部状态变化）
    static let menuRefresh = Notification.Name("minibar.menuRefresh")
}

// MARK: - 面板皮肤（主面板 + 设置面板共用）
//
// 规则（用户定稿，无开关）：
//   从未点过外观 chip → 跟随系统，系统切深浅色面板立刻跟着换；
//   点过一次 chip     → 记住用户选择，之后永远用手动的，不再随系统变。
// chip 只切 MiniBar 自己的面板皮肤，不改系统外观。

enum PanelSkin: String {
    case light, dark

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var nsAppearance: NSAppearance {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)!
    }

    /// 面板底色：深色沿用 HTML 定稿 #1C1C20，浅色为对应亮色 #F6F6F8
    var background: Color {
        self == .dark
            ? Color(red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 32.0 / 255.0)
            : Color(red: 246.0 / 255.0, green: 246.0 / 255.0, blue: 248.0 / 255.0)
    }
    var backgroundNS: NSColor {
        self == .dark
            ? NSColor(calibratedRed: 28.0 / 255.0, green: 28.0 / 255.0, blue: 32.0 / 255.0, alpha: 1)
            : NSColor(calibratedRed: 246.0 / 255.0, green: 246.0 / 255.0, blue: 248.0 / 255.0, alpha: 1)
    }
    /// 面板描边 / 分隔线 / 子行 tag 描边：深底用白、浅底用黑
    var border: Color { self == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.10) }
    var borderNS: NSColor {
        self == .dark ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.10)
    }
    var separator: Color { self == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12) }
    var tagBorder: Color { self == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.16) }
}

enum PanelAppearance {
    /// UserDefaults 键：存手动皮肤；不存在 = 跟随系统
    static let manualKey = "panel.skin.manual"
    /// 手动皮肤变化广播（面板监听后重建）
    static let changed = Notification.Name("minibar.panelSkinChanged")

    static var manual: PanelSkin? {
        PanelSkin(rawValue: UserDefaults.standard.string(forKey: manualKey) ?? "")
    }

    /// 当前有效皮肤：手动优先，未手动跟随系统
    static var current: PanelSkin {
        if let manual { return manual }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .dark : .light
    }

    /// chip 点击：手动切到当前皮肤的反面，并广播（菜单 + 两块面板一起换）
    static func toggleManual() {
        let next: PanelSkin = current == .dark ? .light : .dark
        UserDefaults.standard.set(next.rawValue, forKey: manualKey)
        NotificationCenter.default.post(name: changed, object: nil)
        NotificationCenter.default.post(name: ModuleEvent.menuRefresh, object: nil)
    }
}
