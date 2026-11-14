import AppKit
import CoreGraphics

for screen in NSScreen.screens {
    guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
    let mode = CGDisplayCopyDisplayMode(displayID)
    let logical = "\(mode?.width ?? 0)x\(mode?.height ?? 0)"
    let pixel = "\(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0)"
    let scale = screen.backingScaleFactor
    let builtin = CGDisplayIsBuiltin(displayID) != 0
    let hidpi = scale > 1.5
    print("\(builtin ? "内置屏" : "外接屏") \(screen.localizedName)")
    print("  逻辑分辨率=\(logical)  像素分辨率=\(pixel)  backingScale=\(scale)")
    print("  HiDPI: \(hidpi ? "✓ 已开启（Scaled 缩放模式）" : "✗ 未开启（原生 1:1）")")
}
