---
name: macos-dock-folders
description: 把 macOS Dock 里的一堆 App 折叠成可点击展开的图标，或整理/去重 Dock 布局。当用户说"Dock 图标太多/太挤"、"想在 Dock 里建文件夹"、"像手机那样分组应用"、"Dock 整理"、"Dock 图标大小统一"、"Dock 位置不对"时使用。含现成工具：实时合成 2×2 拼贴图标 + 写入 Dock + 自动监听 + 一键备份恢复。
agent_created: true
---

# macOS Dock 折叠分组

## 结论先行（先告诉用户这个）

macOS **原生不支持**把 Dock 图标拖到另一个上合并成 iOS 那种文件夹。
能做的是「拼贴图标 + 点击展开」，而且**位置和展开方式必须二选一**：

| 想要的位置 | tile 类型 | 点击行为 |
|---|---|---|
| 左侧 App 区（任意位置） | 启动器 **App**（`file-tile`） | 弹出图标网格 ✅（需编译 App） |
| 分隔线右侧 | 文件夹 **Stack**（`directory-tile`） | 原生 Stack 网格 ✅ |

**关键事实**：文件夹 tile 写进 `persistent-apps`（左侧区）是能被 Dock 接受的，
重启 Dock 也不会被弹回右侧 —— **但点击只会打开 Finder 窗口，不会弹网格**。
Stack 的弹窗逻辑和 tile 所在区域绑定，**没有任何 plist 字段能改**。
所以用户既要「别在最右边」又要「点击展开」，就必须走启动器 App 方案。

想支持拖拽合并 → 只有第三方 Dock 替代品（如 Dockish，$6.99），要接管整个 Dock，一般不建议。

## 现成工具

本仓库的 `scripts/dockgroup.py`（配置 `~/Dock Groups/groups.json`，可用 `DOCKGROUP_HOME` 覆盖）。

```bash
DG='/usr/bin/python3 <repo>/scripts/dockgroup.py'
$DG doctor              # 先体检依赖
$DG init                # 扫描当前 Dock 生成起始配置
$DG new AI "App1" "App2"
$DG preview [组名]      # 只合成图标预览，不动 Dock —— 改前必跑
$DG apply   [组名]      # 生成并写入 Dock
$DG rebuild             # 按文件夹现状刷新图标并重启 Dock
$DG list / open / test / remove / clean / watch-install / restore
```

## 标准流程

1. **读现状**：`$DG list`，或 `defaults read com.apple.dock persistent-apps` + percent-decode。
2. **提方案**：按用途分组（AI/浏览器/社交/办公/系统/个人）。
   **高频 App 保持平铺**，只折叠「低频但想在手边」的。清单给用户确认。
3. **预览**：跑 `preview`，把 `~/Dock Groups/.cache/preview-all.png` 给用户看。
   拼贴图标**必须在 64px 下也检查**（真实 Dock tile 就是这个尺寸）——
   做一张 128/96/64px 三档 + 模拟 Dock 条的对比图给用户挑风格，比只给大图有效得多。
4. **拿到确认再 apply**。这是改系统偏好，不能擅自动手。
5. 收尾再出一张「真实 Dock 顺序预览」（按 `persistent-apps` 顺序逐个渲染图标拼成 Dock 条），
   用户一眼确认位置，不用自己数。最后 `present_files`。

## 必须照抄的技术点（每条都是踩坑换来的）

1. **设文件夹自定义图标 → 必须用 AppKit 官方 API**
   ```javascript
   const img = $.NSImage.alloc.initWithContentsOfFile(pngPath);
   $.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, folderPath, 0);
   ```
   ⚠️ **不要手写 `Icon\r` + `SetFile -a C`**：那样 `xattr` 会显示
   `com.apple.FinderInfo` 里 kHasCustomIcon(0x04) 已置位、`file` 也认它是合法 icns，
   **但 IconServices 渲染不出来，Dock 上仍然是蓝色文件夹**。实测对比过。

2. **Finder 自动化被 TCC 拦截**（`tell application "Finder"` 一律 `-10004 权限违例`），
   建/解析别名全走 Foundation：
   - 建：`NSURL.writeBookmarkDataToURL:options:error:` +
     `bookmarkDataWithOptions:...` 带 **1024**（SuitableForBookmarkFile）
   - 解析：`NSURL.URLByResolvingAliasFileAtURLOptionsError:`（**类方法**，256 = WithoutUI）
   - 比 `ln -s` 干净：symlink 在 Finder 里有小箭头角标，真别名没有

3. **取 App 图标**：`NSWorkspace.iconForFile:`（JXA），能处理 Assets.car，
   比翻 `Contents/Resources/*.icns` 可靠。按名字找 App 用
   `NSWorkspace.fullPathForApplication()`（能覆盖 Safari 这类不在 /Applications 里的系统 App）。

4. **写 Dock 不能直接改 plist 文件**（cfprefsd 会覆盖，`killall Dock` 后改动消失）。
   正确：`defaults export com.apple.dock -` → plistlib 改 → `defaults import com.apple.dock -` → `killall Dock`。
   - 文件夹 Stack：`tile-type=directory-tile`、**`displayas=0`**、`showas=2`、`arrangement=1`
   - App tile：`tile-type=file-tile`、`file-type=41`、`bundle-identifier`、`file-label`、
     `file-data{_CFURLString,_CFURLStringType:15}`，以及 **`book`**
     （bookmark 二进制，magic `book`，可用 JXA `bookmarkDataWithOptions:...:error:` 生成再 base64 回传）
   - 写之前先备份 plist

5. **文件夹是唯一事实来源**。让用户往 `~/Dock Groups/<组名>/` 里拖 App
   （⌘⌥ = 建别名，直接拖是**移动**，会真把 App 搬出 /Applications —— **必须警告**），
   再 `rebuild`。配置里的 `apps` 只当首次播种用。

6. **位置：写进 `persistent-apps` 就是左侧，`persistent-others` 就是右侧。**
   落位用「自动落位」最省事：折叠前该组第一个 App 在原列表里的下标，就是文件夹该插的位置——
   视觉上直接顶替原 App，不用手工配锚点（`after` 字段可显式覆盖）。

7. **左侧 App 区要「点击弹网格」→ 必须做成启动器 App**（`scripts/launcher/main.swift`）：
   - `swiftc -swift-version 5 -O -o <app>/Contents/MacOS/<exe> main.swift -framework Cocoa`，
     CLT 自带，不需要 Xcode。源文件必须叫 `main.swift`（顶层代码）。
   - `Info.plist`：`LSUIElement=true`、`CFBundlePackageType=APPL`、`CFBundleIconFile=AppIcon`，
     并把分组文件夹路径塞进自定义键（如 `DockGroupFolder`），App 运行时现读
     → 内容变化不用重编译，只重建图标。
   - 编译后 `codesign --force --sign - <app>` + `lsregister -f <app>`。
   - **面板层级陷阱（最容易白忙一场）**：`NSPanel.isFloatingPanel = true` 会把 `level`
     **重置为 3**（NSFloatingWindowLevel），而 Dock 的层级是
     `CGWindowLevelForKey(.dockWindow)` = **20** —— 实测「先设 `.popUpMenu`(101) 再设
     isFloatingPanel」结果为 3，面板会被 Dock 压住，且因为是否重叠取决于点击点在图标上的
     高低位置，表现为「**有时被挡、不是每次**」。
     **只显式设 `level = .popUpMenu`，绝不碰 `isFloatingPanel`。**
   - 定位：`NSEvent.mouseLocation`（点击瞬间 ≈ Dock 图标中心），
     `y = max(mouse.y + 14, visibleFrame.minY + 8)`，x 也 clamp 进 `visibleFrame`
     —— 用 `visibleFrame` 而非 `frame`，这样面板永远不压到 Dock（侧边 Dock 同理）。
     早期用 `screen.frame` 会让面板往 Dock 里扎 30pt 左右。
   - 关闭：`NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])`
     → terminate（全局监听不会收到自己的点击，所以面板内按钮正常工作）
     + `didResignKeyNotification` 兜底 + `cancelOperation` 接 Esc。
   - 已运行时再次点击图标 → 实现 `applicationShouldHandleReopen` 重新显示面板。

8. **可观测性（无 GUI 权限时唯一能验证的手段）**：
   让 App 把面板 frame / 屏内判定 / 条目数 / level 对比 / 是否避开 Dock 写成日志文件。
   要复现「鼠标在 Dock 上」的场景，用 `CGWarpMouseCursorPosition`（JXA 里
   `$.CGWarpMouseCursorPosition($.CGPointMake(x, h - appkitY))`，注意 CG 坐标原点在左上）
   把光标瞬移到 Dock 图标高度再启动 App —— 无法手动点击时这是唯一办法。测完记得复原。

9. **拼贴图标在 64px 下的可读性**（踩过）：
   - 半透明淡底 + 无边框 = 64px 时容器消失，几个图标散成一堆 → **不要用**。
   - 无底板的纯拼贴 / 纯描边框 = 同上失败。
   - 能用的只有两种：**实心卡片**（白/浅灰底 + 细边 + 投影）或**实心深色玻璃**。
   - 单个 App 图标占文件夹边长取 **0.44**、内边距 0.085、间距 0.045 最舒服。
   - 画布保持留白 7.5%，与普通 App 图标 86.5% 的内容占比对齐，放进 Dock 才不显大。
   - 注意：作为 **App** 放进 Dock 时，系统会把图标归一化到 86.5% 内容框
     （我们的原图是 89.9%），所以渲染结果与合成图会有约 18% 像素差异 —— **这是正常的**，
     归一化后反而和邻居更统一。

## 环境须知

- 用 `/usr/bin/python3`（系统自带 Pillow）。托管 Python 可能**没有** PIL。
- macOS 26 已移除 `/System/Library/Fonts/PingFang.ttc`；
  中文渲染改用 `/System/Library/Fonts/Hiragino Sans GB.ttc`（index 2 = W6）。
- **本机常见权限拦截**（会显著影响方案设计）：
  - `screencapture` 报 `could not create image from rect` → 别指望截图验证
  - `tell application "Finder"` 报 `-10004` → 别用 Finder 自动化
  - `launchctl` 全部 I/O error → 监听类方案只能生成 plist，让用户在自己终端执行一次
  - `killall iconservicesd` 会把当前命令连带打死（exit 137）→ 别用

## 排障

| 现象 | 处理 |
|---|---|
| 点击打开的是 Finder 窗口 | 用的是文件夹 Stack 却在左侧 → `placement` 改 `left` 后 `apply` |
| 点击没反应 | `test <组名>` 手动跑一次，看 `<落盘>/.cache/<组名>.launch.log` |
| 弹出栏被 Dock 挡住 | `isFloatingPanel` 把 level 压到 3 了 → 重跑 `apply` 重新编译 |
| 图标没跟着文件夹内容变 | `rebuild`；装了 watch 看 `launchctl list \| grep dockgroup` |
| Dock 条目被系统丢弃 | `restore` 回滚，改手动把 App 拖回 Dock |
| 想彻底撤销 | `dockgroup.py restore` |
