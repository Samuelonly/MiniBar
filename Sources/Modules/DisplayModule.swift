import AppKit
import CoreGraphics
import IOKit
import IOKit.graphics

/// 显示控制模块（PRD §3.1，最高频）
/// 内置屏亮度走公开 IOKit API IODisplaySetFloatParameter（CGDisplaySetBrightness 已从 macOS 27 SDK 移除）；
/// 外接屏 DDC 亮度/对比度 TODO(1.0)：移植 MonitorControl 的 DDC 层（references/MonitorControl）。
final class DisplayModule: NSObject, MiniBarModule {
    var name: String { "display" }

    func activate() {}
    func deactivate() {}

    /// 鼠标所在屏（PRD §3.1 多屏路由：拖拽即路由，无需手动选目标）
    private func currentScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// 通过 vendor/product 匹配 IODisplayConnect 服务
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
        guard let screen = currentScreen(),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let service = ioDisplayService(for: displayID) else { return }
        IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString,
                                   Float32(sender.doubleValue))
        IOObjectRelease(service)
        UserDefaults.standard.set(sender.doubleValue, forKey: "display.brightness")
    }

    /// TODO(1.0): DDC VCP 0x12 对比度（外接屏）；内置屏无软件对比度
    @objc private func contrastChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "display.contrast")
    }

    /// TODO(1.0): 私有 CoreDisplay CGS 接口（已批准，PRD §9-3），参考 displayplacer
    @objc private func rotationChanged(_ sender: NSMenuItem) {
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
    }

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }
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
        rotationMenu.addItem(menuItem("横屏", symbol: "arrow.left.arrow.right",
                                      action: #selector(rotationChanged(_:)), target: self, state: .on))
        rotationMenu.addItem(menuItem("竖屏", symbol: "arrow.up.arrow.down",
                                      action: #selector(rotationChanged(_:)), target: self))

        let brightness = NSSlider(
            value: UserDefaults.standard.object(forKey: "display.brightness") as? Double ?? 0.72,
            minValue: 0.05, maxValue: 1.0,
            target: self, action: #selector(brightnessChanged(_:)))
        let contrast = NSSlider(
            value: UserDefaults.standard.object(forKey: "display.contrast") as? Double ?? 55,
            minValue: 0, maxValue: 100,
            target: self, action: #selector(contrastChanged(_:)))

        return [sectionHeader("显示"),
                label,
                sliderRow("亮度", symbol: "sun.max", slider: brightness),
                sliderRow("对比度", symbol: "circle.lefthalf.filled", slider: contrast),
                menuItem("旋转方向", symbol: "rotate.right", submenu: rotationMenu)]
    }
}
