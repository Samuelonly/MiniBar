# MiniBar 接力文档（hand off）

> 交接时间：2026-11-16。交接原因：菜单面板渲染问题多轮修复未收敛，产品所有者决定换工具接力。
> 本文写给下一位接手的 AI/工程师：先读本文，再读 PRD.md，再动代码。

## 仓库与文件路径（本机绝对路径）

- **本地仓库根目录**：`/Users/sameulliu/.zcode/workspace/draft-237629a0-e726-4bb6-bf2b-542073be38c2/MiniBar`
- **HTML 原型（视觉唯一真源）**：`/Users/sameulliu/.zcode/workspace/draft-237629a0-e726-4bb6-bf2b-542073be38c2/MiniBar/mockups/menubar.html`（浏览器直接打开，全部交互可演示）
- **PRD**：`PRD.md`（唯一规格，含全部决策记录 §9/§12）
- **裁缝清单**：`TAILORING.md`（哪些模块抄哪个 MIT 项目）
- **构建**：`./build.sh` → `build/MiniBar.app`（swiftc 直出，无 xcodeproj）
- **诊断工具**：`tools/ddcprobe.swift`（DDC 能力探测）、`tools/hidpi-check.swift`、`tools/micprobe.swift`
- 远端：`github.com/Samuelonly/MiniBar`（私有，push 需本地代理 127.0.0.1:7897）

## 当前状态

- **能跑**：`build/MiniBar.app` 进程正常，全部功能模块可用（DDC 亮度/对比度、画质模式 0x14 十二档、夜览、旋转、音频路由、存储弹出/挂载、防休眠、i18n zh-Hans/en）。
- **未收敛的 bug**：点击菜单栏图标后面板高度塌陷问题修过 4 轮（手算高度→居中溢出→浮层→细线），最新一轮（commit a6108be）的机制见下节，**尚未经产品所有者真机确认**。若仍复现，按"已知问题与排查思路"继续。

## 最新一轮修复的机制（a6108be，细线根治）

病根：`ScrollView` 没有理想高度，跟随窗口提案 → 窗口起步 40pt → 测量值被提案绑架 → 面板塌成细线。

修复：
1. **量 `core` 本体**（ScrollView 内的 VStack）——core 是内容驱动的，报告真实内容高度，不随视口提案缩水；
2. 视口 = `min(内容高度 + 12, 屏幕上限 − 40)`，`setViewportHeight` 设置窗口；
3. 起步高度用模型精确计算（`Self.contentHeight`，行高全是固定值：行 26 / 滑杆 30 / 节标题 23 / 分界线 11 / padding 12）；
4. 顶边钉死状态栏底边（`statusBarBottom`，取自 `statusItem.button.window.frame.minY`）。

**如果细线仍复现，下一步排查顺序**：
1. `onGeometryChange` 是否真的在 core 上触发（打印 h）；
2. `setViewportHeight` 的 setFrame 是否被 SwiftUI 布局回写覆盖（考虑 `NSHostingView.sizingOptions = []` + 纯手动窗口管理）；
3. 最稳回退点：commit `4f29697`（该版能启动、渲染正确，仅顶部有缝），在其基础上只加"顶边钉住+实测高度"两件事，别的东西一律不动。

## 已知问题历史（防再踩）

- 顶部缝隙 = 内容比窗口高 + SwiftUI 垂直居中 → 上溢。**窗口高度必须等于实测内容高度，内容顶对齐**。
- 滑杆叠成一条 = AppKit 视图嵌 SwiftUI 没锁高度 → `AppKitRow(...).frame(height: 30)` + SliderRowView 固定 frame。
- 滑杆不等长 = 标签宽度随字数变 → 标签锁宽 44pt 左对齐。
- 渲染糊版 = NSStackView 与 frame 行混用 → 行布局全部固定值，禁止混用。
- 屏名曾被做成下拉块、滑杆被藏 → **产品所有者明确否决**：屏名是纯文本行，滑杆永远一步可见。
- 浮层遮罩方案被否决：展开 = Section/Block 内**就地插入**行，手风琴单开。

## 层级与交互定稿（必须遵守）

层级 = **Section（6 个分区，节标题+分界线）> Block（画质模式/扬声器/麦克风/旋转，可展开）> 行（开关/滑杆/动作）**。交互细则全部以 `mockups/menubar.html` 为准，包括：右侧开关单选互斥、图标双态（静音喇叭↔斜线）、阻断警示（防休眠开启扳系统休眠 → 橙色"⚠ 请先关闭防休眠"）、二段确认（安全弹出全部）、滑杆滚轮调节（上=减，下=增）、数值角标（拖动浮现 0~100，停手即隐）、阻尼 hover（0.22s 慢减速）、文案纪律（PRD §10）。

## 待办队列（产品所有者已排期）

1. 面板高度问题真机确认（上述机制）
2. 麦克风电平表实装（TCC 探针已通过：`tools/micprobe.swift`）
3. 档位自定义命名（画质模式 12 档 OSD 名不可读，暂"模式 N"）
4. 第 6 步候选池：主屏/副屏折叠、设备常驻、显示器音量直控（VCP 0x62）、App 图标

## 红线（违反 = 停下问产品所有者）

- PRD 冲突必须暂停询问，无人值守也一样（README）。
- 零权限：辅助功能/屏幕录制/完全磁盘访问绝不申请。
- 私有 API 已批准的仅三处：IOAVService DDC、CoreDisplay/MonitorPanel 旋转、CoreBrightness 夜览。
- 文案纪律：内部术语（"路由""销毁"）不上 UI；产品术语以 PRD 为准。
- 节奏：串行小步提交，禁止并发子 AI 多任务（用户配额限制）。
