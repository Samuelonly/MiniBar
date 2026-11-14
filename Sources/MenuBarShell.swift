import AppKit

/// 菜单外壳：唯一持有 NSStatusItem + NSMenu 的地方。
/// 各模块按 PRD §3 固定顺序申报菜单片段，外壳零业务逻辑。
final class MenuBarShell: NSObject, NSMenuDelegate {
    private let modules: [MiniBarModule]
    private var statusItem: NSStatusItem?

    override init() {
        modules = [DisplayModule(), StateModule(), PowerModule(), AudioModule(), StorageModule()]
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3",
                                     accessibilityDescription: "MiniBar")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
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

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        var addedAny = false
        for module in modules {
            guard let section = module.menuSection() else { continue }
            if addedAny { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
            addedAny = true
        }
        // PRD §11 锚点：分隔线后永远是设置与退出
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "MiniBar 设置…",
                                  action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.target = NSApp.delegate as? AppDelegate
        menu.addItem(settings)
        let quit = NSMenuItem(title: "退出 MiniBar",
                              action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quit.target = NSApp.delegate as? AppDelegate
        menu.addItem(quit)
    }
}
