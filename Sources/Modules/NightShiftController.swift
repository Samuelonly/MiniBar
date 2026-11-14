import Foundation
import Darwin

/// 夜览模式控制器（PRD §9-3 已批准私有 API，不上架 App Store）。
/// 走私有 CoreBrightness 框架的 CBBlueLightClient（纯 ObjC runtime 调用）。
/// 方法集与状态布局参考开源 brightness-cli 的 NightShiftService：
/// getBlueLightStatus: 填充的 C 结构体首两字节为 (active, enabled)，
/// enabled = 功能已开启（可能在排程外暂未生效），active = 正在施加色温。
final class NightShiftController {
    private let client: NSObject

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                     RTLD_LAZY) != nil,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        // +supportsBlueLightReduction 返回 BOOL，经 perform 桥接在指针低位
        let supportsSelector = Selector(("supportsBlueLightReduction"))
        if cls.responds(to: supportsSelector) {
            let supported = unsafeBitCast(cls.perform(supportsSelector), to: Int.self)
            if supported == 0 { return nil }
        }
        client = cls.init()
    }

    var isEnabled: Bool {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64,
                                                      alignment: MemoryLayout<Int>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        typealias GetStatusIMP = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
        let selector = Selector(("getBlueLightStatus:"))
        guard client.responds(to: selector) else { return false }
        let getStatus = unsafeBitCast(client.method(for: selector), to: GetStatusIMP.self)
        guard getStatus(client, selector, buffer) else { return false }
        return buffer.load(fromByteOffset: 1, as: Bool.self)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        typealias SetEnabledIMP = @convention(c) (NSObject, Selector, Bool) -> Bool
        let selector = Selector(("setEnabled:"))
        guard client.responds(to: selector) else { return false }
        let setEnabled = unsafeBitCast(client.method(for: selector), to: SetEnabledIMP.self)
        return setEnabled(client, selector, enabled)
    }

    /// 夜览强度 0~1；开关切换保持系统当前强度设定，不覆盖
    @discardableResult
    func setStrength(_ strength: Float) -> Bool {
        typealias SetStrengthIMP = @convention(c) (NSObject, Selector, Float, Bool) -> Bool
        let selector = Selector(("setStrength:commit:"))
        guard client.responds(to: selector) else { return false }
        let setStrength = unsafeBitCast(client.method(for: selector), to: SetStrengthIMP.self)
        return setStrength(client, selector, strength, true)
    }
}
