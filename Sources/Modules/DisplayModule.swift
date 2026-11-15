import AppKit
import CoreGraphics
import IOKit
import IOKit.graphics

/// 显示控制模块（PRD §3.1，最高频）
/// 多屏架构：**每个屏幕一个 Block**（Block 头 = 屏幕名），亮度/对比度按屏绑定、按屏缓存，
/// 外接屏走 DDC、内置屏走 IOKit——MacBook + N 个外接屏 = N 个独立 Block。
/// 画质模式（0x14）随鼠标所在屏路由。
final class DisplayModule: NSObject, MiniBarModule {
    var name: String { "display" }

    private let ddc = DDCTransport.shared
    private var ddcEndpoints: [DDCTransport.Endpoint] = []

    func activate() {
        refreshPictureMode()
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
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func ddcEndpoint(for screen: NSScreen) -> DDCTransport.Endpoint? {
        guard let displayID = displayID(screen) else { return nil }
        let identity = DDCTransport.Identity(vendor: CGDisplayVendorNumber(displayID),
                                             product: CGDisplayModelNumber(displayID),
                                             serial: CGDisplaySerialNumber(displayID))
        return ddcEndpoints.first { $0.identity == identity }
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }
    }

    /// 通过 vendor/product 匹配 IODisplayConnect 服务（内置屏亮度用）
    private func ioDisplayService(for displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IODisplayConnect"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let tag = "DisplayVendorID-\(CGDisplayVendorNumber(displayID))-DisplayProductID-\(CGDisplayModelNumber(displayID))"
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if let info = IODisplayCreateInfoDictionary(service, IOOptionBits(0))
                .takeRetainedValue() as? [String: Any],
               let location = info[kIODisplayLocationKey] as? String,
               location.contains(tag) {
                return service // 调用方负责 IOObjectRelease
            }
            IOObjectRelease(service)
        }
        return nil
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
    }

    // MARK: - 画质模式（VCP 0x14，随鼠标所在屏路由）

    private func refreshPictureMode() {
        DispatchQueue.global(qos: .utility).async {
            guard let endpoints = DDCTransport.shared?.endpoints() else { return }
            for endpoint in endpoints {
                if let reading = DDCTransport.shared?.read(endpoint, command: .pictureMode) {
                    UserDefaults.standard.set(Int(reading.current), forKey: "display.pictureMode")
                    UserDefaults.standard.set(Int(reading.max), forKey: "display.pictureModeMax")
                }
            }
        }
    }

    /// 画质模式切换：写 0x14 原始档位值（精确写入，不做百分比换算）
    @objc private func setPictureMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        guard let screen = currentScreen(), let endpoint = ddcEndpoint(for: screen) else { return }
        if ddc?.writeRaw(endpoint, command: .pictureMode, raw: UInt16(value)) == true {
            UserDefaults.standard.set(value, forKey: "display.pictureMode")
            sender.state = .on
        }
    }

    private func pictureModeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let modeMax = max(UserDefaults.standard.integer(forKey: "display.pictureModeMax"), 11)
        let currentMode = UserDefaults.standard.integer(forKey: "display.pictureMode")
        for value in 0...modeMax {
            let modeItem = menuItem(String(format: L("menu.display.modeItem"), value + 1),
                                    symbol: "",
                                    action: #selector(setPictureMode(_:)), target: self,
                                    state: currentMode == value ? .on : .off,
                                    rep: value)
            modeItem.toolTip = "VCP 0x14 = \(value)"
            menu.addItem(modeItem)
        }
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
        menu.addItem(menuItem(L("menu.rotation.landscape"), symbol: "arrow.left.arrow.right",
                              action: #selector(rotationChanged(_:)), target: self,
                              state: currentRotation == 0 ? .on : .off))
        menu.addItem(menuItem(L("menu.rotation.portrait"), symbol: "arrow.up.arrow.down",
                              action: #selector(rotationChanged(_:)), target: self,
                              state: currentRotation != 0 ? .on : .off))
        return menu
    }

    // MARK: - 菜单片段：Section 头 + 每屏一个 Block + 旋转 + 画质模式

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }
        ddcEndpoints = ddc?.endpoints() ?? []

        var items: [NSMenuItem] = [sectionHeader(L("menu.section.display"))]

        // 每屏一个 Block（多屏接口）：MacBook + 两个外接屏 = 三个 Block，各自独立
        for screen in NSScreen.screens {
            guard let displayID = displayID(screen) else { continue }
            items.append(screenBlock(screen, displayID: displayID))
        }

        items.append(menuItem(L("menu.display.rotation"), symbol: "rotate.right",
                              submenu: rotationMenu()))
        items.append(menuItem(L("menu.display.pictureMode"), symbol: "paintpalette",
                              submenu: pictureModeMenu()))
        return items
    }

    /// 单屏 Block：亮度滑杆（内置屏）/ 亮度+对比度滑杆（外接屏）
    private func screenBlock(_ screen: NSScreen, displayID: CGDirectDisplayID) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let brightness = NSSlider(
            value: UserDefaults.standard.object(forKey: brightnessCacheKey(displayID)) as? Double ?? 0.72,
            minValue: 0.05, maxValue: 1.0,
            target: self, action: #selector(brightnessChanged(_:)))
        brightness.identifier = NSUserInterfaceItemIdentifier(String(displayID))
        let brightnessItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        brightnessItem.view = SliderRowView(title: L("menu.display.brightness"), symbol: "sun.max",
                                            slider: brightness, rowWidth: 308)
        submenu.addItem(brightnessItem)

        let hasDDC = ddcEndpoint(for: screen) != nil
        if hasDDC {
            let contrast = NSSlider(
                value: UserDefaults.standard.object(forKey: contrastCacheKey(displayID)) as? Double ?? 50,
                minValue: 0, maxValue: 100,
                target: self, action: #selector(contrastChanged(_:)))
            contrast.identifier = NSUserInterfaceItemIdentifier(String(displayID))
            let contrastItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            contrastItem.view = SliderRowView(title: L("menu.display.contrast"), symbol: "circle.lefthalf.filled",
                                              slider: contrast, rowWidth: 308)
            submenu.addItem(contrastItem)
        }

        return menuItem(screen.localizedName, symbol: "display", submenu: submenu)
    }
}
