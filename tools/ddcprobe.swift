import CoreGraphics
import Darwin
import Foundation
import IOKit

// 一次性诊断工具：读取外接显示器的 DDC Capabilities String（VESA DDC/CI 能力清单）。
// 只读操作，不修改任何显示器状态。用于 1.0.1 显示器预设模式的 Plan A/B 决策。

typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

guard let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
      let c = dlsym(ioKit, "IOAVServiceCreateWithService"),
      let r = dlsym(ioKit, "IOAVServiceReadI2C"),
      let w = dlsym(ioKit, "IOAVServiceWriteI2C") else {
    print("FATAL: IOKit dlopen/dlsym failed"); exit(1)
}
let create = unsafeBitCast(c, to: Create.self)
let read = unsafeBitCast(r, to: Transfer.self)
let write = unsafeBitCast(w, to: Transfer.self)

// 实验模式：./ddcprobe exp → 向 0x14 写 0 观察画面，随后立刻写回原值
let experiment = CommandLine.arguments.contains("exp")

var iterator: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
    print("FATAL: enumeration failed"); exit(1)
}
defer { IOObjectRelease(iterator) }

/// 读 Capabilities String：请求包 [0x84,0x03,0xF3,off_hi,off_lo]+校验，分段回读
func readCapabilities(_ service: CFTypeRef, chip: UInt32) -> String? {
    var result = ""
    var offset: UInt16 = 0
    for _ in 0..<12 {
        var packet: [UInt8] = [0x84, 0x03, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)]
        packet.append(packet.reduce(UInt8(0x6E ^ 0x51), ^))
        var sent = false
        for _ in 0..<2 {
            usleep(10_000)
            let ok = packet.withUnsafeMutableBytes { raw in
                write(service, chip, 0x51, raw.baseAddress!, UInt32(raw.count)) == kIOReturnSuccess
            }
            if ok { sent = true; break }
        }
        guard sent else { return result.isEmpty ? nil : result }

        usleep(60_000)
        var reply = [UInt8](repeating: 0, count: 38)
        let replyCount = UInt32(reply.count)
        let rc = reply.withUnsafeMutableBytes { raw in
            read(service, chip, 0, raw.baseAddress!, replyCount)
        }
        let nonzero = (0..<reply.count).reversed().first(where: { reply[$0] != 0 }).map { $0 + 1 } ?? 0
        let dump = reply[0..<max(nonzero, 0)].map { String(format: "%02x", $0) }.joined(separator: " ")
        print("    raw rc=\(rc) bytes[\(nonzero)]: \(dump)")

        guard rc == kIOReturnSuccess,
              reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x03, reply[3] == 0, reply[4] == 0xF3 else { continue }

        guard let end = (0..<reply.count).reversed().first(where: { reply[$0] != 0 }), end > 8 else { continue }
        let xor = reply[0..<end].reduce(UInt8(0x50), ^)
        guard xor == reply[end] else { continue }

        let resultCode = reply[5]
        let chunk = String(bytes: reply[8..<end], encoding: .ascii) ?? ""
        result += chunk
        if resultCode == 0x02 || resultCode == 0x00 { return result } // 回读完成
        offset += UInt16(chunk.utf8.count)
    }
    return result.isEmpty ? nil : result
}

var index = 0
while case let proxy = IOIteratorNext(iterator), proxy != 0 {
    defer { IOObjectRelease(proxy) }
    index += 1
    let location = IORegistryEntryCreateCFProperty(proxy, "Location" as CFString, nil, 0)?
        .takeRetainedValue() as? String ?? "<nil>"
    guard location == "External" else { continue }
    var provider = "<nil>"
    var chip: UInt32 = 0x37
    var parent: io_object_t = 0
    if IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS {
        defer { IOObjectRelease(parent) }
        provider = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, nil, 0)?
            .takeRetainedValue() as? String ?? "<nil>"
        if provider == "AppleDCPMCDP29XX" { chip = 0xB7 }
    }
    print("== 外接屏 #\(index) provider=\(provider) chip=0x\(String(chip, radix: 16)) ==")

    guard let service = create(nil, proxy)?.takeRetainedValue() else {
        print("  IOAVServiceCreateWithService 失败"); continue
    }

    var edid = [UInt8](repeating: 0, count: 128)
    _ = edid.withUnsafeMutableBytes { raw in read(service, 0x50, 0, raw.baseAddress!, 128) }
    let vendor = String(format: "%02X%02X", edid[8], edid[9])
    let product = Int(edid[10]) | Int(edid[11]) << 8
    print("  EDID vendor=\(vendor) product=\(product)")

    guard let caps = readCapabilities(service, chip: chip) else {
        print("  Capabilities String 读取失败 → 改用 VCP 码逐个试探（只读，安全）")

        // 逐码发 Get VCP（[0x82,0x01,code]+校验），看哪些码有合法回声
        let candidates: [(UInt8, String)] = [
            (0x10, "亮度"), (0x12, "对比度"), (0x6C, "视频黑位?"), (0x62, "音频喇叭?"),
            (0x68, "Gamma/模式?"), (0xE2, "厂商池?"), (0xF4, "厂商池?"), (0x14, "画面效果?"),
            (0x00, "厂商池0?"), (0xB0, "厂商池B0?"), (0xD6, "电源模式"), (0xAC, "水平后延?"),
        ]
        for (code, name) in candidates {
            var packet: [UInt8] = [0x82, 0x01, code]
            packet.append(packet.reduce(UInt8(0x6E), ^))
            var got: (UInt16, UInt16)? = nil
            for _ in 0..<3 {
                var sentOK = false
                for _ in 0..<2 {
                    usleep(10_000)
                    let ok = packet.withUnsafeMutableBytes { raw in
                        write(service, chip, 0x51, raw.baseAddress!, UInt32(raw.count)) == kIOReturnSuccess
                    }
                    if ok { sentOK = true; break }
                }
                guard sentOK else { break }
                usleep(chip == 0xB7 ? 100_000 : 50_000)
                var reply = [UInt8](repeating: 0, count: 11)
                let replyCount = UInt32(reply.count)
                let rc = reply.withUnsafeMutableBytes { raw in
                    read(service, chip, 0, raw.baseAddress!, replyCount)
                }
                guard rc == kIOReturnSuccess, reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02,
                      reply[3] == 0, reply[4] == code, reply[5] == 0,
                      reply.prefix(11).reduce(UInt8(0x50), ^) == 0 else { continue }
                let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
                let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
                guard maximum > 0, current <= maximum else { continue }
                got = (maximum, current)
                break
            }
            if let (maximum, current) = got {
                print(String(format: "    VCP 0x%02X (%@): ✓ 当前=%d 范围=0~%d", code, name, current, maximum))
                if code == 0x14 {
                    // 写通道验证：把当前值原样写回（值不变 → 屏幕必然无任何可见变化），再读一次确认
                    var wp: [UInt8] = [0x84, 0x03, 0x14, UInt8(current >> 8), UInt8(current & 0xFF)]
                    wp.append(wp.reduce(UInt8(0x6E ^ 0x51), ^))
                    var writeOK = false
                    for _ in 0..<2 {
                        usleep(10_000)
                        if wp.withUnsafeMutableBytes({ raw in
                            write(service, chip, 0x51, raw.baseAddress!, UInt32(raw.count)) == kIOReturnSuccess
                        }) { writeOK = true; break }
                    }
                    usleep(100_000)
                    print("    0x14 写通道验证（原值写回，零可见变化）: \(writeOK ? "写入完成，可再跑一次本工具确认值未漂移" : "✗ 写失败")")
                    if experiment && writeOK {
                        // 语义实验：写 0 → 读回 → 写回原值 → 复读
                        var zero: [UInt8] = [0x84, 0x03, 0x14, 0, 0]
                        zero.append(zero.reduce(UInt8(0x6E ^ 0x51), ^))
                        let sent = zero.withUnsafeMutableBytes { raw in
                            write(service, chip, 0x51, raw.baseAddress!, UInt32(raw.count)) == kIOReturnSuccess
                        }
                        usleep(300_000)
                        print("    [实验] 已向 0x14 写入 0（\(sent ? "发送成功" : "发送失败")）——请观察屏幕画面模式是否变化")
                        // 立刻恢复原值
                        var back: [UInt8] = [0x84, 0x03, 0x14, UInt8(current >> 8), UInt8(current & 0xFF)]
                        back.append(back.reduce(UInt8(0x6E ^ 0x51), ^))
                        _ = back.withUnsafeMutableBytes { raw in
                            write(service, chip, 0x51, raw.baseAddress!, UInt32(raw.count)) == kIOReturnSuccess
                        }
                        usleep(300_000)
                        print("    [实验] 已写回原值 \(current)")
                    }
                }
            } else {
                print(String(format: "    VCP 0x%02X (%@): ✗ 无回声", code, name))
            }
        }
        continue
    }
    print("  CAPS: \(caps)")
}
