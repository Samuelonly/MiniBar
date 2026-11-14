import AppKit
import CoreGraphics

/// 自适应显示模块（1.0.1 §12.2 定案：与其让用户选预设，不如让用户不用选。
/// "他现在不需要知道为什么他的屏幕亮度产生了变化。"）
///
/// 规则引擎：识别前台 App 类别 → 应用对应显示预设；回到普通 App 自动还原基线。
/// 检测方式：NSWorkspace 前台切换通知（公开 API，零权限，非全局事件监听）。
/// 与夜览不冲突：夜览是色温层（叠加），本模块动的是背光层（亮度），不同维度可共存。
final class AdaptiveModule: NSObject, MiniBarModule {
    var name: String { "adaptive" }

    private var observer: NSObjectProtocol?
    private var endpoints: [DDCTransport.Endpoint] = []
    private var baseline: Double = 0.72
    private var appliedMedia = false

    /// 媒体播放器识别（按 bundle id 关键词，持续可扩充）
    private let mediaHints = ["iina", "vlc", "mpv", "quicktime", "infuse", "potplayer", "movist", "elmedia"]

    func activate() {
        guard observer == nil else { return }
        endpoints = DDCTransport.shared?.endpoints() ?? []
        // 基线：激活时的当前亮度（TODO 1.0.1: 用户手动拖滑杆时同步基线）
        baseline = UserDefaults.standard.object(forKey: "display.brightness") as? Double ?? 0.72
        observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyForFrontmost()
        }
    }

    func deactivate() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        endpoints.removeAll()
        appliedMedia = false
    }

    private func currentDisplayID() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func endpoint(for displayID: CGDirectDisplayID) -> DDCTransport.Endpoint? {
        let identity = DDCTransport.Identity(vendor: CGDisplayVendorNumber(displayID),
                                             product: CGDisplayModelNumber(displayID),
                                             serial: CGDisplaySerialNumber(displayID))
        return endpoints.first { $0.identity == identity }
    }

    private func applyBrightness(_ percent: Double) {
        guard let displayID = currentDisplayID(),
              let endpoint = endpoint(for: displayID) else { return }
        _ = DDCTransport.shared?.write(endpoint, command: .brightness, percent: percent)
        UserDefaults.standard.set(percent, forKey: "display.brightness")
    }

    private func applyForFrontmost() {
        guard isEnabled(self), let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundle = (app.bundleIdentifier ?? "").lowercased()
        let isMedia = mediaHints.contains { bundle.contains($0) }

        if isMedia, !appliedMedia {
            // 播放器打开 → 自动提亮（基线 × 1.2，封顶 1.0）
            appliedMedia = true
            applyBrightness(min(1.0, baseline * 1.2))
        } else if !isMedia, appliedMedia {
            // 回到普通 App → 还原基线
            appliedMedia = false
            applyBrightness(baseline)
        }
    }

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }
        let item = menuItem("自适应显示", symbol: "wand.and.stars",
                            action: #selector(toggleAdaptive(_:)), target: self,
                            state: appliedMedia ? .on : .off)
        item.toolTip = "播放器打开自动提亮，回桌面自动还原"
        return [sectionHeader("自适应"),
                item,
                menuItem("以当前亮度为新基线", symbol: "bookmark",
                         action: #selector(rebaseline(_:)), target: self)]
    }

    @objc private func toggleAdaptive(_ sender: NSMenuItem) {
        appliedMedia.toggle()
        sender.state = appliedMedia ? .on : .off
    }

    @objc private func rebaseline(_ sender: NSMenuItem) {
        guard let displayID = currentDisplayID(),
              let endpoint = endpoint(for: displayID),
              let reading = DDCTransport.shared?.read(endpoint, command: .brightness) else { return }
        baseline = Double(reading.current) / Double(max(reading.max, 1))
        UserDefaults.standard.set(baseline, forKey: "adaptive.baseline")
        sender.state = .on
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { sender.state = .off }
    }
}
