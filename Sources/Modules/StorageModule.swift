import AppKit
import DiskArbitration

/// 存储管理模块（PRD §3.5/§4）：
/// 文案用"安全弹出"，底层动作是 diskutil unmount（绝不带 force），不物理断电。
/// 仅识别 USB / Thunderbolt 物理外接盘，自动过滤 DMG 与网络盘。
final class StorageModule: NSObject, MiniBarModule {
    var name: String { "storage" }

    private var session: DASession?
    /// 本会话内弹出的盘（BSD unit + 盘名 + 容量），供 ↻ 重新挂载；不向用户暴露 diskN 设备号
    private var ejectedUnits: [(unit: String, name: String, size: Int64)] = []

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
        let freeSize: Int64
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
            let bus = description[kDADiskDescriptionBusNameKey as String] as? String ?? ""
            let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
            guard bus.contains("USB") || bus.contains("Thunderbolt")
                    || transport.contains("USB") || transport.contains("Thunderbolt") else { return nil }
            let unitNumber = (description[kDADiskDescriptionMediaBSDUnitKey as String] as? NSNumber)?.intValue ?? 0

            // 读取已用空间（filesystem 级，比 MediaSizeKey 准）
            var free: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
               let freeNum = attrs[.systemFreeSize] as? NSNumber {
                free = freeNum.int64Value
            }
            let total = (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0

            return MountedDisk(
                name: description[kDADiskDescriptionMediaNameKey as String] as? String ?? url.lastPathComponent,
                size: total,
                freeSize: free,
                unit: "disk\(unitNumber)",
                mountPath: url.path)
        }
    }

    /// 仅卸载，绝不带 force（PRD §4）；有占用则拒绝并提示（kDAReturnBusy 场景）
    @objc private func ejectDisk(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? MenuRowMeta,
              let mountPath = path.payload as? String else { return }
        if runCommand("/usr/sbin/diskutil", ["unmount", mountPath]) == 0 {
            if let disk = mountedDisks().first(where: { $0.mountPath == mountPath }) {
                ejectedUnits.append((disk.unit, disk.name, disk.size))
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
                ejectedUnits.append((disk.unit, disk.name, disk.size))
            }
        }
    }

    /// 重新挂载：无需拔插 Hub 线缆（PRD §4 恢复机制）
    /// TODO(1.0): 扫描 diskutil list 以发现 App 启动前就已弹出的盘
    @objc private func mountDisk(_ sender: NSMenuItem) {
        guard let meta = sender.representedObject as? MenuRowMeta,
              let unit = meta.payload as? String else { return }
        runCommand("/usr/sbin/diskutil", ["mountDisk", "/dev/\(unit)"])
        ejectedUnits.removeAll { $0.unit == unit }
    }

    /// 十进制容量（1000 进制）：1024GB → 1TB（对齐硬盘销售口径）
    private func capFormatter() -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.includesUnit = true
        return f
    }

    /// 十进制 + 去空格：1TB / 910GB
    private func capacity(_ bytes: Int64) -> String {
        capFormatter().string(fromByteCount: bytes).replacingOccurrences(of: " ", with: "")
    }

    /// 已用空间：用了 / 总量 → "910GB/1TB"
    private func usedString(disk: MountedDisk) -> String {
        let used = max(0, disk.size - disk.freeSize)
        return "\(capacity(used))/\(capacity(disk.size))"
    }

    func menuSection() -> [NSMenuItem]? {
        guard isEnabled(self) else { return nil }
        var items = [sectionHeader(L("menu.section.storage"))]

        for disk in mountedDisks() {
            // HTML .disk：图标 + 名字（flex:1 截断）+ 容量角标 + 悬停变红的弹出钮
            let item = NSMenuItem(title: disk.name,
                                  action: #selector(ejectDisk(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("minibar.disk")
            item.image = NSImage(systemSymbolName: DeviceIcons.storage(name: disk.name),
                                 accessibilityDescription: disk.name)
            item.target = self
            item.representedObject = MenuRowMeta(caption: usedString(disk: disk),
                                                 payload: disk.mountPath)
            item.toolTip = "安全弹出（不断电，可随时重新挂载）"
            items.append(item)
        }

        for ejected in ejectedUnits {
            // HTML .disk.ejected：45% 透明，右侧 ↻ 重新挂载
            let item = NSMenuItem(title: "已弹出 · \(ejected.name)",
                                  action: #selector(mountDisk(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("minibar.diskEjected")
            item.image = NSImage(systemSymbolName: DeviceIcons.storage(name: ejected.name),
                                 accessibilityDescription: ejected.name)
            item.target = self
            item.representedObject = MenuRowMeta(caption: capacity(ejected.size),
                                                 payload: ejected.unit)
            item.toolTip = "重新挂载"
            items.append(item)
        }

        if items.count > 1 {
            let ejectAll = menuItem(L("menu.storage.ejectAll"), symbol: "eject",
                                    action: #selector(ejectAllDisks), target: self)
            ejectAll.identifier = NSUserInterfaceItemIdentifier("minibar.confirmEjectAll")
            items.append(ejectAll)
        } else {
            let empty = NSMenuItem(title: L("menu.storage.empty"), action: nil, keyEquivalent: "")
            empty.image = NSImage(systemSymbolName: "externaldrive.badge.minus", accessibilityDescription: nil)
            items.append(empty)
        }
        return items
    }
}
