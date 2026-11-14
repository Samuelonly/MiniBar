import AppKit
import CoreGraphics
import IOKit
import IOKit.graphics

/// 显示控制模块（PRD §3.1，最高频）
/// 内置屏亮度：公开 IOKit API IODisplaySetFloatParameter（CGDisplaySetBrightness 已从 macOS 27 SDK 移除）。
/// 外接屏亮度/对比度：DDC/CI 走 IOAVService（移植自用户自己的 BrightnessBar，路线 MonitorControl MIT；
/// 对比度 VCP 0x12 为本次新增）。
final class DisplayModule: NSObject, MiniBarModule {
    var name: String { "display" }

    /// DDC 通道（可能为 nil：无外接屏或 IOAVService 不可用）
    private let ddc = DDCTransport.shared
    /// 菜单展开时刷新的 DDC 端点缓存，滑杆动作按屏幕身份匹配
    private var ddcEndpoints: [DDCTransport.Endpoint] = []

    func activate() {}
    func deactivate() { ddcEndpoints.removeAll() }

    /// 鼠标所在屏（PRD §3.1 多屏路由：拖拽即路由，无需手动选目标）
    private func currentScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// 屏幕身份（vendor/product/serial）→ DDC 端点
    private func ddcEndpoint(for screen: NSScreen?) -> DDCTransport.Endpoint? {
        guard let screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        let identity = DDCTransport.Identity(vendor: CGDisplayVendorNumber(displayID),
                                             product: CGDisplayModelNumber(displayID),
                                             serial: CGDisplaySerialNumber(displayID))
        return ddcEndpoints.first { $0.identity == identity }
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

    @objc private func brightnessChanged(_ sender: NSSlider) {
        guard let screen = currentScreen() else { return }
        if let endpoint = ddcEndpoint(for: screen) {
            // 外接屏：DDC/CI VCP 0x10
            _ = ddc?.write(endpoint, command: .brightness, percent: sender.doubleValue)
        } else if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let service = ioDisplayService(for: displayID) {
            // 内置屏：IOKit 亮度
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString,
                                       Float32(sender.doubleValue))
            IOObjectRelease(service)
        }
        UserDefaults.standard.set(sender.doubleValue, forKey: "display.brightness")
    }

    /// 对比度：DDC VCP 0x12（内置屏无软件对比度，静默忽略）
    @objc private func contrastChanged(_ sender: NSSlider) {
        guard let endpoint = ddcEndpoint(for: currentScreen()) else { return }
        _ = ddc?.write(endpoint, command: .contrast, percent: sender.doubleValue / 100)
        UserDefaults.standard.set(sender.doubleValue, forKey: "display.contrast")
    }

    /// 旋转：横屏(0) ⇄ 竖屏(90)，走私有 MonitorPanel MPDisplay（PRD §9-3）
    @objc private func rotationChanged(_ sender: NSMenuItem) {
        guard let screen = currentScreen(),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let target: Int32 = RotationController.shared.currentRotation(displayID) == 0 ? 90 : 0
        guard RotationController.shared.rotate(displayID, to: target) else { return }
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }
        // 菜单展开时刷新 DDC 端点缓存（滑杆动作按当前鼠标屏匹配路由）
        ddcEndpoints = ddc?.endpoints() ?? []
        let screen = currentScreen()
        let screenName = screen?.localizedName ?? "显示器"

        let label = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let labelField = NSTextField(labelWithString: "\(screenName) · 当前屏幕")
        labelField.font = NSFont.systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.lineBreakMode = .byTruncatingMiddle
        label.view = menuRow(height: 20, subviews: [iconView("display"), labelField])

        let rotationMenu = NSMenu()
        rotationMenu.autoenablesItems = false
        // 按当前鼠标屏实际旋转角勾选（PRD §3.1 横屏/竖屏切换）
        var currentRotation: Int32 = 0
        if let screen,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            currentRotation = RotationController.shared.currentRotation(displayID)
        }
        rotationMenu.addItem(menuItem("横屏", symbol: "arrow.left.arrow.right",
                                      action: #selector(rotationChanged(_:)), target: self,
                                      state: currentRotation == 0 ? .on : .off))
        rotationMenu.addItem(menuItem("竖屏", symbol: "arrow.up.arrow.down",
                                      action: #selector(rotationChanged(_:)), target: self,
                                      state: currentRotation != 0 ? .on : .off))

        let brightness = NSSlider(
            value: UserDefaults.standard.object(forKey: "display.brightness") as? Double ?? 0.72,
            minValue: 0.05, maxValue: 1.0,
            target: self, action: #selector(brightnessChanged(_:)))
        let contrast = NSSlider(
            value: UserDefaults.standard.object(forKey: "display.contrast") as? Double ?? 55,
            minValue: 0, maxValue: 100,
            target: self, action: #selector(contrastChanged(_:)))

        // PRD §12：异步回读 DDC 实时值，滑杆起步即真实状态（读不阻塞菜单展开）
        if let endpoint = ddcEndpoint(for: screen), let transport = ddc {
            let brightnessRef = brightness
            let contrastRef = contrast
            DispatchQueue.global(qos: .userInitiated).async {
                if let reading = transport.read(endpoint, command: .brightness) {
                    let value = Double(reading.current) / Double(max(reading.max, 1))
                    DispatchQueue.main.async { brightnessRef.doubleValue = value }
                }
                if let reading = transport.read(endpoint, command: .contrast) {
                    let value = Double(reading.current) / Double(max(reading.max, 1)) * 100
                    DispatchQueue.main.async { contrastRef.doubleValue = value }
                }
            }
        }

        return [sectionHeader("显示"),
                label,
                sliderRow("亮度", symbol: "sun.max", slider: brightness),
                sliderRow("对比度", symbol: "circle.lefthalf.filled", slider: contrast),
                menuItem("旋转方向", symbol: "rotate.right", submenu: rotationMenu)]
    }
}
