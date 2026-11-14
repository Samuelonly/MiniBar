import AppKit

/// 设备图标映射库（PRD §3.4/§3.5）：
/// 统一使用 SF Symbols 单色 Template——原生、跟系统外观、零第三方依赖。
/// 规则：按传输类型 + 设备名归类（iPad / AirPods / 有线耳机 / 内建 / HDMI / USB / 隔空播放），
/// 各模块禁止自造图标，一律走这里。
enum DeviceIcons {
    // MARK: - 音频输出

    static func audioOutput(transport: String, name: String) -> String {
        let n = name.lowercased()
        if n.contains("ipad") { return "ipad" }                       // iPad 作为输出（隔空播放/Sidecar）
        if transport == "蓝牙" {
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return "airpods" }
            if n.contains("buds") { return "earbuds" }
            return "headphones"
        }
        if n.contains("headphone") || n.contains("耳机") { return "headphones" } // 3.5mm 有线耳机常报 Headphones
        if n.contains("buds") { return "earbuds" }
        switch transport {
        case "内建":
            return n.contains("mini") ? "hifispeaker.2" : "hifispeaker" // Mac mini 内建喇叭 vs MacBook 内建
        case "HDMI", "雷电":
            return "tv"                                                  // 显示器喇叭
        case "隔空播放":
            return n.contains("homepod") ? "hifispeaker.2" : "airplayaudio"
        default:
            return "hifispeaker"                                         // USB 声卡 / 外置音箱
        }
    }

    // MARK: - 音频输入

    static func audioInput(transport: String, name: String) -> String {
        let n = name.lowercased()
        if n.contains("ipad") { return "ipad" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("headphone") { return "headphones" }
        if n.contains("usb") || transport == "USB" { return "mic" }
        return "mic"
    }

    // MARK: - 存储

    static func storage(name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("ssd") { return "externaldrive.fill" }
        if n.contains("hdd") || n.contains("机械") { return "internaldrive" }
        return "externaldrive"
    }
}
