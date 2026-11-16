import AppKit
import SwiftUI

// MARK: - 面板状态（跨 rootView 重建共享，刷新菜单时展开态/提示不丢）
final class HUDPanelState: ObservableObject {
    @Published var expandedBlockTitle: String?
    @Published var appeared = false
    @Published var hintItem: ObjectIdentifier?
    @Published var hintText: String?
    @Published var hintWarn = false
    /// 滚轮递增：外部改滑杆后让 SwiftUI 行重新读取真实值
    @Published var sliderTick = 0
    /// 当前鼠标悬停的滑杆行（滚轮事件只作用于它）
    weak var hoveredSlider: SliderRowView?
}

private let hudAccent = Color(red: 77 / 255, green: 157 / 255, blue: 255 / 255)

// MARK: - 自绘 HUD 菜单
//
// 1.0.3 以 mockups/menubar.html 为唯一真源，尺寸/交互逐条对齐原型。
// 层级 = Section > Block > 行；Block 子行是 **z 轴浮层**（HTML 定稿：
// 「父行与面板高度不动」），所以面板高度与展开状态无关。
//
// 高度是**解析式**的：每种行都有固定行高（全部来自 HTML 的 px 值），
// 面板高度 = 2 × 面板内边距 + 各行行高之和。
// 没有常规路径的 ScrollView、没有实时测量回路——前四轮「细线/裁切」的病根
// 就是实测值被窗口提案与安全区内边距联手篡改（实测 635 < 真实内容）。
final class HUDMenuPanel: NSPanel {
    static let width: CGFloat = 320

    // 尺寸常量 —— v0.3.1 呼吸感调整（对齐 Apple 菜单的纵向节奏）：
    // 行高 26→30、滑杆行 30→34、节标题 22→26、分隔线 11→15、说明/电平行 22→26、
    // chip 行 40→44、面板内边距 10→12、左右内缩 6→8、子行 26→28。
    // 面板宽度保持 320（用户否决 332：不是常规断点值），滑杆少 4pt 仍在 100pt 下限之上。
    static let panelPadding: CGFloat = 12
    static let rowHeight: CGFloat = 30
    static let sliderRowHeight: CGFloat = 34
    static let chipRowHeight: CGFloat = 44
    static let screenLabelHeight: CGFloat = 26
    static let sectionHeight: CGFloat = 26
    static let separatorHeight: CGFloat = 15
    static let noteHeight: CGFloat = 26
    static let meterRowHeight: CGFloat = 26
    static let childRowHeight: CGFloat = 28
    static let childHInset: CGFloat = 8
    /// 行左右内缩（原 HTML 的 6px，放宽到 8px 换取呼吸感）
    static let rowHInset: CGFloat = 8

    fileprivate weak var shell: MenuBarShell?
    fileprivate var panelState: HUDPanelState?
    fileprivate var hintClearWork: DispatchWorkItem?

    private var onDismiss: (() -> Void)?
    private var contentHeightValue: CGFloat = 0
    private var statusBarBottom: CGFloat?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var tmpMouseMonitor: Any?
    private var hintObserver: Any?
    private var skinObserver: Any?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(shell: MenuBarShell) {
        self.shell = shell
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 40),
            // borderless：内容直顶窗口顶边。不能用 .nonactivatingPanel——
            // 它让面板弹出时不是 key window，第一次点击只用来激活窗口，
            // 落不到控件上（用户实测「要点两次」的根因）。
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // 皮肤：未手动跟随系统、手动后记住选择（PanelAppearance）。
        // 窗口 appearance 决定 NSSlider / NSSwitch 原生控件配色，必须跟着皮肤走。
        appearance = PanelAppearance.current.nsAppearance
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // PowerModule 要让显示器 sleep → 先 dismiss HUD 面板（否则面板重绘会立刻唤醒显示器）
        NotificationCenter.default.addObserver(forName: Notification.Name("minibar.willSleep"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.dismiss()
        }
        // 系统深浅色模式变化 → 跟随系统时换皮肤 + 重建菜单让 chip 文字及时更新
        NSApp.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)
        // 手动换肤（chip 点击）→ 换皮肤 + 重建菜单
        skinObserver = NotificationCenter.default.addObserver(
            forName: PanelAppearance.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applySkin()
            self?.refreshMenu()
        }
    }

    /// 把当前有效皮肤应用到窗口与托管视图（原生控件配色 + SwiftUI colorScheme）
    private func applySkin() {
        let skin = PanelAppearance.current
        appearance = skin.nsAppearance
        (contentView as? NSHostingView<HUDMenuContent>)?.appearance = skin.nsAppearance
    }

    override func close() {
        dismiss()
    }

    deinit {
        NSApp.removeObserver(self, forKeyPath: "effectiveAppearance")
        if let skinObserver { NotificationCenter.default.removeObserver(skinObserver) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" {
            applySkin()
            refreshMenu()
        }
    }

    // MARK: 面板高度 = 行高模型（解析式，与 HTML 的固定像素一一对应）
    static func height(of item: NSMenuItem) -> CGFloat {
        if item.isSeparatorItem { return separatorHeight }
        switch item.identifier?.rawValue {
        case "minibar.sectionHeader": return sectionHeight
        case "minibar.screenLabel": return screenLabelHeight
        case "minibar.note": return noteHeight
        case "minibar.chipRow": return chipRowHeight
        case "minibar.micLevel": return meterRowHeight
        default:
            if let view = item.view { return view.frame.height }
            return rowHeight
        }
    }

    static func contentHeight(menu: NSMenu) -> CGFloat {
        menu.items.reduce(panelPadding * 2) { $0 + height(of: $1) }
    }

    // MARK: 展示
    func showUnderButton(_ buttonFrame: NSRect?) {
        guard let menu = shell?.buildMenuModel() else { return }

        let screen = NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        statusBarBottom = buttonFrame?.minY

        // 超屏才降级为滚动：内容高度已知，不需要任何测量
        let natural = Self.contentHeight(menu: menu)
        let cap = available.height - 40
        let scrollable = natural > cap
        let height = scrollable ? cap : natural
        contentHeightValue = natural

        let state = HUDPanelState()
        panelState = state
        let host = FirstMouseHostingView(rootView: makeContent(menu: menu, scrollable: scrollable,
                                                       cap: cap, state: state))
        host.sizingOptions = []
        contentView = host
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        applySkin()

        var frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        if let buttonFrame {
            // 顶边钉住状态栏底边，水平对齐状态项
            frame.origin.x = buttonFrame.midX - Self.width / 2
            frame.origin.y = buttonFrame.minY - height
        }
        frame.origin.x = max(available.minX + 8,
                             min(frame.origin.x, available.maxX - Self.width - 8))
        if frame.origin.y < available.minY + 8 { frame.origin.y = available.minY + 8 }
        setFrame(frame, display: false)
        orderFrontRegardless()
        installMonitors()
    }

    private func makeContent(menu: NSMenu, scrollable: Bool, cap: CGFloat,
                             state: HUDPanelState) -> HUDMenuContent {
        var content = HUDMenuContent(menu: menu, scrollable: scrollable,
                                     maxHeight: cap, state: state)
        content.onDismiss = { [weak self] in self?.dismiss() }
        content.onRefresh = { [weak self] in self?.refreshMenu() }
        return content
    }

    // MARK: 刷新（弹出盘后行内容变化；行数不变 → 高度不变）
    // 对外可见：PowerModule 屏幕睡/醒、StorageModule 盘挂载/弹出 → MenuBarShell 调
    func refreshMenu() {
        guard let shell, let host = contentView as? NSHostingView<HUDMenuContent>,
              let state = panelState else { return }
        let menu = shell.buildMenuModel()

        let natural = Self.contentHeight(menu: menu)
        let cap = (NSScreen.main?.visibleFrame ?? frame).height - 40
        let scrollable = natural > cap
        contentHeightValue = natural

        host.rootView = makeContent(menu: menu, scrollable: scrollable, cap: cap, state: state)

        let height = scrollable ? cap : natural
        guard abs(height - frame.height) > 0.5 else { return }
        var f = frame
        f.size.height = height
        f.origin.y = (statusBarBottom ?? f.maxY) - height
        let floorY = (NSScreen.main?.visibleFrame.minY ?? 0) + 8
        if f.origin.y < floorY { f.origin.y = floorY }
        setFrame(f, display: true)
    }

    func dismiss() {
        orderOut(nil)
        panelState?.hoveredSlider = nil
        removeMonitors()
        onDismiss?()
    }

    private func removeMonitors() {
        for monitor in [clickMonitor, keyMonitor, tmpMouseMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        clickMonitor = nil
        keyMonitor = nil
        tmpMouseMonitor = nil
        if let hintObserver { NotificationCenter.default.removeObserver(hintObserver) }
        hintObserver = nil
        hintClearWork?.cancel()
    }

    // MARK: 监听（面板外点击 / Esc / 行内提示桥接）
    private func installMonitors() {
        // 先清旧的：之前每次弹面板都叠加一套监听器，开 100 次就积 100 个，
        // 点击/滚轮会被重复处理，行为越来越怪。
        removeMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let location = NSEvent.mouseLocation
            if let buttonFrame = shell?.statusButtonFrame(), buttonFrame.contains(location) { return }
            if !self.frame.contains(location) { self.dismiss() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == 53 else { return event }
            self.dismiss()
            return nil
        }
        // 滚轮调滑杆由 NativeSliderRow 的容器处理（NSSlider 自己就是原生滚轮响应），
        // 这里不再加全局 wheel monitor，否则一次滚动会被两处各调一遍。

        // 调试用的点击日志监听已移除：每次点击都写文件会明显拖慢交互

        // 模块行内提示（阻断警示等）：桥接进共享状态，1.4s 自动清除
        hintObserver = NotificationCenter.default.addObserver(
            forName: ModuleEvent.rowHint, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isVisible, let state = self.panelState,
                  let item = note.userInfo?["item"] as? NSMenuItem,
                  let text = note.userInfo?["text"] as? String else { return }
            let warn = (note.userInfo?["warn"] as? Bool) ?? false
            let target = ObjectIdentifier(item)

            self.hintClearWork?.cancel()
            state.hintItem = target
            state.hintText = text
            state.hintWarn = warn

            let work = DispatchWorkItem { [weak state] in
                guard let state, state.hintItem == target else { return }
                state.hintItem = nil
                state.hintText = nil
            }
            self.hintClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
        }
    }

    private func send(_ item: NSMenuItem) {
        if let target = item.target, let action = item.action {
            NSApp.sendAction(action, to: target, from: item)
        }
    }
}

// MARK: - Block 子行浮层锚点（key = Block 标题，跨菜单重建稳定）
private struct BlockAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - 展开态收起（点面板任意行/空白处都收起，对应 HTML capture 阶段行为）
private struct CollapseBlocksKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private extension EnvironmentValues {
    var collapseBlocks: () -> Void {
        get { self[CollapseBlocksKey.self] }
        set { self[CollapseBlocksKey.self] = newValue }
    }
}

// MARK: - SwiftUI 内容（Section > Block > 行）
private struct HUDMenuContent: View {
    let menu: NSMenu
    let scrollable: Bool
    let maxHeight: CGFloat
    @ObservedObject var state: HUDPanelState
    var onDismiss: (() -> Void)?
    var onRefresh: (() -> Void)?

    /// 行状态（开关/单选）读 NSMenuItem.state，动作后 +1 强制整棵重绘
    @State private var version = 0

    private struct Block {
        let item: NSMenuItem
        var title: String { item.title }
        let children: [NSMenuItem]
    }

    private struct SectionData {
        var title: String?
        var rows: [NSMenuItem] = []
        var blocks: [Block] = []
        var isEmpty: Bool { title == nil && rows.isEmpty && blocks.isEmpty }
    }

    private var sections: [SectionData] {
        var result: [SectionData] = []
        var current = SectionData()
        for item in menu.items {
            if item.isSeparatorItem {
                if !current.isEmpty { result.append(current) }
                current = SectionData()
            } else if item.identifier?.rawValue == "minibar.sectionHeader" {
                if !current.isEmpty { result.append(current) }
                current = SectionData()
                current.title = item.title
            } else if item.submenu != nil && item.identifier?.rawValue != "minibar.chipRow" {
                // chip 行也带 submenu，但它是「一行两枚 chip」，不是可展开 Block
                let children = item.submenu?.items.filter { !$0.isSeparatorItem } ?? []
                current.blocks.append(Block(item: item, children: children))
            } else {
                current.rows.append(item)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private var allBlocks: [Block] { sections.flatMap(\.blocks) }

    var body: some View {
        let _ = version
        Group {
            if scrollable {
                ScrollView { core }.frame(height: maxHeight)
            } else {
                core
            }
        }
        .frame(width: HUDMenuPanel.width, alignment: .top)
        // 背景与描边随皮肤：夜间 #1C1C20（HTML 定稿）/ 白天 #F6F6F8。
        // 不透明实色——毛玻璃会把背后的编辑器文字透出来，看起来像蒙了层脏纱。
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(PanelAppearance.current.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(PanelAppearance.current.border, lineWidth: 1)
        )
        // 文字/次级文字/chip/浮层材质全部由 colorScheme 驱动，两套皮肤真切换
        .environment(\.colorScheme, PanelAppearance.current.colorScheme)
        .opacity(state.appeared ? 1 : 0)
        .onAppear {
            guard !state.appeared else { return }
            withAnimation(.easeOut(duration: 0.15)) { state.appeared = true }
        }
    }

    private var core: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, pair in
                if index > 0 { separator }
                if let title = pair.title { sectionHeader(title) }
                ForEach(Array(pair.rows.enumerated()), id: \.offset) { _, item in
                    row(item)
                }
                ForEach(Array(pair.blocks.enumerated()), id: \.offset) { _, block in
                    blockHeader(block.item)
                        .anchorPreference(key: BlockAnchorKey.self, value: .bounds) {
                            [block.title: $0]
                        }
                }
            }
        }
        .padding(.horizontal, HUDMenuPanel.panelPadding)
        .padding(.vertical, HUDMenuPanel.panelPadding)
        .environment(\.collapseBlocks) { state.expandedBlockTitle = nil }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    state.expandedBlockTitle = nil
                }
        )
        .overlayPreferenceValue(BlockAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let title = state.expandedBlockTitle,
                   let anchor = anchors[title],
                   let block = allBlocks.first(where: { $0.title == title }) {
                    let rect = proxy[anchor]
                    childrenPanel(block)
                        // HTML .children{top:calc(100% + 2px); left:30px; right:10px}
                        .frame(width: rect.width - 40, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: rect.minX + 30, y: rect.maxY + 2)
                }
            }
        }
    }

    // MARK: 行分发
    @ViewBuilder
    private func row(_ item: NSMenuItem) -> some View {
        switch item.identifier?.rawValue {
        case "minibar.screenLabel":
            screenLabel(item.title)
        case "minibar.note":
            noteRow(item.title)
        case "minibar.chipRow":
            chipRow(item)
        case "minibar.disk":
            DiskRow(item: item, meta: item.representedObject as? MenuRowMeta,
                    ejected: false, onClick: { send(item, refresh: true) })
        case "minibar.diskEjected":
            DiskRow(item: item, meta: item.representedObject as? MenuRowMeta,
                    ejected: true, onClick: { send(item, refresh: true) })
        case "minibar.micLevel":
            MicLevelRow()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: HUDMenuPanel.meterRowHeight)
        case "minibar.sceneBlock":
            SceneBlockView()
                .frame(maxWidth: .infinity, alignment: .leading)
        case "minibar.confirmEjectAll":
            ConfirmEjectAllRow(item: item) {
                send(item)
                onDismiss?()
            }
        case "minibar.switch":
            MenuSwitchRow(item: item,
                          hint: state.hintItem == ObjectIdentifier(item) ? state.hintText : nil,
                          hintWarn: state.hintWarn,
                          onFlip: {
                              send(item)
                              version &+= 1
                          })
        default:
            if let sliderRow = item.view as? SliderRowView {
                // 滑杆用 SwiftUI 重建（不再把 AppKit 视图塞进视图树，
                // 那样每次刷新菜单都会被 ARC 回收 → 用户看到「滑杆时有时无」）
                HUDliderRow(source: sliderRow, state: state)
                    .frame(height: HUDMenuPanel.sliderRowHeight)
            } else if let view = item.view {
                AppKitRow(view: view).frame(height: view.frame.height)
            } else {
                ActionRow(item: item,
                          hasHint: state.hintItem == ObjectIdentifier(item),
                          hintText: state.hintItem == ObjectIdentifier(item)
                              ? (state.hintText ?? "") : "",
                          hintWarn: state.hintWarn,
                          onAction: {
                              send(item)
                              onDismiss?()
                          })
            }
        }
    }

    private func send(_ item: NSMenuItem, refresh: Bool = false) {
        if let target = item.target, let action = item.action {
            NSApp.sendAction(action, to: target, from: item)
        }
        if refresh { onRefresh?() }
    }

    // MARK: Section / 说明
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, HUDMenuPanel.rowHInset)
            .padding(.top, 9)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: HUDMenuPanel.sectionHeight)
    }

    private var separator: some View {
        Rectangle()
            .fill(PanelAppearance.current.separator)
            .frame(height: 1)
            .padding(.horizontal, HUDMenuPanel.rowHInset)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .frame(height: HUDMenuPanel.separatorHeight)
    }

    /// HTML .screen-label：无图标、12px、名字 500 字重
    private func screenLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, HUDMenuPanel.rowHInset)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: HUDMenuPanel.screenLabelHeight)
    }

    /// HTML 说明行「所有模块可随时加载或关闭」
    private func noteRow(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(PanelAppearance.current.label)
            .lineLimit(1)
            .padding(.horizontal, 16)   // .child-row 的 margin 8 + padding 8
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: HUDMenuPanel.noteHeight)
    }

    // MARK: Block 头（可展开行）
    private func blockHeader(_ item: NSMenuItem) -> some View {
        let open = state.expandedBlockTitle == item.title
        return Hoverable(
            content: HStack(spacing: 12) {
                if let image = item.image {
                    Image(nsImage: image).resizable().frame(width: 15, height: 15)
                        .foregroundStyle(.secondary)
                }
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .animation(.easeOut(duration: 0.22), value: open)
            },
            onClick: {
                state.expandedBlockTitle = open ? nil : item.title
            }
        )
    }

    // MARK: Block 子行（z 轴浮层，面板高度不变）
    private func childrenPanel(_ block: Block) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(block.children.enumerated()), id: \.offset) { _, child in
                childRow(child, siblings: block.children)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(PanelAppearance.current.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 10)
    }

    @ViewBuilder
    private func childRow(_ child: NSMenuItem, siblings: [NSMenuItem]) -> some View {
        if child.identifier?.rawValue == "minibar.micLevel" {
            MicLevelRow()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: HUDMenuPanel.meterRowHeight)
        } else {
            // 单选互斥：翻转后由 version 重绘统一回读各 item.state
            MenuSwitchRow(item: child,
                          tag: (child.representedObject as? MenuRowMeta)?.caption,
                          hint: nil, hintWarn: false,
                          compact: true,
                          onFlip: {
                              send(child)
                              if child.state == .on {
                                  for sibling in siblings where sibling !== child {
                                      sibling.state = .off
                                  }
                              }
                              version &+= 1
                          })
        }
    }

    // MARK: 外观 chip 行（HTML .grid-row）
    private func chipRow(_ item: NSMenuItem) -> some View {
        let chips = item.submenu?.items ?? []
        return HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                ChipView(item: chip) {
                    send(chip)
                    version &+= 1
                }
            }
        }
        .padding(.horizontal, HUDMenuPanel.rowHInset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: HUDMenuPanel.chipRowHeight)
    }
}

// MARK: - 外观 chip（HTML .chip）
private struct ChipView: View {
    let item: NSMenuItem
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        // chip 是**按钮**，不是开关：点一下执行动作，没有选中态。
        // （HTML 的 .chip.on 是原型里标注「当前模式」用的，不适用于这里的语义）
        HStack(spacing: 7) {
            if let image = item.image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: 14, height: 14)
            }
            Text(item.title)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(hovering ? 0.12 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .animation(.easeOut(duration: 0.18), value: hovering)
    }
}

// MARK: - 存储盘行（HTML .disk：名字 + 容量 + 弹出钮，悬停变红；已弹出 45% 透明）
private struct DiskRow: View {
    let item: NSMenuItem
    let meta: MenuRowMeta?
    let ejected: Bool
    let onClick: () -> Void

    @State private var hovering = false

    var body: some View {
        Hoverable(
            content: HStack(spacing: 12) {
                if let image = item.image {
                    Image(nsImage: image).resizable().frame(width: 15, height: 15)
                        .foregroundStyle(.secondary)
                }
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                if let cap = meta?.caption {
                    Text(cap)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PanelAppearance.current.label)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .lineLimit(1)
                }
                Image(systemName: ejected ? "arrow.clockwise" : "eject.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ejected
                                     ? Color.secondary
                                     : (hovering
                                        ? Color(red: 1, green: 0.545, blue: 0.478)
                                        : Color.secondary))
            },
            onClick: onClick,
            hoveringChanged: { hovering = $0 }
        )
        .opacity(ejected ? 0.45 : 1)
    }
}

// MARK: - 通用行容器（HTML .item：hover 阻尼 0.22s）
private struct Hoverable<Content: View>: View {
    let content: Content
    var height: CGFloat = HUDMenuPanel.rowHeight
    var hInset: CGFloat = HUDMenuPanel.rowHInset
    var radius: CGFloat = 10
    var hoverOpacity: CGFloat = 0.08
    var onClick: (() -> Void)?
    var hoveringChanged: ((Bool) -> Void)?

    @State private var hovering = false
    @Environment(\.collapseBlocks) private var collapseBlocks

    var body: some View {
        content
            .padding(.horizontal, hInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.primary.opacity(hovering ? hoverOpacity : 0))
                    .shadow(color: .black.opacity(hovering ? 0.3 : 0),
                            radius: hovering ? 4 : 0,
                            y: hovering ? 2 : 0)
            )
            .contentShape(Rectangle())
            .onHover { h in
                withAnimation(.easeOut(duration: 0.22)) { hovering = h }
                hoveringChanged?(h)
            }
            .onTapGesture {
                collapseBlocks()
                onClick?()
            }
    }
}

// MARK: - 动作行（HTML .item + .shortcut）
private struct ActionRow: View {
    let item: NSMenuItem
    var hasHint: Bool
    var hintText: String
    var hintWarn: Bool
    var onAction: () -> Void

    var body: some View {
        Hoverable(
            content: HStack(spacing: 12) {
                if let image = item.image {
                    Image(nsImage: image).resizable().frame(width: 15, height: 15)
                        .foregroundStyle(.secondary)
                }
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 12)
                if hasHint {
                    Text(hintText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(hintWarn ? Color(red: 1, green: 0.71, blue: 0.33)
                                                  : Color(red: 0.49, green: 0.89, blue: 0.66))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(4)
                        .transition(.opacity)
                } else if !item.keyEquivalent.isEmpty {
                    Text("⌘\(item.keyEquivalent.uppercased())")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            },
            onClick: onAction
        )
        .animation(.easeOut(duration: 0.2), value: hasHint)
    }
}

// MARK: - 开关行（HTML .item + .switch；compact = 子行 .child-row）
// 状态直接读 NSMenuItem.state：父层 version +1 后整棵重绘，单选互斥才不会视觉打架
private struct MenuSwitchRow: View {
    let item: NSMenuItem
    /// HTML .tag：10px 等宽、1px 描边，跟在名字后面（内建/USB/蓝牙…）
    var tag: String?
    var hint: String?
    var hintWarn = false
    var compact = false
    let onFlip: () -> Void

    var body: some View {
        Hoverable(
            content: HStack(spacing: 12) {
                if let image = item.image {
                    Image(nsImage: image).resizable()
                        .frame(width: compact ? 13 : 15, height: compact ? 13 : 15)
                        .foregroundStyle(.secondary)
                }
                Text(item.title)
                    .font(.system(size: compact ? 12 : 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                if let tag {
                    Text(tag)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(PanelAppearance.current.label)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(PanelAppearance.current.tagBorder, lineWidth: 1)
                        )
                }
                if let hint {
                    Text(hint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(hintWarn ? Color(red: 1, green: 0.71, blue: 0.33)
                                                  : Color(red: 0.49, green: 0.89, blue: 0.66))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(4)
                        .transition(.opacity)
                }
                Toggle("", isOn: Binding(get: { item.state == .on },
                                         set: { _ in onFlip() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            },
            height: compact ? HUDMenuPanel.childRowHeight : HUDMenuPanel.rowHeight,
            hInset: compact ? HUDMenuPanel.childHInset : 6,
            radius: compact ? 8 : 10,
            hoverOpacity: compact ? 0.05 : 0.08
        )
        .animation(.easeOut(duration: 0.2), value: hint != nil)
    }
}

// MARK: - 破坏性动作二段确认行（PRD §3.6）
private struct ConfirmEjectAllRow: View {
    let item: NSMenuItem
    var onConfirmed: () -> Void

    @State private var confirming = false
    @State private var timer: Timer?

    var body: some View {
        Hoverable(
            content: HStack(spacing: 12) {
                if let image = item.image {
                    Image(nsImage: image).resizable().frame(width: 15, height: 15)
                        .foregroundStyle(.secondary)
                }
                Text(confirming ? L("menu.storage.ejectAllConfirm") : item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(confirming ? Color(red: 1, green: 0.71, blue: 0.33) : .primary)
                    .lineLimit(1)
                Spacer(minLength: 12)
            },
            onClick: {
                if confirming {
                    timer?.invalidate()
                    confirming = false
                    onConfirmed()
                } else {
                    confirming = true
                    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                        confirming = false
                    }
                }
            }
        )
        .background(confirming ? Color(red: 1, green: 0.55, blue: 0.2).opacity(0.15) : Color.clear)
        .animation(.easeOut(duration: 0.2), value: confirming)
    }
}

// MARK: - SwiftUI 滑杆行（HTML .slider-row：图标 15 + 共享标签宽 + 轨道；行内 gap 10 用户定稿）
private struct HUDliderRow: View {
    let source: SliderRowView
    @ObservedObject var state: HUDPanelState

    @State private var value: Double
    @State private var showTag = false
    @State private var hideTask: DispatchWorkItem?

    init(source: SliderRowView, state: HUDPanelState) {
        self.source = source
        self.state = state
        _value = State(initialValue: source.sliderValue)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.rowSymbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 15)
            Text(source.rowTitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // i18n：当前语言实测共享标签宽（亮度/对比度取最大），两行轨道同起点；
                // 上限 141 保证滑杆至少 100pt，极端长语言标签截断也不与滑杆粘上
                .frame(width: SliderRowView.sharedLabelWidth, alignment: .leading)
            NativeSliderRow(minValue: source.sliderMin,
                            maxValue: source.sliderMax,
                            value: value) { newValue in
                value = newValue
                source.commit(newValue)
                flashTag()
            }
            .frame(height: 16)
        }
        .padding(.horizontal, HUDMenuPanel.rowHInset)
        .frame(height: HUDMenuPanel.sliderRowHeight)
        .onHover { inside in
            if inside {
                state.hoveredSlider = source
            } else if state.hoveredSlider === source {
                state.hoveredSlider = nil
            }
        }
        .onChange(of: state.sliderTick) { _ in
            // 滚轮改的是 AppKit 里的真实值，这里同步回显示
            if abs(source.sliderValue - value) > 0.0001 {
                value = source.sliderValue
            }
        }
        .overlay(alignment: .topTrailing) {
            if showTag {
                Text("\(Int(((value - source.sliderMin) / max(source.sliderMax - source.sliderMin, 0.0001) * 100).rounded()))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(hudAccent, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: -40, y: -2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func flashTag() {
        showTag = true
        hideTask?.cancel()
        let work = DispatchWorkItem { showTag = false }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
}

// MARK: - AppKit 原生滑杆（NSSlider：系统 glass 质感 + 阴影；滚轮在容器层处理）
private struct NativeSliderRow: NSViewRepresentable {
    let minValue: Double
    let maxValue: Double
    let value: Double
    let onChange: (Double) -> Void

    final class ContainerView: NSView {
        let slider = NSSlider()
        var onChange: ((Double) -> Void)?

        /// 滚轮：每次 1%，最多 5%（与 HTML 一致的细粒度，不会一动就到底）
        override func scrollWheel(with event: NSEvent) {
            let span = max(slider.maxValue - slider.minValue, 0.0001)
            let ticks = max(1, min(Int(abs(event.scrollingDeltaY) / 8) + 1, 5))
            let step = span * 0.01 * Double(ticks)
            let delta = event.scrollingDeltaY > 0 ? -step : step
            slider.doubleValue = max(slider.minValue,
                                     min(slider.maxValue, slider.doubleValue + delta))
            onChange?(slider.doubleValue)
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView()
        let slider = container.slider
        slider.minValue = minValue
        slider.maxValue = maxValue
        slider.doubleValue = value
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            slider.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.onChange = onChange
        context.coordinator.onChange = onChange
        return container
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        nsView.onChange = onChange
        context.coordinator.onChange = onChange
        if abs(nsView.slider.doubleValue - value) > 0.0001 {
            nsView.slider.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (Double) -> Void
        init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSSlider) { onChange(sender.doubleValue) }
    }
}

// MARK: - AppKit 滑杆（实现在 Module.swift 的 SliderRowView：滚轮 + 数值角标）
private struct AppKitRow: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        // 给 container 初始 frame，避免 SwiftUI 首次布局时 Auto Layout 还没从 subview
        // 反向推导出高度 → 滑杆行闪一下或根本不显示
        let initialHeight = max(view.frame.height, 30)
        container.frame = NSRect(x: 0, y: 0, width: 308, height: initialHeight)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.frame = container.bounds
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 麦克风输入电平（HTML .meter：8 格 × 4×10，仅子行展开期间运行）
private struct MicLevelRow: View {
    @State private var level: Float = 0

    var body: some View {
        HStack(spacing: 12) {
            Text(L("menu.mic.inputLevel"))
                .font(.system(size: 12))
                .foregroundStyle(PanelAppearance.current.label)
                .lineLimit(1)
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < litCount ? hudAccent : Color.primary.opacity(0.15))
                        .frame(width: 4, height: 10)
                        .animation(.easeOut(duration: 0.1), value: litCount)
                }
            }
        }
        .padding(.horizontal, HUDMenuPanel.childHInset)
        .onReceive(NotificationCenter.default.publisher(for: .micLevelDidChange)) { note in
            if let value = note.object as? Float { level = value }
        }
        .onAppear { MicLevelMonitor.shared.start() }
        .onDisappear { MicLevelMonitor.shared.stop() }
    }

    private var litCount: Int {
        min(8, max(0, Int((level * 8).rounded())))
    }
}
