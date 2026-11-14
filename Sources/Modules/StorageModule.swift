import AppKit
import DiskArbitration

/// 存储管理模块（PRD §3.5/§4）：
/// 文案用"安全弹出"，底层动作是 diskutil unmount（绝不带 force），不物理断电。
/// 仅识别 USB / Thunderbolt 物理外接盘，自动过滤 DMG 与网络盘。
final class StorageModule: NSObject, MiniBarModule {
    var name: String { "storage" }

    private var session: DASession?
    /// 本会话内弹出的盘（BSD unit），供 ↻ 重新挂载
    private var ejectedUnits: [String] = []

    func activate() {
        if session == nil { session = DASessionCreate(kCFAllocatorDefault) }
    }

    func deactivate() {
        session = nil
        ejectedUnits.removeAll()
    }

    private struct MountedDisk {
        let name: String
        let size: Int64
        let unit: String
        let mountPath: String
    }

    private func mountedDisks() -> [MountedDisk] {
        guard let session else { return [] }
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return volumes.compactMap { url in
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  let isInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
                  !isInternal,
                  let isNetwork = description[kDADiskDescriptionVolumeNetworkKey as String] as? Bool,
                  !isNetwork else { return nil }
            // BusType 键已在 macOS 27 SDK 移除，用 BusName + DeviceProtocol 双重识别（PRD §4：仅 USB / Thunderbolt）
            let bus = description[kDADiskDescriptionBusNameKey as String] as? String ?? ""
            let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
            guard bus.contains("USB") || bus.contains("Thunderbolt")
                    || transport.contains("USB") || transport.contains("Thunderbolt") else { return nil }
            let unitNumber = (description[kDADiskDescriptionMediaBSDUnitKey as String] as? NSNumber)?.intValue ?? 0
            return MountedDisk(
                name: description[kDADiskDescriptionMediaNameKey as String] as? String ?? url.lastPathComponent,
                size: (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0,
                unit: "disk\(unitNumber)",
                mountPath: url.path)
        }
    }

    /// 仅卸载，绝不带 force（PRD §4）；有占用则拒绝并提示（kDAReturnBusy 场景）
    @objc private func ejectDisk(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        if runCommand("/usr/sbin/diskutil", ["unmount", path]) == 0 {
            if let disk = mountedDisks().first(where: { $0.mountPath == path }) {
                ejectedUnits.append(disk.unit)
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "无法安全弹出"
            alert.informativeText = "有文件正被占用，请先关闭正在使用该盘的程序再试。"
            alert.runModal()
        }
    }

    @objc private func ejectAllDisks() {
        for disk in mountedDisks() {
            if runCommand("/usr/sbin/diskutil", ["unmount", disk.mountPath]) == 0 {
                ejectedUnits.append(disk.unit)
            }
        }
    }

    /// 重新挂载：无需拔插 Hub 线缆（PRD §4 恢复机制）
    /// TODO(1.0): 扫描 diskutil list 以发现 App 启动前就已弹出的盘
    @objc private func mountDisk(_ sender: NSMenuItem) {
        guard let unit = sender.representedObject as? String else { return }
        runCommand("/usr/sbin/diskutil", ["mountDisk", "/dev/\(unit)"])
        ejectedUnits.removeAll { $0 == unit }
    }

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }
        var items = [sectionHeader("存储")]
        let formatter = ByteCountFormatter()

        for disk in mountedDisks() {
            let item = NSMenuItem(title: "\(disk.name) · \(formatter.string(fromByteCount: disk.size))",
                                  action: #selector(ejectDisk(_:)), keyEquivalent: "")
            // PRD §3.5：按设备身份选图标（iPhone/SSD/机械盘/通用外接盘）
            item.image = NSImage(systemSymbolName: DeviceIcons.storage(name: disk.name),
                                 accessibilityDescription: disk.name)
            item.target = self
            item.representedObject = disk.mountPath
            item.toolTip = "安全弹出（不断电，可随时重新挂载）"
            items.append(item)
        }

        for unit in ejectedUnits {
            let item = NSMenuItem(title: "已弹出 · \(unit)",
                                  action: #selector(mountDisk(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新挂载")
            item.target = self
            item.representedObject = unit
            item.toolTip = "重新挂载"
            items.append(item)
        }

        if items.count > 1 {
            items.append(menuItem("安全弹出全部", symbol: "eject",
                                  action: #selector(ejectAllDisks), target: self))
        } else {
            let empty = NSMenuItem(title: "没有外接硬盘", action: nil, keyEquivalent: "")
            empty.image = NSImage(systemSymbolName: "externaldrive.badge.minus", accessibilityDescription: nil)
            items.append(empty)
        }
        return items
    }
}
