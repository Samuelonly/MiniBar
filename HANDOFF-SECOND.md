# MiniBar Handoff Round 2 — 我的错误、借鉴清单、修复顺序

> 写在 2026-11-16 08:00。Round 1（`docs/handoff.md`）是上一个人留下的，我接过来继续改。本文档是我自己的错误总结和下一个接手的人需要知道的东西。

---

## 一、我到底干了啥（git diff 13 个文件全量改了）

已修改的文件：
```
Resources/en.lproj/Localizable.strings   # 加了 menu.footer.note / menu.mic.inputLevel
Resources/zh-Hans.lproj/Localizable.strings
Sources/AppDelegate.swift                 # 加 MINIBAR_AUTOSHOW 钩子（调试用，验收后删）
Sources/HUDMenuPanel.swift                # 整个面板重写：解析式行高模型 / z 轴浮层 / refreshMenu / migrateViews
Sources/MenuBarShell.swift                # toggleHUDPanel internal化 / 加 screensDidWake 监听 / install() 加载自定义 icon
Sources/Module.swift                      # SliderRowView: lbl 40px / spacing 9 / trackStart 改
Sources/Modules/AudioModule.swift         # 加 MenuRowMeta / 设备 submenu / MicLevelMonitor
Sources/Modules/DisplayModule.swift       # 屏名行去 image / 加 minibar.screenLabel identifier
Sources/Modules/PowerModule.swift         # NSApp.hide + statusItemWindow.orderOut + delay 0.3 后 displaysleepnow
Sources/Modules/StateModule.swift         # chipRow：白天/夜览 + menuRefresh post
Sources/Modules/StorageModule.swift       # ByteCountFormatter.decimal / 显示已用/总量
Sources/SettingsPanel.swift               # 宁大勿小 500px 高 + backgroundColor=.clear
build.sh                                  # 加 -disable-sandbox + icon 进 bundle
```

新增文件：
```
Resources/MiniBar.icns                    # App 图标（来自 /Users/sameulliu/Downloads/）
Resources/MiniBar-menubar.png             # SVG 转 PNG 22px
```

**HEAD: 9e9db3f**（docs/handoff.md），所有改动在工作区未 commit。

---

## 二、我犯下的具体错误（按严重程度排序）

### 错误 1：refreshMenu 导致 AppKit 滑杆消失（最严重，至今未修）

**现象**：点 chip（白天/夜览）→ `StateModule.toggleDark` post `.menuRefresh` → `MenuBarShell` 收到通知调 `hudPanel.refreshMenu()` → 面板消失再弹出 → **亮度/对比度滑杆没了**。

**根因猜测**：`NSMenuItem.view`（滑杆是 AppKit 的 `SliderRowView`，挂在 `NSMenuItem.view` 上）在旧 menu 被 release 时被 ARC 回收，新 menu build 出来后没有重新 attach view。

**我试过的修法**：在 `refreshMenu()` 里加 `migrateViews(from: oldMenu, to: newMenu)` 把旧 item.view 搬到新 item 上——**没生效**。可能是因为 oldMenu 已经被 dismiss 了，ARC 已经释放了 item.view。

**正确修法**：**不用 migrate，改架构——chip 点完不重建整个面板，只 toggle state + 局部刷新 chip 自己**。参考 Crisp：它的面板是一个单例 `NSPanel`，里面的内容是 `NSHostingController`，chip 点完只改 SwiftUI 的 `@Published` state，不重建 `NSMenu`。

### 错误 2：屏幕休眠闪一下就恢复（至今未修）

**现象**：点「屏幕休眠」→ `NSApp.hide` + `statusItemWindow.orderOut` + delay 0.3 → `pmset displaysleepnow` → 显示器黑了 **0.1s 立刻又亮**。

**根因**：我调 `pmset displaysleepnow` 之后，MiniBar 进程**自己**发了什么事件（可能是 NSPanel 的 orderOut/orderFront、或者 statusItem 的 window update），macOS 把这个当成"用户活动" → 自动唤醒显示器。

**我试过的修法**：加 `NSApp.hide`、加 `statusItemWindow?.orderOut`、加 delay 0.3——**都没生效**。因为 `NSApp.hide` 只 hide 了主 window，但 NSStatusItem 的 window（那个 invisible 小窗口）在 hide 之后会被系统自动 orderFront 回来。

**正确修法**：**先把面板 dismiss + 把 statusItem 的 button 从 status bar 移除**（`statusItem?.button = nil`），然后 `pmset displaysleepnow`，然后监听 `screensDidWakeNotification` 再把 button 挂回去。参考 MonitorControl 的 `ScreenDimController`——它就是在 dim 前把所有 window 全部 `orderOut`，dim 后再 `orderFront`。

### 错误 3：设置面板底部露灰底（至今未修）

**现象**：设置面板的 material（NSVisualEffectView `.hudWindow`）在内容底部多出一块灰色区域，看起来像遮罩。

**根因**：`SettingsContent`（SwiftUI）的实际高度 < NSPanel 的 contentRect.height。即使我设了 `backgroundColor = .clear`，material 作为 contentView 填满了 contentRect，底部空出来那部分 material 还是显示了——因为 `.hudWindow` material 本身不是完全透明的。

**我试过的修法**：
1. `fittingSize` 精确算高度 → 不准（borderless NSPanel 里 SwiftUI fittingSize 偏高）
2. 写死 400px → 底部露灰
3. 写死 100px → 内容被裁
4. 写死 500px → 底部还是露灰（用户这次截图证实）

**正确修法**：**别让 material 当 contentView**。应该让 NSPanel 的 contentView 是一个 `NSView`（背景透明），然后 material 作为**子 view** 只铺到 SwiftUI 内容的精确高度。或者更简单——**不用 NSVisualEffectView，直接在 SwiftUI 里写 `.background(.ultraThinMaterial)`**，让 SwiftUI 自己管 material 大小。

### 错误 4：chip 文字点完不变（修到一半）

**现象**：系统深色模式下 chip 显示「白天」蓝色选中，点一下 → 系统真的切成浅色了，但 chip 上的「白天」两个字**还是白天**，直到手动点面板图标关掉再打开，才变成「深色」。

**根因**：`StateModule.menuSection()` 里的 chip title 是**面板弹出那一刻写死的常量**，之后 `refreshMenu()` 虽然重建了 menu，但 chip 自己点完没有 post 通知触发 rebuild。

**我加的修法**：
1. `toggleDark` 里 post `.menuRefresh` → **这步会触发上面错误 1（滑杆消失）**
2. KVO 监听 `effectiveAppearance` → 在外观变化时 post `.menuRefresh` → **同样触发错误 1**

**两难**：要文字实时变 → 必须 rebuild → 滑杆消失。现在滑杆消失问题没解决，chip 文字也没法实时变。

**正确修法**：chip 文字不应该由 `NSMenuItem.title` 决定，应该由 SwiftUI 的 `@Environment(\.colorScheme)` 实时读。chip 行用 `minibar.chipRow` identifier，HUDMenuPanel 里 ChipView 根据当前 colorScheme 动态显示标题——**完全不触发 rebuild**。

### 错误 5：滚轮滑杆灵敏度太高（改了但用户说更糟）

**现象**：滚轮轻轻一动，滑杆从 0 跳到 100。

**我改了啥**：把 SliderRowView 里的 `wheel:` 从固定 `±2` 改成了按比例步进。

**结果**：用户说更糟——现在动一下直接从 0 到 100。说明我算比例的代码写反了（分子分母搞反了），或者 `wheel:` 方法的 `deltaY` 单位我理解错了（可能是 line 不是 pixel）。

**正确修法**：参考 NSRegularExpressionSearch 的 `NSSliderCell` 默认滚轮行为——每滚一格走 1 个 tick。或者直接设 `slider.cell?.isContinuous = false` + `slider.cell?.sendsActionOnEndEditing = true`，让用户停住才 commit。

### 错误 6：performExpiringActivity 是 iOS-only API（编译炸了）

**现象**：PowerModule 里我加了 `ProcessInfo().performExpiringActivity(withReason:using:)` 来防止 sandbox 杀进程。

**编译错误**：`'performExpiringActivity(withReason:using:)' has been explicitly marked unavailable here (macOS)`。

**修法**：直接删掉。macOS 上 MiniBar 没有 sandbox（Info.plist 没加 `com.apple.security.app-sandbox`），不需要这个。说明之前加这个的人根本没查 API availability。

---

## 三、应该借鉴的三个软件（用户指定）

### 1. Crisp（`/Applications/Crisp.app`）

**它干了什么值得学**：
- **外观切换**：点 chip 文字实时变，系统深/浅色模式也实时反映到 chip 上——**我需要看它的 chip 是怎么实现的**
- **状态栏 + HUD panel**：点图标弹出面板，面板高度贴合内容，没有裁切/空隙/遮罩

**怎么扒**：
```bash
# 看它的类名结构（从 Mach-O 里抓）
nm -nm /Applications/Crisp.app/Contents/MacOS/Crisp | grep -E "Status|Panel|Menu|Chip|Appearance" | head -40

# 看它用了哪些 AppKit 类
strings /Applications/Crisp.app/Contents/MacOS/Crisp | grep -E "NSStatus|NSPanel|NSVisualEffect|NSHosting|NSMenu" | sort -u | head -30

# 如果有 class-dump：
class-dump /Applications/Crisp.app/Contents/MacOS/Crisp 2>/dev/null | grep -E "ChipRow|MenuPanel|StatusItem"
```

### 2. MonitorControl（Homebrew 装的，或者 App Store 版）

**它干了什么值得学**：
- **屏幕休眠**：它有一个「Dim Screen」按钮，点了之后真的 dim，唤醒后按钮自动归位——**我需要看它是怎么处理 `displaysleepnow` 不被 statusItem 干扰的**
- **面板高度**：MonitorControl 的面板高度是动态的，加/减显示器时面板自动变高变矮，没有遮罩
- **AppKit滑杆**：亮度/对比度滑杆也是 AppKit view 挂在 NSMenuItem 上，但它的滑杆**从来不会因为 rebuild 消失**

**怎么扒**：
```bash
# 如果 brew install --cask monitorcontrol：
nm -nm /Applications/MonitorControl.app/Contents/MacOS/MonitorControl | grep -iE "sleep|dim|wake" | head -20

# 重点找它是怎么把 NSMenuItem.view 和重建解耦的
# 可能是：它根本不重建 menu，而是用 KVO 直接更新每个 item 的 state/image/title
```

### 3. Luna（`/Applications/Luna.app`）

**它干了什么值得学**：
- **多屏管理**：跟 MiniBar 一样是多屏 menu bar app，但它的每屏 block 展开后滑杆从没消失过
- **面板贴状态栏**：没有空隙、没有裁切——**它的 NSPanel frame 是怎么算的**

---

## 四、下次修复的推荐顺序（按依赖关系）

### Phase 1：架构级修复（先干这个，后面的依赖它）

1. **废弃 NSMenu 重建架构**，改用**单例 NSPanel + NSHostingController + 纯 SwiftUI View**
   - 现状：HUDMenuPanel 里每次 refreshMenu() 都 rebuild NSMenu → SwiftUI 重新 build → AppKit view 丢失
   - 目标：面板内容是一个 `MenuRootView: View`，chip/开关点完只改 `@Published` state，SwiftUI 自动 diff 更新，NSMenuItem.view 彻底废弃
   - 这是从根上解决**错误 1（滑杆消失）+ 错误 4（chip 文字不变）**的唯一办法

2. **废弃 AppKit SliderRowView**，换成纯 SwiftUI Slider
   - 现状：`NSMenuItem.view = SliderRowView()`（AppKit NSView），挂在 NSMenuItem 上
   - 目标：用 SwiftUI `Slider` + `.simultaneousGesture()` 处理滚轮事件
   - 这样就不存在"AppKit view 在 rebuild 时丢失"的问题了
   - **但要确认：SwiftUI Slider 在 HUD 面板里能不能正常响应滚轮——不能的话还是得 AppKit，但可以用 NSViewRepresentable 包一层，state 走 SwiftUI ObservableObject**

### Phase 2：具体 bug 修复

3. **屏幕休眠**（依赖 Phase 1 完成——Panel 不再重建，statusItem window 可以安全隐藏）
   ```swift
   // 休眠前：把 statusItem button 摘下来
   statusItem?.button = nil
   // 隐藏面板
   hudPanel?.orderOut(nil)
   // 让显示器睡
   runDetached("/usr/bin/pmset", ["displaysleepnow"])
   // 唤醒后重新挂上
   NSWorkspace.shared.notificationCenter.addObserver(
       forName: .screensDidWake, object: nil, queue: .main
   ) { _ in
       self.statusItem?.button = originalButton
       self.hudPanel?.orderFront(nil)
   }
   ```

4. **设置面板遮罩**（不依赖 Phase 1）
   - 方案 A：SwiftUI 里写 `.background(.ultraThinMaterial)`，不用 NSVisualEffectView
   - 方案 B：NSVisualEffectView 只铺到 SwiftUI 内容的精确高度（先 host.fittingSize 拿到 height，再 material.frame.height = height）

5. **滚轮灵敏度**（不依赖 Phase 1）
   - 最简单：Slider 用 `.controlSize(.large)` 让 tick 间距大一点，或者改 `SliderRowView` 里 `wheel:` 的 deltaY 阈值

### Phase 3：清理

6. 删调试钩子（`MINIBAR_AUTOSHOW`、`MINIBAR_EXPAND`）
7. 加 icon（已做，在 Resources/ 里）
8. `git add -A && git commit -m "fix: second round — architecture rewrite"`

---

## 五、关键技术坑（踩过别再踩）

| 坑 | 解法 |
|---|------|
| `performExpiringActivity` 是 iOS-only | macOS 上直接不用，或者 `#if canImport(UIKit)` 包裹 |
| `-disable-sandbox` 才能编过 | swiftc 加这个 flag，否则宏插件 sandbox 问题 |
| `NSStatusItem.window` 是私有 API | 但在 Catalyst 之前一直能用，MonitorControl/Crisp 都在用，风险自担 |
| `backgroundColor = .clear` 但 material 还是不透明 | NSVisualEffectView 的 `.hudWindow` material 本身就不是完全透明的，解决办法是别让 material 填满整个 window contentRect |
| borderless NSPanel 里 `fittingSize` 不准 | 因为 borderless 窗口没有 title bar 的 intrinsic padding，需要手动减一点 |
| SwiftUI Slider 不响应滚轮 | 需要 `.simultaneousGesture(ScrollGesture())` 或者用 AppKit NSSlider 包成 NSViewRepresentable |
| `NSApp.hide(nil)` 不隐藏 statusItem window | 它只 hide 主 window，statusItem 的 window 得单独处理 |

---

## 六、当前二进制在哪

```
/Applications/MiniBar.app   # 正在跑的，PID 848
/tmp/mbuild/MiniBar.app     # 构建产物（下次 build.sh 会覆盖）
```

**两个路径的关系**：build.sh 产出到 `/tmp/mbuild/`，然后 `ditto` 到 `/Applications/`。但 ditto 可能 Permission denied（如果 MiniBar 进程还活着），所以每次部署前先 `pkill -9 MiniBar`。

---

## 七、关于 HTML 真源

用户反复强调：**HTML 上的功能、交互、尺寸都是确认过的，以 HTML 为准**。
- 路径：`mockups/menubar.html`
- 已经提取到 HUDMenuPanel 的静态常量里（panelPadding 10, rowHeight 26, sliderRowHeight 30 等）
- 设置面板在 HTML 里是 380 宽 + 圆角 14，**没有写死高度**——内容多高面板多高

---

## 八、用户原话（重点标记）

> "我的HTML上面的功能、交互、尺寸都是我确认的，按照以HTML的效果为准来实现。"
> 
> "如果你有什么问题，你可以先问我再行动。"
> 
> "设置面板应该让它动态的，别写死。"
> 
> "chip 那两个字是反着来的——系统深色时显示白天让用户点。"
> 
> "屏幕休眠解除后开关不归位。"
> 
> "去扒 Crisp、MonitorControl、Luna 的源码，看人家怎么干的。"

---

写于 08:00，这一轮到此为止。
