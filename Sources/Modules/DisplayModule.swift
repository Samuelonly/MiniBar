import AppKit
import CoreGraphics
import IOKit
import IOKit.graphics

/// 显示控制模块（PRD §3.1，最高频）
/// 多屏架构：**每个屏幕一个 Block**（Block 头 = 屏幕名），亮度/对比度按屏绑定、按屏缓存，
/// 外接屏走 DDC、内置屏走 IOKit——MacBook + N 个外接屏 = N 个独立 Block。
/// 场景随鼠标所在屏路由。
final class DisplayModule: NSObject, MiniBarModule {
    var name: String { "display" }

    private let ddc = DDCTransport.shared
    private var ddcEndpoints: [DDCTransport.Endpoint] = []

    func activate() {
        // 提前初始化场景仓库：恢复用户主动绑定的全局热键、写入默认场景。
        // 不能等到第一次开面板才初始化，否则冷启动时热键是死的。
        _ = SceneStore.shared
    }

    func deactivate() {
        ddcEndpoints.removeAll()
    }

    // MARK: - 屏幕定位

    /// 鼠标所在屏（画质模式/旋转的路由目标）
    private func currentScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        DisplayPort.displayID(of: screen)
    }

    private func ddcEndpoint(for screen: NSScreen) -> DDCTransport.Endpoint? {
        guard let displayID = displayID(screen) else { return nil }
        return DisplayPort.endpoint(for: displayID)
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        DisplayPort.screen(for: displayID)
    }

    /// 内置屏亮度服务（走显示端口层）
    private func ioDisplayService(for displayID: CGDirectDisplayID) -> io_service_t? {
        DisplayPort.ioService(for: displayID)
    }

    // MARK: - 亮度/对比度（按屏）

    private func brightnessCacheKey(_ displayID: CGDirectDisplayID) -> String { "display.brightness.\(displayID)" }
    private func contrastCacheKey(_ displayID: CGDirectDisplayID) -> String { "display.contrast.\(displayID)" }

    /// 亮度滑杆变化（滚轮/拖拽共用）：按滑杆上标的屏幕路由
    @objc private func brightnessChanged(_ sender: NSSlider) {
        guard let idString = sender.identifier?.rawValue,
              let displayID = UInt32(idString) else { return }
        let percent = sender.doubleValue
        UserDefaults.standard.set(percent, forKey: brightnessCacheKey(displayID))

        if let screen = screen(for: displayID), let endpoint = ddcEndpoint(for: screen) {
            _ = ddc?.write(endpoint, command: .brightness, percent: percent)
        } else if let service = ioDisplayService(for: displayID) {
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString,
                                       Float32(percent))
            IOObjectRelease(service)
        }
        // 不重建菜单，只让场景区块重算 dirty 状态
        NotificationCenter.default.post(name: .minibarDisplayValueChanged, object: nil)
    }

    /// 对比度滑杆变化：仅外接屏（DDC VCP 0x12），内置屏无软件对比度
    @objc private func contrastChanged(_ sender: NSSlider) {
        guard let idString = sender.identifier?.rawValue,
              let displayID = UInt32(idString),
              let screen = screen(for: displayID),
              let endpoint = ddcEndpoint(for: screen) else { return }
        let percent = sender.doubleValue / 100
        _ = ddc?.write(endpoint, command: .contrast, percent: percent)
        UserDefaults.standard.set(sender.doubleValue, forKey: contrastCacheKey(displayID))
        NotificationCenter.default.post(name: .minibarDisplayValueChanged, object: nil)
    }

    // MARK: - 场景（随鼠标所在屏路由）

    /// 场景应用：submenu 里点场景 → apply + 重建菜单让滑杆跟值
    @objc private func applySceneFromPictureMode(_ sender: NSMenuItem) {
        guard let sceneID = sender.representedObject as? String,
              let scene = SceneStore.shared.scenes.first(where: { $0.id == sceneID }),
              let screen = currentScreen(),
              let displayID = displayID(screen) else { return }

        // dirty 场景切换：先问保存 / 丢弃 / 取消
        if SceneStore.shared.isDirty(displayID: displayID),
           let currentID = SceneStore.shared.activeSceneID(for: displayID),
           currentID != scene.id,
           let currentName = SceneStore.shared.scenes.first(where: { $0.id == currentID })?.displayName {
            switch SceneDialogs.switchChoice(sceneName: currentName) {
            case .save:
                SceneStore.shared.updateActiveWithCurrent(displayID: displayID)
            case .discard:
                break
            case .cancel:
                return
            }
        }

        _ = SceneStore.shared.apply(scene, on: displayID)
        if !DisplayPort.isSupported(displayID) {
            SceneDialogs.info(L("scene.apply.failed"))
        }
        NotificationCenter.default.post(name: ModuleEvent.menuRefresh, object: nil)
    }

    /// dirty 时：用当前滑杆值覆盖激活场景
    @objc private func updateSceneFromPictureMode(_ sender: NSMenuItem) {
        guard let sceneID = sender.representedObject as? String,
              let screen = currentScreen(),
              let displayID = displayID(screen) else { return }
        SceneStore.shared.updateActiveWithCurrent(displayID: displayID)
        NotificationCenter.default.post(name: ModuleEvent.menuRefresh, object: nil)
    }

    /// 存为新场景
    @objc private func saveSceneFromPictureMode(_ sender: NSMenuItem) {
        guard let screen = currentScreen(), let displayID = displayID(screen),
              let name = SceneDialogs.prompt(
                title: L("scene.new.title"),
                message: L("scene.new.message"),
                placeholder: L("scene.new.placeholder")) else { return }
        SceneStore.shared.addScene(name: name, displayID: displayID)
        NotificationCenter.default.post(name: ModuleEvent.menuRefresh, object: nil)
    }

    /// 恢复内置场景
    @objc private func restoreScenesFromPictureMode(_ sender: NSMenuItem) {
        guard SceneDialogs.confirm(title: L("scene.restore.title"),
                                   message: L("scene.restore.message"),
                                   action: L("scene.restore.action")) else { return }
        guard let screen = currentScreen(), let displayID = displayID(screen) else { return }
        SceneStore.shared.restoreBuiltins(displayID: displayID)
        NotificationCenter.default.post(name: ModuleEvent.menuRefresh, object: nil)
    }

    /// 场景 submenu：日常 / 影像 / 文稿 / 夜读 / 暗房（用户要求收这里）
    private func scenesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let store = SceneStore.shared
        let displayID = currentScreen().flatMap { displayID($0) }
        let activeID = displayID.flatMap { store.activeSceneID(for: $0) }
        let dirty = displayID.map { store.isDirty(displayID: $0) } ?? false

        // —— 场景行 ——
        for scene in store.scenes {
            let isActive = activeID == scene.id
            let item = NSMenuItem(title: scene.displayName,
                                  action: #selector(applySceneFromPictureMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = scene.id
            item.identifier = NSUserInterfaceItemIdentifier("minibar.pmSceneRow")
            item.image = isActive
                ? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                : nil
            item.state = isActive ? .on : .off
            item.tag = Int(isActive && dirty ? 1 : 0)
            menu.addItem(item)
        }

        // —— dirty 保存 ——
        if dirty, let activeID,
           let activeScene = store.scenes.first(where: { $0.id == activeID }) {
            menu.addItem(NSMenuItem.separator())
            let item = NSMenuItem(title: String(format: L("menu.scene.update"), activeScene.displayName),
                                  action: #selector(updateSceneFromPictureMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = activeID
            item.identifier = NSUserInterfaceItemIdentifier("minibar.pmSceneDirty")
            item.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                 accessibilityDescription: nil)
            menu.addItem(item)
        }

        // —— 动作行 ——
        menu.addItem(NSMenuItem.separator())
        let saveItem = NSMenuItem(title: L("menu.scene.saveNew"),
                                  action: #selector(saveSceneFromPictureMode(_:)),
                                  keyEquivalent: "")
        saveItem.target = self
        saveItem.identifier = NSUserInterfaceItemIdentifier("minibar.pmSceneSaveNew")
        saveItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(saveItem)

        let restoreItem = NSMenuItem(title: L("menu.scene.restore"),
                                     action: #selector(restoreScenesFromPictureMode(_:)),
                                     keyEquivalent: "")
        restoreItem.target = self
        restoreItem.identifier = NSUserInterfaceItemIdentifier("minibar.pmSceneRestore")
        restoreItem.image = NSImage(systemSymbolName: "arrow.2.squarepath",
                                    accessibilityDescription: nil)
        menu.addItem(restoreItem)

        // 画质档位 VCP 0x14 已移除 — 用户确认这些硬件档位名对终端用户无意义

        return menu
    }

    // MARK: - 旋转（随鼠标所在屏路由）

    @objc private func rotationChanged(_ sender: NSMenuItem) {
        guard let screen = currentScreen(),
              let displayID = displayID(screen) else { return }
        let target: Int32 = RotationController.shared.currentRotation(displayID) == 0 ? 90 : 0
        guard RotationController.shared.rotate(displayID, to: target) else { return }
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    private func rotationMenu() -> NSMenu {
        var currentRotation: Int32 = 0
        if let screen = currentScreen(), let displayID = displayID(screen) {
            currentRotation = RotationController.shared.currentRotation(displayID)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // HTML .child-row（旋转浮层）：只有文字 + 开关，无图标、无 tag
        menu.addItem(menuItem(L("menu.rotation.landscape"), symbol: "",
                              action: #selector(rotationChanged(_:)), target: self,
                              state: currentRotation == 0 ? .on : .off))
        menu.addItem(menuItem(L("menu.rotation.portrait"), symbol: "",
                              action: #selector(rotationChanged(_:)), target: self,
                              state: currentRotation != 0 ? .on : .off))
        return menu
    }

    // MARK: - 菜单片段：Section 头 + 每屏一个 Block + 旋转 + 画质模式

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }
        ddcEndpoints = ddc?.endpoints() ?? []

        var items: [NSMenuItem] = [sectionHeader(L("menu.section.display"))]

        // 多屏：每个屏幕一组（屏名文本行 + 滑杆直接可见），不用下拉折叠——滑杆永远一步可达
        for screen in NSScreen.screens {
            guard let displayID = displayID(screen) else { continue }

            // HTML .screen-label：纯文本 <b> 白色 500，无图标，行高 22
            let nameRow = NSMenuItem(title: screen.localizedName, action: nil, keyEquivalent: "")
            nameRow.identifier = NSUserInterfaceItemIdentifier("minibar.screenLabel")
            items.append(nameRow)

            let brightness = NSSlider(
                value: UserDefaults.standard.object(forKey: brightnessCacheKey(displayID)) as? Double ?? 0.72,
                minValue: 0.05, maxValue: 1.0,
                target: self, action: #selector(brightnessChanged(_:)))
            brightness.identifier = NSUserInterfaceItemIdentifier(String(displayID))
            let brightnessItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            brightnessItem.view = SliderRowView(title: L("menu.display.brightness"), symbol: "sun.max",
                                                slider: brightness, rowWidth: 308)
            items.append(brightnessItem)

            if ddcEndpoint(for: screen) != nil {
                let contrast = NSSlider(
                    value: UserDefaults.standard.object(forKey: contrastCacheKey(displayID)) as? Double ?? 50,
                    minValue: 0, maxValue: 100,
                    target: self, action: #selector(contrastChanged(_:)))
                contrast.identifier = NSUserInterfaceItemIdentifier(String(displayID))
                let contrastItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                contrastItem.view = SliderRowView(title: L("menu.display.contrast"), symbol: "circle.lefthalf.filled",
                                                  slider: contrast, rowWidth: 308)
                items.append(contrastItem)
            }
        }

        items.append(menuItem(L("menu.display.scenes"), symbol: "paintpalette",
                              submenu: scenesMenu()))

        // 旋转：独立放在末尾
        items.append(NSMenuItem.separator())
        items.append(menuItem(L("menu.display.rotation"), symbol: "rotate.right",
                              submenu: rotationMenu()))
        return items
    }
}
