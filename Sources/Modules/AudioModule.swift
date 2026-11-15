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
    }

    // MARK: - 设备切换

    @objc private func switchOutput(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        setDefaultDevice(AudioDeviceID(number.uint32Value),
                         selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    @objc private func switchInput(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        setDefaultDevice(AudioDeviceID(number.uint32Value),
                         selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func deviceSubmenu(_ devices: [AudioDeviceInfo], defaultID: AudioDeviceID,
                               input: Bool, action: Selector) -> NSMenu? {
        guard !devices.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for device in devices {
            // PRD §3.4：设备图标按类型归类（iPad/蓝牙耳机/有线耳机/内建/HDMI/USB/隔空播放）
            let symbol = input
                ? DeviceIcons.audioInput(transport: device.transport, name: device.name)
                : DeviceIcons.audioOutput(transport: device.transport, name: device.name)
            let item = menuItem("\(middleTruncate(device.name)) · \(device.transport)",
                                symbol: symbol, action: action, target: self,
                                state: device.id == defaultID ? .on : .off,
                                rep: NSNumber(value: device.id))
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
        let mute = menuItem(L("menu.audio.mute"), symbol: "speaker.slash",
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
            items.append(menuItem(L("menu.audio.microphones"), symbol: "mic", submenu: microphones))
        }
        return items
    }
}
