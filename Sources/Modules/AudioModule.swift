import AppKit
import CoreAudio

/// 音频路由模块（PRD §3.4）：全局静音 + 扬声器/麦克风子菜单切换。
/// 纯公开 CoreAudio API，零权限。
final class AudioModule: NSObject, MiniBarModule {
    var name: String { "audio" }

    func activate() {}
    func deactivate() {}

    // MARK: - CoreAudio 基础封装

    private func propertyAddress(_ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func propertySize(_ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                              object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject)) -> UInt32 {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        return size
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size = propertySize(kAudioHardwarePropertyDevices)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids
    }

    private func deviceName(_ id: AudioDeviceID) -> String {
        var address = propertyAddress(kAudioObjectPropertyName)
        var size = max(propertySize(kAudioObjectPropertyName, object: id),
                       UInt32(MemoryLayout<CFString?>.stride))
        var name: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let string = name?.takeRetainedValue() else { return "未知设备" }
        return string as String
    }

    private func transportLabel(_ id: AudioDeviceID) -> String {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var size = propertySize(kAudioDevicePropertyTransportType, object: id)
        var value: UInt32 = 0
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "内建"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "蓝牙"
        case kAudioDeviceTransportTypeAirPlay: return "隔空播放"
        default: return "其他"
        }
    }

    private func deviceHasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        propertySize(kAudioDevicePropertyStreams, scope: scope, object: id) > 0
    }

    private func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = propertyAddress(selector)
        var size = propertySize(selector)
        var id = AudioDeviceID(0)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private func setDefaultDevice(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) {
        var address = propertyAddress(selector)
        var deviceID = id
        var size = UInt32(MemoryLayout<AudioDeviceID>.stride)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &deviceID)
    }

    // MARK: - 静音

    private var isMuted: Bool {
        let device = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
        var address = propertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        var size = propertySize(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, object: device)
        guard size >= 4 else { return false }
        var value: UInt32 = 0
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value != 0
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        let device = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
        var value: UInt32 = isMuted ? 0 : 1
        var address = propertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        let size = UInt32(MemoryLayout<UInt32>.stride)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        sender.state = value == 1 ? .on : .off
        // 图标双态：静音喇叭 ↔ 有声喇叭（PRD §3.4）
        sender.image = NSImage(systemSymbolName: value == 1 ? "speaker.slash" : "speaker.wave.2",
                               accessibilityDescription: nil)
    }

    // MARK: - 设备切换

    @objc private func switchOutput(_ sender: NSMenuItem) {
        guard let meta = sender.representedObject as? MenuRowMeta,
              let number = meta.payload as? NSNumber else { return }
        setDefaultDevice(AudioDeviceID(number.uint32Value),
                         selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    @objc private func switchInput(_ sender: NSMenuItem) {
        guard let meta = sender.representedObject as? MenuRowMeta,
              let number = meta.payload as? NSNumber else { return }
        setDefaultDevice(AudioDeviceID(number.uint32Value),
                         selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func deviceSubmenu(_ devices: [AudioDeviceInfo], defaultID: AudioDeviceID,
                               input: Bool, action: Selector) -> NSMenu? {
        guard !devices.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for device in devices {
            // HTML .child-row：扬声器子行带 13px 图标，麦克风子行无图标；
            // 传输方式是独立的 .tag 角标（10px 等宽、1px 描边），不再拼进标题。
            let symbol = input
                ? ""
                : DeviceIcons.audioOutput(transport: device.transport, name: device.name)
            let item = menuItem(middleTruncate(device.name),
                                symbol: symbol, action: action, target: self,
                                state: device.id == defaultID ? .on : .off,
                                rep: MenuRowMeta(caption: device.transport,
                                                 payload: NSNumber(value: device.id)))
            item.toolTip = device.name
            menu.addItem(item)
        }
        return menu
    }

    private struct AudioDeviceInfo {
        let id: AudioDeviceID
        let name: String
        let transport: String
        let hasInput: Bool
        let hasOutput: Bool
    }

    private func enumerateDevices() -> [AudioDeviceInfo] {
        allDeviceIDs().map { id in
            AudioDeviceInfo(id: id,
                            name: deviceName(id),
                            transport: transportLabel(id),
                            hasInput: deviceHasStreams(id, scope: kAudioObjectPropertyScopeInput),
                            hasOutput: deviceHasStreams(id, scope: kAudioObjectPropertyScopeOutput))
        }
    }

    // MARK: - 菜单片段

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }
        let devices = enumerateDevices()
        let outputDefault = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
        let inputDefault = defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)

        var items = [sectionHeader(L("menu.section.audio"))]
        let mute = menuItem(L("menu.audio.mute"),
                            symbol: isMuted ? "speaker.slash" : "speaker.wave.2",
                            action: #selector(toggleMute(_:)), target: self,
                            state: isMuted ? .on : .off)
        mute.identifier = NSUserInterfaceItemIdentifier("minibar.switch")
        items.append(mute)

        if let speakers = deviceSubmenu(devices.filter(\.hasOutput), defaultID: outputDefault,
                                        input: false, action: #selector(switchOutput(_:))) {
            items.append(menuItem(L("menu.audio.speakers"), symbol: "hifispeaker", submenu: speakers))
        }
        if let microphones = deviceSubmenu(devices.filter(\.hasInput), defaultID: inputDefault,
                                           input: true, action: #selector(switchInput(_:))) {
            // HTML：输入电平是麦克风浮层的最后一行（只读，无开关）
            let level = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            level.identifier = NSUserInterfaceItemIdentifier("minibar.micLevel")
            microphones.addItem(level)
            items.append(menuItem(L("menu.audio.microphones"), symbol: "mic", submenu: microphones))
        }
        return items
    }
}

// MARK: - 麦克风电平监视器
//
// 只读电平，不存储、不传输任何音频数据（零权限红线）。
// 真机 tools/micprobe.swift 已验证：在默认输入设备上创建并启动 IOProc 不触发 TCC。
extension Notification.Name {
    /// 电平变化，object = Float（0~1 峰值）
    static let micLevelDidChange = Notification.Name("minibar.micLevelDidChange")
}

final class MicLevelMonitor {
    static let shared = MicLevelMonitor()
    private init() {}

    private var ioProcID: AudioDeviceIOProcID?
    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var format = AudioStreamBasicDescription()
    private var running = false
    /// 音频线程侧节流：~16Hz 足够驱动 8 格电平表，也避免主线程被通知打爆
    private var lastPost: TimeInterval = 0

    var isRunning: Bool { running }

    func start() {
        guard !running, let input = Self.defaultInputDevice() else { return }
        deviceID = input
        format = Self.streamFormat(of: input)

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, input, nil) { [weak self] _, inputList, _, _, _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastPost >= 0.06 else { return }
            self.lastPost = now
            let peak = self.peakLevel(of: inputList)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .micLevelDidChange, object: peak)
            }
        }
        guard status == noErr, let proc else { return }
        guard AudioDeviceStart(input, proc) == noErr else {
            AudioDeviceDestroyIOProcID(input, proc)
            return
        }
        ioProcID = proc
        running = true
    }

    func stop() {
        guard running, let proc = ioProcID else { return }
        AudioDeviceStop(deviceID, proc)
        AudioDeviceDestroyIOProcID(deviceID, proc)
        ioProcID = nil
        deviceID = kAudioObjectUnknown
        running = false
        lastPost = 0
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .micLevelDidChange, object: Float(0))
        }
    }

    // MARK: 取值

    private func peakLevel(of list: UnsafePointer<AudioBufferList>) -> Float {
        // IOProc 给的就是设备流格式；线性 PCM 之外（压缩格式）没有样本可读
        guard format.mFormatID == kAudioFormatLinearPCM else { return 0 }
        let bits = Int(format.mBitsPerChannel)
        guard bits >= 8, bits % 8 == 0 else { return 0 }
        let bytesPerSample = bits / 8

        var peak: Float = 0
        // Swift 只提供 UnsafeMutableAudioBufferListPointer，这里只读不写，
        // 用 mutating 转换借用一下 const 指针（IOProc 回调里没有别的安全写法）
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let count = Int(buffer.mDataByteSize) / bytesPerSample
            guard count > 0 else { continue }
            switch bits {
            case 32:
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<count {
                    let v = abs(samples[i])
                    if v > peak { peak = v }
                }
            case 16:
                let samples = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<count {
                    let v = abs(Float(samples[i]) / 32768)
                    if v > peak { peak = v }
                }
            default:
                return 0
            }
        }
        return min(peak, 1)
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func streamFormat(of device: AudioDeviceID) -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format) == noErr else {
            return AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1,
                                               mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 32, mReserved: 0)
        }
        return format
    }
}
