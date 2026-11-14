import AppKit

// MiniBar — Mac mini 极简状态控制台
// 菜单栏常驻（LSUIElement），纯遥控器模式，零辅助功能权限（PRD §1/§2）

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
