# 模块裁缝清单（开源参考映射，许可证已验证 2026-11-14）

> 原则：优先整段搬 MIT 代码；GPL 只看思路，一行不搬；能不引第三方就不引。

| PRD 模块 | 实现路径 | 参考项目（许可证） | 扒什么 |
|---|---|---|---|
| 外接屏 DDC 亮度/对比度 | IOKit `IOAVService` 私有 I2C（Apple Silicon） | **用户自己的 [BrightnessBar](https://github.com/Samuelonly/BrightnessBar)（已移植，源头是 MonitorControl MIT 路线）** | `DDCTransport.swift` 直接移植；MiniBar 新增 VCP 0x12 对比度（BrightnessBar 原版只有亮度 0x10） |
| 外接屏 DDC（对照参考） | 同上 | [m1ddc](https://github.com/waydabber/m1ddc) (MIT) | 对照实现 |
| ~~ddcctl~~ | — | [ddcctl](https://github.com/kfix/ddcctl) (**GPL-3.0**) | ⚠️ 只看思路，禁止搬运 |
| 屏幕旋转（私有 API，已批准） | CoreDisplay CGS 私有接口 | [displayplacer](https://github.com/jakehilborn/displayplacer) (MIT) | 旋转/分辨率切换实现 |
| 音频输入/输出切换、静音 | CoreAudio 公开 API | [switchaudio-osx](https://github.com/deweller/switchaudio-osx) (MIT，README 已确认) | 设备枚举+切换逻辑，翻 Swift 约 200 行 |
| 深色模式（一次性授权，已批准） | osascript appearance preferences | [dark-mode](https://github.com/sindresorhus/dark-mode) (MIT) | osascript 调用方式 |
| 夜览模式（私有 API，已批准） | CoreBrightness `CBBlueLightClient` | 无必抄项，公开资料多 | Shifty 路线 |
| 内置屏亮度 | `CGDisplaySetBrightness` 公开 API | 不需要 | 系统原生 |
| 屏幕/系统休眠 | `pmset displaysleepnow` / `sleepnow` | 不需要 | `Process` 调用 |
| 防休眠锁 | 独立 `caffeinate -i` 子进程 | 不需要 | App 退出后依然生效（符合 PRD 第 6 节） |
| 存储卸载/挂载 | `diskutil` + DiskArbitration 过滤 USB/Thunderbolt | 不需要 | PRD 第 4 节原生方案 |

## 菜单栏 UI（AppKit）

`NSStatusItem` + `NSMenu`：

- 分组标题用 `NSMenuItem.sectionHeaderWithTitle:`（macOS 12+），天然获得系统设置式分组视觉。
- 亮度/对比度滑杆：view-based NSMenuItem 内嵌 NSSlider（高约 26pt）。
- 滑杆上方标签：菜单展开瞬间用 `NSEvent.mouseLocation` 查询鼠标所在屏名称（`CGGetDisplaysWithPoint` 路由），无需监听。
- 开关项：`item.state = .on/.off` 自带勾选。
- 音频设备：子菜单防长设备名撑爆菜单。
- 图标：SF Symbol 单色 Template。

## 设置面板

主菜单 AppKit；设置面板 SwiftUI（原生 `Settings` scene / NSPopover + `.ultraThinMaterial` 毛玻璃），不引入任何 WebView 技术。

## 已确认决策（详见 PRD 第 9 节）

1. 勿扰模式砍掉 → 1.1
2. 深色模式接受一次性 Automation 授权
3. 允许私有 API，不上架 App Store
4. 唤醒功能明确不做（系统深睡时软件层无法自唤醒；浅睡用原生 `caffeinate -u`；深睡靠外部 WoL）—— PRD §7
5. 重新挂载用 ↻ 图标与 ⏏ 同槽位对称，悬停出字 —— PRD §3.5

## 开发环境备注（2026-11-14）

* 开源参考代码一律**克隆到用户本地**（`references/`，已 gitignore），不经任何外部服务器；网络直连 → 失败切本地代理 `127.0.0.1:7897`。
* 代理也不通：Clash Verge 订阅按钮里点用户的代理「小鲤鱼」刷新订阅，自动切最快节点（用户已授权）。
* 懒人模块化：设置面板关闭某模块 → 该模块 `deactivate()`，后台零监听零 Timer 零唤醒；模块协议三条腿见 PRD §11。
* 菜单/设置面板外观跟随系统深浅色（PRD §10）；菜单每一行必须有图标（全有或全无）。
