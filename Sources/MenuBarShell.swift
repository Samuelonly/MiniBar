import AppKit

/// 菜单外壳 = 传达室：唯一持有 NSStatusItem 的地方。
/// NSMenu 仅作为各模块申报的数据模型（不再显示），渲染交给自绘 HUDMenuPanel
/// （1.0.2 渲染器定稿：向下堆栈展开 / hover 卡片 / 贴边约束）。
final class MenuBarShell: NSObject {
    private let modules: [MiniBarModule]
    private var statusItem: NSStatusItem?
    private var hudPanel: HUDMenuPanel?
    private var refreshObserver: Any?
    /// 上次 buildMenuModel 返回的 menu——用于把 AppKit 滑杆 view 迁移到新 menu，避免每次 refresh 重建滑杆
    private var lastMenu: NSMenu?

    /// 暴露给 PowerModule 用：屏幕休眠前先隐藏 statusItem 按钮窗口（否则系统认为 App 还有活动而阻止睡眠）
    var statusItemWindow: NSWindow? { statusItem?.button?.window }

    override init() {
        modules = [DisplayModule(), StateModule(), PowerModule(), AudioModule(), StorageModule()]
        super.init()

        // PowerModule 屏幕睡/醒、StorageModule 盘弹出/挂载等 → HUD 面板需要重建 menu model
        refreshObserver = NotificationCenter.default.addObserver(
            forName: ModuleEvent.menuRefresh, object: nil, queue: .main
        ) { [weak self] _ in
            // 必须先刷新 model，再让面板 render——menu item 的 state 是在 buildMenuModel 时写的
            self?.hudPanel?.refreshMenu()
        }
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 状态栏图标：优先用 bundle 里的 PNG，回退到系统符号。
        // 源图是 SVG 几何矢量重绘的 40×40（= 20pt @2x），逻辑尺寸固定 20×20pt：
        // 之前是 22px 的 1x 位图，Retina 上被拉伸 2 倍，看起来发虚、也显得偏大。
        if let imgPath = Bundle.main.path(forResource: "MiniBar-menubar", ofType: "png"),
           let img = NSImage(contentsOfFile: imgPath) {
            img.size = NSSize(width: 16, height: 16)  // 状态栏视觉尺寸：16pt
            img.isTemplate = true  // 让系统自动适配深浅色
            item.button?.image = img
            item.button?.imageScaling = .scaleProportionallyDown
        } else {
            item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3",
                                         accessibilityDescription: "MiniBar")
        }
        item.button?.target = self
        item.button?.action = #selector(toggleHUDPanel)
        statusItem = item
        syncModules()

        // Bug 2 补充：屏幕唤醒时把 statusItem 窗口重新放回前层（屏幕休眠前被 orderOut 了）
        let captured = self
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak captured] _ in
            guard let shell = captured else { return }
            (shell as MenuBarShell).statusItemWindow?.orderFrontRegardless()
        }
    }

    /// 勾选即加载，取消即彻底销毁（PRD §5/§6：零监听、零 Timer、零唤醒）
    func syncModules() {
        for module in modules {
            if isEnabled(module) {
                module.activate()
            } else {
                module.deactivate()
            }
        }
    }

    func statusButtonFrame() -> NSRect? {
        statusItem?.button?.window?.frame
    }

    @objc func toggleHUDPanel() {
        if let panel = hudPanel, panel.isVisible {
            panel.dismiss()
            hudPanel = nil
            return
        }
        let panel = HUDMenuPanel(shell: self)
        hudPanel = panel
        panel.showUnderButton(statusButtonFrame())
    }

    /// 数据模型：按 PRD §3 固定顺序装配各模块申报的菜单片段
    func buildMenuModel() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var addedAny = false
        for module in modules {
            guard let section = module.menuSection() else { continue }
            if addedAny { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
            addedAny = true
        }
        // PRD §11 锚点：分隔线后永远是设置与退出
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L("menu.settings"),
                                  action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.target = NSApp.delegate as? AppDelegate
        menu.addItem(settings)

        let quit = NSMenuItem(title: L("menu.quit"),
                              action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quit.target = NSApp.delegate as? AppDelegate
        menu.addItem(quit)

        // Bug 1 修复：把上次 menu 里带 AppKit view 的行（滑杆等）迁移过来
        // 这样 refreshMenu 重建 menu model 时，滑杆 view 不会丢——避免 SliderRowView/NSSlider 反复创建
        if let oldMenu = lastMenu {
            migrateViews(from: oldMenu, to: menu)
        }
        lastMenu = menu
        return menu
    }

    /// 按索引对齐迁移 AppKit view：滑杆行（NSMenuItem.title == "" 且有 .view）在新 menu 里
    /// 位置没变，直接用旧 view 覆盖新 item.view，保留用户正在拖的 NSSlider
    private func migrateViews(from old: NSMenu, to new: NSMenu) {
        let oldItems = old.items
        let newItems = new.items
        let count = min(oldItems.count, newItems.count)
        for i in 0..<count {
            if let oldView = oldItems[i].view, oldItems[i].title.isEmpty {
                newItems[i].view = oldView
            }
        }
    }
}
