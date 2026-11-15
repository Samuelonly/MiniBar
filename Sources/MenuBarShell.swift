import AppKit

/// 菜单外壳 = 传达室：唯一持有 NSStatusItem 的地方。
/// NSMenu 仅作为各模块申报的数据模型（不再显示），渲染交给自绘 HUDMenuPanel
/// （1.0.2 渲染器定稿：向下堆栈展开 / hover 卡片 / 贴边约束）。
final class MenuBarShell: NSObject {
    private let modules: [MiniBarModule]
    private var statusItem: NSStatusItem?
    private var hudPanel: HUDMenuPanel?

    override init() {
        modules = [DisplayModule(), StateModule(), PowerModule(), AudioModule(), StorageModule()]
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3",
                                     accessibilityDescription: "MiniBar")
        item.button?.target = self
        item.button?.action = #selector(toggleHUDPanel)
        statusItem = item
        syncModules()
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

    @objc private func toggleHUDPanel() {
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
        return menu
    }
}
