import CoreAudio
import Darwin
import Foundation

// TCC 探针：验证"读麦克风电平"是否触发 macOS 麦克风权限。
// 最权威的判定 = 在默认输入设备上创建并启动一个 IOProc（真实音频流），
// 若被 TCC 拦截（'!perm'）→ 任何需要真实电平的方案都违背零权限红线 → 电平表砍。
// 本探针不存储、不传输任何音频数据，启动 0.5 秒后立即停止。

var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var deviceID = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.stride)
let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
guard st == noErr, deviceID != 0 else { print("无默认输入设备"); exit(1) }
print("默认输入设备 AudioDeviceID=\(deviceID)")

var procID: AudioDeviceIOProcID?
let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, _, _, _, _ in }
print("创建 IOProc: \(createStatus == noErr ? "成功" : "失败 \(fourCC(createStatus))")")
guard createStatus == noErr, let procID else { exit(1) }

let startStatus = AudioDeviceStart(deviceID, procID)
print("启动输入流: \(startStatus == noErr ? "✓ 成功（未触发 TCC 麦克风权限 → 电平表可行）" : "✗ 被拦（\(fourCC(startStatus)) → 触发权限 → 电平表砍）")")

usleep(500_000)
AudioDeviceStop(deviceID, procID)
AudioDeviceDestroyIOProcID(deviceID, procID)
print("已停止并销毁，未读取任何音频内容")

func fourCC(_ code: OSStatus) -> String {
    let chars = [
        UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
    ]
    let readable = chars.allSatisfy { $0 >= 32 && $0 < 127 }
    return readable ? "'\(String(bytes: chars, encoding: .ascii)!)' (\(code))" : "\(code)"
}
