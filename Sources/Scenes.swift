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
    var values: [String: SceneValues]   // 显示端口 key → 数值（含 "default"）

    var displayName: String { builtin ? L("scene.\(id)") : name }
}

/// 用户可改的快捷键绑定（设置页录制）
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt      // NSEvent.ModifierFlags 的原始位（仅 control/option/shift/command）

    var display: String {
        var text = ""
        if modifiers & UInt(NSEvent.ModifierFlags.control.rawValue) != 0 { text += "⌃" }
        if modifiers & UInt(NSEvent.ModifierFlags.option.rawValue) != 0 { text += "⌥" }
        if modifiers & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0 { text += "⇧" }
        if modifiers & UInt(NSEvent.ModifierFlags.command.rawValue) != 0 { text += "⌘" }
        return text + HotkeyBinding.keyName(keyCode)
    }

    /// NSEvent 修饰位 → Carbon 修饰位（RegisterEventHotKey 用）
    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// 常用键位显示名（数字/字母足够覆盖场景快捷键）
    static func keyName(_ code: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
            34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        ]
        return map[code] ?? "Key\(code)"
    }
}

// MARK: - 存储

/// 场景 = 一组 {亮度, 对比度} 的命名书签。N 个场景只多 N 行文字，不造控件。
final class SceneStore {
    static let shared = SceneStore()
    static let changed = Notification.Name("minibar.scenesChanged")
    static let valueKey = "default"

    private(set) var scenes: [Scene] = []
    private(set) var active: [String: String] = [:]   // 显示端口 key → 场景 id
    /// 场景 id → 快捷键（用户可在设置里改；缺省即未绑定）
    private(set) var bindings: [String: HotkeyBinding] = [:]

    /// 内置 5 档：亮度跨度大、对比度跨度小且不同向——反向微调才是预设的价值
    private static let builtinDefaults: [(id: String, b: Double, c: Double)] = [
        ("daily",    55, 50),
        ("cinema",   80, 55),
        ("text",     45, 55),
        ("night",    22, 40),
        ("darkroom",  8, 30),
    ]

    private static let defaultModifiers: UInt =
        NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.option.rawValue

    /// 默认快捷键 ⌃⌥1…5
    static let defaultBindings: [String: HotkeyBinding] = [
        "daily":    HotkeyBinding(keyCode: 18, modifiers: defaultModifiers),
        "cinema":   HotkeyBinding(keyCode: 19, modifiers: defaultModifiers),
        "text":     HotkeyBinding(keyCode: 20, modifiers: defaultModifiers),
        "night":    HotkeyBinding(keyCode: 21, modifiers: defaultModifiers),
        "darkroom": HotkeyBinding(keyCode: 23, modifiers: defaultModifiers),
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
        var bindings: [String: HotkeyBinding]?
    }

    private init() {
        load()
        refreshHotkeys()
    }

    // MARK: 读写盘

    private func read(_ url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.scenes.isEmpty else { return nil }
        return payload
    }

    private func load() {
        if let payload = read(fileURL) {
            scenes = payload.scenes
            active = payload.active
            // 老版本文件没有 bindings → 补默认值；有则尊重用户设置（含「未绑定」）
            bindings = payload.bindings ?? Self.defaultBindings
            return
        }
        // 损坏 → .bak 恢复 → 仍坏则重建
        if let payload = read(fileURL.appendingPathExtension("bak")) {
            scenes = payload.scenes
            active = payload.active
            bindings = payload.bindings ?? Self.defaultBindings
            return
        }
        seedBuiltins()
        save()
    }

    private func save() {
        let payload = Payload(scenes: scenes, active: active, bindings: bindings)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let bak = fileURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.copyItem(at: fileURL, to: bak)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func seedBuiltins() {
        scenes = Self.builtinDefaults.map { d in
            Scene(id: d.id, name: "", builtin: true,
                  values: [Self.valueKey: SceneValues(brightness: d.b, contrast: d.c)])
        }
        bindings = Self.defaultBindings
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

    // MARK: 快捷键

    enum BindingResult { case ok, duplicate, unavailable }

    func binding(for scene: Scene) -> HotkeyBinding? { bindings[scene.id] }

    /// 录制期间：临时注销全部热键；结束后按当前表重新注册
    func suspendHotkeys() { HotkeyCenter.shared.suspend() }
    func resumeHotkeys() { refreshHotkeys() }

    /// 重新注册全部快捷键，返回注册失败（被系统/其它 App 占用）的场景 id
    @discardableResult
    private func refreshHotkeys() -> Set<String> {
        let items: [(id: String, binding: HotkeyBinding)] = scenes.compactMap { scene in
            guard let binding = bindings[scene.id] else { return nil }
            return (scene.id, binding)
        }
        return HotkeyCenter.shared.update(items) { [weak self] sceneID in
            guard let self,
                  let scene = self.scenes.first(where: { $0.id == sceneID }),
                  let displayID = DisplayPort.currentDisplayID() else { return }
            self.apply(scene, on: displayID)
            NotificationCenter.default.post(name: ModuleEvent.menuRefresh, object: nil)
        }
    }

    /// 绑定 nil = 取消该场景的快捷键
    @discardableResult
    func setBinding(_ binding: HotkeyBinding?, for sceneID: String) -> BindingResult {
        if let binding,
           bindings.contains(where: { $0.key != sceneID && $0.value == binding }) {
            return .duplicate
        }
        let previous = bindings
        if let binding {
            bindings[sceneID] = binding
        } else {
            bindings.removeValue(forKey: sceneID)
        }
        // 注册失败（系统占用等）→ 回滚，别让设置显示一个按不响的键
        if refreshHotkeys().contains(sceneID) {
            bindings = previous
            refreshHotkeys()
            return .unavailable
        }
        save()
        notify()
        return .ok
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
        let scene = Scene(id: UUID().uuidString, name: trimmed, builtin: false,
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
        bindings.removeValue(forKey: scene.id)
        refreshHotkeys()
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

    /// 只复位内置的名字/数值/快捷键，不动用户自建
    func restoreBuiltins(displayID: CGDirectDisplayID?) {
        for d in Self.builtinDefaults {
            bindings[d.id] = Self.defaultBindings[d.id]
            if let index = scenes.firstIndex(where: { $0.id == d.id }) {
                scenes[index].name = ""
                scenes[index].builtin = true
                scenes[index].values = [Self.valueKey: SceneValues(brightness: d.b, contrast: d.c)]
            } else {
                scenes.insert(Scene(id: d.id, name: "", builtin: true,
                                    values: [Self.valueKey: SceneValues(brightness: d.b, contrast: d.c)]),
                              at: 0)
            }
        }
        // 内置排在前面（按默认顺序），用户场景在后
        scenes.sort { a, b in
            if a.builtin != b.builtin { return a.builtin }
            let ai = Self.builtinDefaults.firstIndex(where: { $0.id == a.id }) ?? 99
            let bi = Self.builtinDefaults.firstIndex(where: { $0.id == b.id }) ?? 99
            return ai < bi
        }
        refreshHotkeys()
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
    private var refs: [EventHotKeyRef] = []
    /// Carbon 的 id 从 1 起，映射到这里的下标
    private var registeredIDs: [String] = []
    private var handlerRef: EventHandlerRef?
    private var callback: ((String) -> Void)?

    private static let signature: OSType = 0x4D42_4152   // 'MBAR'

    /// 全量替换注册：先全注销再按新表注册。返回注册失败的场景 id（系统/其它 App 占用）
    @discardableResult
    func update(_ items: [(id: String, binding: HotkeyBinding)],
                callback: @escaping (String) -> Void) -> Set<String> {
        self.callback = callback
        unregisterAll()
        installHandlerIfNeeded()

        var failed = Set<String>()
        for item in items {
            let hotKeyID = EventHotKeyID(signature: Self.signature,
                                         id: UInt32(registeredIDs.count + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(item.binding.keyCode),
                                             item.binding.carbonModifiers,
                                             hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                registeredIDs.append(item.id)
            } else {
                failed.insert(item.id)
            }
        }
        return failed
    }

    private func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        registeredIDs.removeAll()
    }

    /// 录制快捷键期间临时注销全部热键：否则按到已注册的组合会被热键吞掉，录制窗收不到
    func suspend() { unregisterAll() }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let index = Int(hotKeyID.id) - 1
            if center.registeredIDs.indices.contains(index) {
                center.callback?(center.registeredIDs[index])
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}

// MARK: - 面板里的场景区块

struct SceneBlockView: View {
    static let sceneRowHeight: CGFloat = 26
    static let dividerHeight: CGFloat = 9

    /// 面板高度按行高模型解析式算，这里必须给出区块的真实高度
    static var blockHeight: CGFloat {
        let store = SceneStore.shared
        var height = CGFloat(store.scenes.count) * sceneRowHeight
        let dirty = DisplayPort.currentDisplayID().map { store.isDirty(displayID: $0) } ?? false
        if dirty { height += dividerHeight + HUDMenuPanel.rowHeight }
        height += dividerHeight + HUDMenuPanel.rowHeight * 2
        return height
    }

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
            if let binding = store.binding(for: scene) {
                Text(binding.display)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(PanelAppearance.current.label)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            if !scene.builtin {
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
        .frame(height: Self.sceneRowHeight)
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
    /// 面板在 statusBar 层级；NSAlert 默认 modalPanel 会被面板盖住，同层抬到最前
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let window = alert.window
        DispatchQueue.main.async {
            window.level = .statusBar
            window.orderFrontRegardless()
        }
        return alert.runModal()
    }

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
        let response = run(alert)
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
        return run(alert) == .alertFirstButtonReturn
    }

    enum SwitchChoice { case save, discard, cancel }

    /// 单按钮提示（调节失败等）
    static func info(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L("common.ok"))
        _ = run(alert)
    }

    /// dirty 状态下切换场景：保存并切换 / 丢弃并切换 / 取消
    static func switchChoice(sceneName: String) -> SwitchChoice {
        let alert = NSAlert()
        alert.messageText = String(format: L("scene.switch.title"), sceneName)
        alert.informativeText = L("scene.switch.message")
        alert.addButton(withTitle: L("scene.switch.save"))
        alert.addButton(withTitle: L("scene.switch.discard"))
        alert.addButton(withTitle: L("common.cancel"))
        switch run(alert) {
        case .alertFirstButtonReturn:  return .save
        case .alertSecondButtonReturn: return .discard
        default:                       return .cancel
        }
    }
}
