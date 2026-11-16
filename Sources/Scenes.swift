import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - 通知

extension Notification.Name {
    /// 滑杆值变化（不重建菜单，只让场景区块重算 dirty）
    static let minibarDisplayValueChanged = Notification.Name("minibar.displayValueChanged")
}

// MARK: - 模型

struct SceneValues: Codable, Equatable {
    var brightness: Double
    var contrast: Double
}

struct Scene: Codable, Identifiable {
    var id: String
    var name: String          // 内置场景为空，名字由 L("scene.<id>") 给出
    var builtin: Bool
    var hotkey: Int?          // 1…5，对应 ⌃⌥1…5
    var values: [String: SceneValues]   // 显示端口 key → 数值（含 "default"）

    var displayName: String { builtin ? L("scene.\(id)") : name }
}

// MARK: - 存储

/// 场景 = 一组 {亮度, 对比度} 的命名书签。N 个场景只多 N 行文字，不造控件。
final class SceneStore {
    static let shared = SceneStore()
    static let changed = Notification.Name("minibar.scenesChanged")
    static let valueKey = "default"

    private(set) var scenes: [Scene] = []
    private(set) var active: [String: String] = [:]   // 显示端口 key → 场景 id

    /// 内置 5 档：亮度跨度大、对比度跨度小且不同向——反向微调才是预设的价值
    private static let builtinDefaults: [(id: String, hotkey: Int, b: Double, c: Double)] = [
        ("daily",    1, 55, 50),
        ("cinema",   2, 80, 55),
        ("text",     3, 45, 55),
        ("night",    4, 22, 40),
        ("darkroom", 5,  8, 30),
    ]

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scenes.json")
    }

    private struct Payload: Codable {
        var scenes: [Scene]
        var active: [String: String]
    }

    private init() {
        load()
        HotkeyCenter.shared.install { [weak self] index in
            guard let self,
                  let scene = self.scenes.first(where: { $0.hotkey == index }),
                  let displayID = DisplayPort.currentDisplayID() else { return }
            self.apply(scene, on: displayID)
            NotificationCenter.default.post(name: ModuleEvent.menuRefresh, object: nil)
        }
    }

    // MARK: 读写盘

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            scenes = payload.scenes
            active = payload.active
            if scenes.isEmpty { seedBuiltins() }
            return
        }
        // 损坏 → .bak 恢复 → 仍坏则重建
        let bak = fileURL.appendingPathExtension("bak")
        if let data = try? Data(contentsOf: bak),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            scenes = payload.scenes
            active = payload.active
            if scenes.isEmpty { seedBuiltins() }
            return
        }
        seedBuiltins()
        save()
    }

    private func save() {
        let payload = Payload(scenes: scenes, active: active)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let bak = fileURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.copyItem(at: fileURL, to: bak)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func seedBuiltins() {
        scenes = Self.builtinDefaults.map { d in
            Scene(id: d.id, name: "", builtin: true, hotkey: d.hotkey,
                  values: [Self.valueKey: SceneValues(brightness: d.b, contrast: d.c)])
        }
        active = [:]
        // 首次启动：激活「日常」。硬件写入放后台，避免首块面板构建被 DDC 阻塞
        if let displayID = DisplayPort.currentDisplayID() {
            active[DisplayPort.key(for: displayID)] = "daily"
            let daily = scenes[0]
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard self != nil else { return }
                _ = DisplayPort.apply(brightness: daily.values[Self.valueKey]?.brightness ?? 55,
                                      contrast: daily.values[Self.valueKey]?.contrast ?? 50,
                                      on: displayID)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .minibarDisplayValueChanged, object: nil)
                }
            }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: 查询

    func activeSceneID(for displayID: CGDirectDisplayID) -> String? {
        // 首次启动没有记录时，默认激活「日常」（规格 §3）
        active[DisplayPort.key(for: displayID)]
            ?? (scenes.contains(where: { $0.id == "daily" }) ? "daily" : scenes.first?.id)
    }

    func values(_ scene: Scene, for displayID: CGDirectDisplayID) -> SceneValues {
        scene.values[DisplayPort.key(for: displayID)]
            ?? scene.values[Self.valueKey]
            ?? SceneValues(brightness: 55, contrast: 50)
    }

    /// 滑杆值与激活场景存值不一致 → dirty
    func isDirty(displayID: CGDirectDisplayID) -> Bool {
        guard let id = activeSceneID(for: displayID),
              let scene = scenes.first(where: { $0.id == id }) else { return false }
        let v = values(scene, for: displayID)
        return abs(DisplayPort.brightness(displayID) - v.brightness) > 0.6
            || abs(DisplayPort.contrast(displayID) - v.contrast) > 0.6
    }

    // MARK: 动作

    @discardableResult
    func apply(_ scene: Scene, on displayID: CGDirectDisplayID) -> Bool {
        let v = values(scene, for: displayID)
        let ok = DisplayPort.apply(brightness: v.brightness, contrast: v.contrast, on: displayID)
        active[DisplayPort.key(for: displayID)] = scene.id
        save()
        notify()
        return ok
    }

    /// 用当前滑杆值覆盖激活场景（不是新场景）
    func updateActiveWithCurrent(displayID: CGDirectDisplayID) {
        guard let id = activeSceneID(for: displayID),
              let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[index].values[DisplayPort.key(for: displayID)] = SceneValues(
            brightness: DisplayPort.brightness(displayID),
            contrast: DisplayPort.contrast(displayID))
        save()
        notify()
    }

    func addScene(name: String, displayID: CGDirectDisplayID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let scene = Scene(id: UUID().uuidString, name: trimmed, builtin: false, hotkey: nil,
                          values: [DisplayPort.key(for: displayID): SceneValues(
                            brightness: DisplayPort.brightness(displayID),
                            contrast: DisplayPort.contrast(displayID))])
        scenes.append(scene)
        active[DisplayPort.key(for: displayID)] = scene.id
        save()
        notify()
    }

    func rename(_ scene: Scene, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scene.builtin, !trimmed.isEmpty,
              let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[index].name = trimmed
        save()
        notify()
    }

    func duplicate(_ scene: Scene, displayID: CGDirectDisplayID) {
        var copy = scene
        copy.id = UUID().uuidString
        copy.builtin = false
        copy.hotkey = nil
        copy.name = scene.displayName + L("scene.copySuffix")
        if let v = scene.values[DisplayPort.key(for: displayID)] {
            copy.values = [DisplayPort.key(for: displayID): v]
        }
        scenes.append(copy)
        active[DisplayPort.key(for: displayID)] = copy.id
        save()
        notify()
    }

    func delete(_ scene: Scene, displayID: CGDirectDisplayID) {
        guard !scene.builtin else { return }   // 内置永不消失
        scenes.removeAll { $0.id == scene.id }
        let key = DisplayPort.key(for: displayID)
        if active[key] == scene.id {
            active[key] = Self.builtinDefaults.first!.id
            if let daily = scenes.first(where: { $0.id == active[key] }) {
                _ = apply(daily, on: displayID)
            }
        }
        save()
        notify()
    }

    /// 只复位内置的名字/数值/热键，不动用户自建
    func restoreBuiltins(displayID: CGDirectDisplayID?) {
        for d in Self.builtinDefaults {
            if let index = scenes.firstIndex(where: { $0.id == d.id }) {
                scenes[index].name = ""
                scenes[index].builtin = true
                scenes[index].hotkey = d.hotkey
                scenes[index].values = [Self.valueKey: SceneValues(brightness: d.b, contrast: d.c)]
            } else {
                scenes.insert(Scene(id: d.id, name: "", builtin: true, hotkey: d.hotkey,
                                    values: [Self.valueKey: SceneValues(brightness: d.b, contrast: d.c)]),
                              at: 0)
            }
        }
        // 内置排在前面，用户场景在后
        scenes.sort { a, b in
            if a.builtin != b.builtin { return a.builtin }
            return (a.hotkey ?? 99) < (b.hotkey ?? 99)
        }
        save()
        notify()
        if let displayID,
           let id = activeSceneID(for: displayID),
           let scene = scenes.first(where: { $0.id == id }) {
            _ = apply(scene, on: displayID)
        }
    }
}

// MARK: - 全局热键（Carbon，不需要辅助功能权限）

final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private var callback: ((Int) -> Void)?

    private static let signature: OSType = 0x4D42_4152   // 'MBAR'
    /// 键盘码：1…5 主键盘
    private static let keyCodes: [UInt32] = [0, 18, 19, 20, 21, 23]

    func install(_ callback: @escaping (Int) -> Void) {
        guard handlerRef == nil else { self.callback = callback; return }
        self.callback = callback

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.callback?(Int(hotKeyID.id))
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        for index in 1...5 {
            var hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            var ref: EventHotKeyRef?
            RegisterEventHotKey(Self.keyCodes[index], UInt32(controlKey | optionKey),
                                hotKeyID, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

// MARK: - 面板里的场景区块

struct SceneBlockView: View {
    @State private var revision = 0
    @State private var hovered: String?

    private var store: SceneStore { SceneStore.shared }

    var body: some View {
        let _ = revision
        let displayID = DisplayPort.currentDisplayID()
        let activeID = displayID.flatMap { store.activeSceneID(for: $0) }
        let dirty = displayID.map { store.isDirty(displayID: $0) } ?? false

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(store.scenes) { scene in
                sceneRow(scene, displayID: displayID, active: scene.id == activeID)
            }
            if dirty, let activeID,
               let name = store.scenes.first(where: { $0.id == activeID })?.displayName {
                divider
                actionRow(String(format: L("menu.scene.update"), name), accent: true) {
                    guard let displayID else { return }
                    store.updateActiveWithCurrent(displayID: displayID)
                    refreshMenu()
                }
            }
            divider
            actionRow(L("menu.scene.saveNew")) {
                guard let displayID, let name = SceneDialogs.prompt(
                    title: L("scene.new.title"),
                    message: L("scene.new.message"),
                    placeholder: L("scene.new.placeholder")) else { return }
                store.addScene(name: name, displayID: displayID)
                refreshMenu()
            }
            actionRow(L("menu.scene.restore")) {
                guard SceneDialogs.confirm(title: L("scene.restore.title"),
                                           message: L("scene.restore.message"),
                                           action: L("scene.restore.action")) else { return }
                store.restoreBuiltins(displayID: displayID)
                refreshMenu()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SceneStore.changed)) { _ in revision &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: .minibarDisplayValueChanged)) { _ in revision &+= 1 }
    }

    // MARK: 行

    private func sceneRow(_ scene: Scene, displayID: CGDirectDisplayID?, active: Bool) -> some View {
        let v = displayID.map { store.values(scene, for: $0) } ?? SceneValues(brightness: 0, contrast: 0)
        let isHover = hovered == scene.id
        return HStack(spacing: 10) {
            Text(active ? "●" : " ")
                .font(.system(size: 9))
                .foregroundStyle(active ? Color.accentColor : .clear)
                .frame(width: 9)
            Text(scene.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
            if active && store.isDirty(displayID: displayID ?? 0) {
                Text(L("menu.scene.dirty"))
                    .font(.system(size: 10))
                    .foregroundStyle(PanelAppearance.current.label)
            }
            Spacer(minLength: 12)
            Text("\(Int(v.brightness.rounded()))/\(Int(v.contrast.rounded()))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(PanelAppearance.current.label)
            if let hotkey = scene.hotkey {
                Text("⌃⌥\(hotkey)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(PanelAppearance.current.label)
                    .frame(width: 28, alignment: .trailing)
            } else {
                Menu {
                    Button(L("scene.menu.rename")) {
                        guard let name = SceneDialogs.prompt(
                            title: L("scene.rename.title"),
                            message: "",
                            placeholder: scene.displayName,
                            defaultText: scene.displayName) else { return }
                        store.rename(scene, to: name)
                        refreshMenu()
                    }
                    Button(L("scene.menu.duplicate")) {
                        guard let displayID else { return }
                        store.duplicate(scene, displayID: displayID)
                        refreshMenu()
                    }
                    Divider()
                    Button(L("scene.menu.delete"), role: .destructive) {
                        guard let displayID else { return }
                        store.delete(scene, displayID: displayID)
                        refreshMenu()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PanelAppearance.current.label)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, HUDMenuPanel.rowHInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isHover ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { h in hovered = h ? scene.id : (hovered == scene.id ? nil : hovered) }
        .onTapGesture {
            guard let displayID else { return }
            // dirty 时切场景必须先问：保存 / 丢弃 / 取消（规格 §5）
            if store.isDirty(displayID: displayID),
               let currentID = store.activeSceneID(for: displayID),
               currentID != scene.id,
               let currentName = store.scenes.first(where: { $0.id == currentID })?.displayName {
                switch SceneDialogs.switchChoice(sceneName: currentName) {
                case .save:
                    store.updateActiveWithCurrent(displayID: displayID)
                case .discard:
                    break
                case .cancel:
                    return
                }
            }
            store.apply(scene, on: displayID)
            // DDC 不支持或写入失败：明确提示，不静默失败（规格 §8）
            if !DisplayPort.isSupported(displayID) {
                SceneDialogs.info(L("scene.apply.failed"))
            }
            refreshMenu()
        }
    }

    private func actionRow(_ title: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(accent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HUDMenuPanel.rowHInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: HUDMenuPanel.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(PanelAppearance.current.separator)
            .frame(height: 1)
            .padding(.horizontal, HUDMenuPanel.rowHInset)
            .padding(.vertical, 4)
    }

    /// 场景写入后重建菜单，让上面的两条滑杆立刻跟到新值
    private func refreshMenu() {
        NotificationCenter.default.post(name: ModuleEvent.menuRefresh, object: nil)
    }
}

// MARK: - 原生输入弹窗（borderless 面板拿不到键盘焦点，内联改名做不到）

enum SceneDialogs {
    static func prompt(title: String, message: String, placeholder: String,
                       defaultText: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText
        field.placeholderString = placeholder
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    enum SwitchChoice { case save, discard, cancel }

    /// 单按钮提示（调节失败等）
    static func info(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// dirty 状态下切换场景：保存并切换 / 丢弃并切换 / 取消
    static func switchChoice(sceneName: String) -> SwitchChoice {
        let alert = NSAlert()
        alert.messageText = String(format: L("scene.switch.title"), sceneName)
        alert.informativeText = L("scene.switch.message")
        alert.addButton(withTitle: L("scene.switch.save"))
        alert.addButton(withTitle: L("scene.switch.discard"))
        alert.addButton(withTitle: L("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .save
        case .alertSecondButtonReturn: return .discard
        default:                       return .cancel
        }
    }
}
