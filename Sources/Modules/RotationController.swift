import AppKit
import CoreGraphics
import Darwin

/// 屏幕旋转控制器（PRD §9-3 已批准私有 API，不上架 App Store）。
/// 走私有 MonitorPanel 框架的 MPDisplay（class-dump 头参考 displayplacer 内嵌版本）：
/// -initWithCGSDisplayID: + setOrientation:（0/90/180/270）+ canChangeOrientation。
final class RotationController {
    static let shared = RotationController()

    private var frameworkLoaded = false

    private func makeDisplay(_ displayID: CGDirectDisplayID) -> NSObject? {
        if !frameworkLoaded {
            guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel",
                         RTLD_LAZY) != nil else { return nil }
            frameworkLoaded = true
        }
        guard let cls = NSClassFromString("MPDisplay") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("initWithCGSDisplayID:")
        guard cls.instancesRespond(to: selector) else { return nil }
        // Swift 禁用 alloc()，走 ObjC runtime perform
        guard let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else { return nil }
        typealias InitIMP = @convention(c) (NSObject, Selector, Int32) -> NSObject?
        let initializer = unsafeBitCast(allocated.method(for: selector), to: InitIMP.self)
        return initializer(allocated, selector, Int32(displayID))
    }

    private func canChangeOrientation(_ display: NSObject) -> Bool {
        let selector = NSSelectorFromString("canChangeOrientation")
        guard display.responds(to: selector) else { return false }
        typealias CanIMP = @convention(c) (NSObject, Selector) -> Bool
        let imp = unsafeBitCast(display.method(for: selector), to: CanIMP.self)
        return imp(display, selector)
    }

    /// 当前鼠标屏是否支持旋转
    func isSupported(_ displayID: CGDirectDisplayID) -> Bool {
        guard let display = makeDisplay(displayID) else { return false }
        return canChangeOrientation(display)
    }

    /// 当前旋转角（0/90/180/270），取不到返回 0
    func currentRotation(_ displayID: CGDirectDisplayID) -> Int32 {
        guard let display = makeDisplay(displayID) else { return 0 }
        let selector = NSSelectorFromString("orientation")
        guard display.responds(to: selector) else { return 0 }
        typealias GetIMP = @convention(c) (NSObject, Selector) -> Int32
        let imp = unsafeBitCast(display.method(for: selector), to: GetIMP.self)
        return imp(display, selector)
    }

    /// 旋转并等待硬件完成（displayplacer 同款轮询，10 秒上限）
    @discardableResult
    func rotate(_ displayID: CGDirectDisplayID, to degree: Int32) -> Bool {
        guard [0, 90, 180, 270].contains(degree),
              let display = makeDisplay(displayID),
              canChangeOrientation(display) else { return false }
        let selector = NSSelectorFromString("setOrientation:")
        guard display.responds(to: selector) else { return false }
        typealias SetIMP = @convention(c) (NSObject, Selector, Int32) -> Void
        let imp = unsafeBitCast(display.method(for: selector), to: SetIMP.self)
        imp(display, selector, degree)
        let deadline = Date().addingTimeInterval(10)
        while CGDisplayRotation(displayID) != CGFloat(degree) {
            if Date() > deadline { return false }
            usleep(100_000)
        }
        return true
    }
}
