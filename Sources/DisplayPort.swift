import AppKit
import CoreGraphics
import IOKit

/// 显示端口（DisplayPort）——唯一碰硬件的层。
/// 业务逻辑（场景、滑杆）只调这里，不直接摸 DDC/IOKit。
/// 一期实现：外接屏 DDC/CI；内置屏走 IOKit 亮度。
enum DisplayPort {

    // MARK: - 屏幕定位

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(of: $0) == displayID }
    }

    /// 鼠标所在屏——场景与画质模式都按这块屏路由
    static func currentDisplayID() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen.flatMap { displayID(of: $0) }
    }

    /// 多屏存储键：优先序列号，退化到 displayID
    static func key(for displayID: CGDirectDisplayID) -> String {
        let serial = CGDisplaySerialNumber(displayID)
        return serial != 0 ? "sn-\(serial)" : "id-\(displayID)"
    }

    // MARK: - DDC 端点

    static func endpoint(for displayID: CGDirectDisplayID) -> DDCTransport.Endpoint? {
        let identity = DDCTransport.Identity(vendor: CGDisplayVendorNumber(displayID),
                                             product: CGDisplayModelNumber(displayID),
                                             serial: CGDisplaySerialNumber(displayID))
        return DDCTransport.shared?.endpoints().first { $0.identity == identity }
    }

    /// 内置屏亮度服务（IODisplayConnect）
    static func ioService(for displayID: CGDirectDisplayID) -> io_service_t? {
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

    // MARK: - 能力

    /// 能否软件调对比度：只有外接屏（DDC VCP 0x12）
    static func supportsContrast(_ displayID: CGDirectDisplayID) -> Bool {
        endpoint(for: displayID) != nil
    }

    static func isSupported(_ displayID: CGDirectDisplayID) -> Bool {
        endpoint(for: displayID) != nil || ioService(for: displayID) != nil
    }

    // MARK: - 缓存值（0…100，供场景比对）

    private static func brightnessKey(_ id: CGDirectDisplayID) -> String { "display.brightness.\(id)" }
    private static func contrastKey(_ id: CGDirectDisplayID) -> String { "display.contrast.\(id)" }

    /// 亮度缓存是 0…1 的小数（历史格式），对外统一换算成 0…100
    static func brightness(_ displayID: CGDirectDisplayID) -> Double {
        let fraction = UserDefaults.standard.object(forKey: brightnessKey(displayID)) as? Double ?? 0.72
        return fraction * 100
    }

    static func contrast(_ displayID: CGDirectDisplayID) -> Double {
        UserDefaults.standard.object(forKey: contrastKey(displayID)) as? Double ?? 50
    }

    // MARK: - 写入

    /// 亮度：0…100。外接屏 DDC，内置屏 IOKit。返回是否写成功
    @discardableResult
    static func setBrightness(_ percent: Double, on displayID: CGDirectDisplayID) -> Bool {
        let clamped = min(max(percent, 5), 100)
        UserDefaults.standard.set(clamped / 100, forKey: brightnessKey(displayID))
        return hardwareBrightness(clamped, on: displayID)
    }

    /// 对比度：0…100。仅外接屏；写失败返回 false（滑杆可回弹）
    @discardableResult
    static func setContrast(_ percent: Double, on displayID: CGDirectDisplayID) -> Bool {
        guard let endpoint = endpoint(for: displayID) else { return false }
        let clamped = min(max(percent, 0), 100)
        let ok = DDCTransport.shared?.write(endpoint, command: .contrast, percent: clamped / 100) ?? false
        if ok { UserDefaults.standard.set(clamped, forKey: contrastKey(displayID)) }
        return ok
    }

    /// 一次性写入一组场景值：先记账（滑杆/圆点/面板立刻跟上），硬件写入后台走——
    /// DDC 每笔有协议级等待（≥70ms），不能占着主线程让界面卡半秒
    @discardableResult
    static func apply(brightness: Double, contrast: Double, on displayID: CGDirectDisplayID) -> Bool {
        let b = min(max(brightness, 5), 100)
        let c = min(max(contrast, 0), 100)
        let supported = isSupported(displayID)
        UserDefaults.standard.set(b / 100, forKey: brightnessKey(displayID))
        if supportsContrast(displayID) {
            UserDefaults.standard.set(c, forKey: contrastKey(displayID))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = hardwareBrightness(b, on: displayID)
            if supportsContrast(displayID) {
                _ = hardwareContrast(c, on: displayID)
            }
        }
        return supported
    }

    // MARK: - 硬件写入（只说话，不记账；记账由调用方先行完成）

    private static func hardwareBrightness(_ clamped: Double, on displayID: CGDirectDisplayID) -> Bool {
        if let endpoint = endpoint(for: displayID) {
            return DDCTransport.shared?.write(endpoint, command: .brightness, percent: clamped / 100) ?? false
        }
        if let service = ioService(for: displayID) {
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString,
                                       Float32(clamped / 100))
            IOObjectRelease(service)
            return true
        }
        return false
    }

    private static func hardwareContrast(_ clamped: Double, on displayID: CGDirectDisplayID) -> Bool {
        guard let endpoint = endpoint(for: displayID) else { return false }
        return DDCTransport.shared?.write(endpoint, command: .contrast, percent: clamped / 100) ?? false
    }
}
