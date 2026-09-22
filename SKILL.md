---
name: macos-dock-folders
description: 把 macOS Dock 里的一堆 App 折叠成可点击展开的图标，或整理/去重 Dock 布局。当用户说"Dock 图标太多/太挤"、"想在 Dock 里建文件夹"、"像手机那样分组应用"、"Dock 整理"、"Dock 图标大小统一"、"Dock 位置不对"时使用。含现成工具：实时合成 2×2 拼贴图标 + 写入 Dock + 自动监听 + 一键备份恢复 + 图形界面（dg gui）。
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

**先装一次短命令**，之后所有操作都用 `dg`，不用再敲长路径：

```bash
mkdir -p ~/.local/bin
printf '#!/bin/bash\nexec /usr/bin/python3 "%s/scripts/dockgroup.py" "$@"\n' "$PWD" > ~/.local/bin/dg
chmod +x ~/.local/bin/dg          # 确认 ~/.local/bin 在 PATH 里
```

> **装不上 / 打不开时先看这条**：如果源码是从 zip 下载来的（不是 `git clone`），
> 每个文件都带 `com.apple.quarantine`，生成的 `.app` 会继承它，双击被 Gatekeeper
> 拦下报「无法验证开发者」。**这不是签名坏了** —— 清掉标记就能开：
> 双击 `tools/install.command`（清隔离 + 装 dg + 体检一条龙，**不会覆盖已有的 dg**），
> 或在仓库根目录 `xattr -cr .`。
>
> **给普通用户的最简路径**（v1.3.0+）：Releases 里的 `DockGroup-vX.Y.Z-macos.zip`
> 解压出 `DockGroup.app`，放行一次 Gatekeeper 即可 —— 它自带 universal 引擎和
> 预编译启动器/管理窗口，双击时自安装（`~/.local/bin/dg` +
> `~/Library/Application Support/DockGroup/`）并打开管理窗口，**不需要 CLT /
> Python / Pillow**；重复双击 = 幂等升级。
>
> 本项目用 **ad-hoc 签名**（`codesign -s -`）：没有 Apple 开发者账号（$99/年），
> 所以不做签名与公证。ad-hoc 本机自用完全够 —— 从网络下载的 `.app` 首开会被
> Gatekeeper 拦一次（`DockGroup.app` 也一样）。放行方法**分版本**：macOS 14 及
> 更早右键 →「打开」；**macOS 15+（含 26）右键旁路已被移除**，要么去系统设置 →
> 隐私与安全性 → 底部「仍要打开」，要么 `xattr -cr` 清标记。构建流程每次都会清
> 一遍隔离标记兜底；`dg doctor` 末尾会报告签名身份和产物隔离状态。

```bash
dg                      # 不带参数 = 帮助 + 当前分组状态
dg doctor               # 先体检依赖
dg init                 # 扫描当前 Dock 生成起始配置
dg new  AI "App1" "App2"
dg add  AI "App3"       # 往已有分组加 App（自动刷新图标 + 重启 Dock）
dg del  AI "App3"       # 从分组删 App（只删别名；真实 App 会拒绝）
dg preview [组名]       # 只合成图标预览，不动 Dock —— 改前必跑
dg apply   [组名]       # 生成并写入 Dock
dg rebuild              # 全部重新生成图标并重启 Dock
dg gui                  # 图形界面（分组管理窗口）
dg list / style / layout / open / test / logs / remove / clean / watch-install / restore
```

> **交互模式（用户不想敲名字时）**：`dg add` / `dg new` **不带参数**直接回车，
> 就进入引导 —— 列分组、列全部已安装 App，输关键词过滤、敲数字多选、回车确认。
> `new` 还会在建完后问「直接写进 Dock？」，一步到位。已在组里的 App 标记
> `·已在该组` 并自动跳过。纯 `input()` 实现，无新依赖；非终端环境（管道/脚本）
> 会自动退回带参数的用法提示，不会死循环。

> **`add` / `del` 是日常唯一需要的两条。** 它们内部走完
> 「建别名 → 同步 `groups.json` → 重建拼贴图标 → 重启 Dock」整条链。
> 所以当用户想「往分组里加个 App」时，**别让他去开 Finder 拖拽再手动 rebuild** ——
> 一条命令就够。App 名支持模糊匹配，`dg add AI chro` 能加上 Google Chrome。
>
> `del` 有安全防护：只 `unlink` 文件（别名），条目若是目录（真实 App）会跳过并提示。

> **图形界面（用户明确说"不想敲命令行"时首选这条）**：`dg gui` 打开管理窗口 ——
> 左栏切分组 / 开关是否进 Dock / 新建分组；中栏看成员、从 Finder 拖 `.app` 进来、
> 悬停点 `−` 移除；右栏换图标风格、面板材质、面板排列，**改完立刻重算预览图**；
> 底栏应用到 Dock / 移除 / 删除 / 看引擎输出。
> 第一次跑要编译打包（十来秒，`swiftc` 编 `scripts/manager/main.swift`），之后走缓存秒开；
> 改过窗口源码要 `dg gui --rebuild`。
>
> 三条要记住的设计：
> ① **外观改动不写 Dock** —— 预览是即时重算拼贴图标的，点「应用到 Dock」才落地，
>    所以 7×13×4 种组合可以随便试而不闪 Dock；
> ② 增删 / 应用 / 移除 / 回滚**一律转发给本脚本**，只有外观三项直接写 `groups.json`
>    （为了即时预览），两边逻辑和文件格式逐字节一致（`DockGroupManager --dump-config`
>    可以验证往返，见下）；
> ③ 它是普通 App（有 Dock 图标，不设 `LSUIElement`），和每分组一个的分组启动器不是一回事，
>    产物在 `~/Dock Groups/.apps/DockGroup.app`。

> ⚠️ **改了布局或材质、点开面板却没变化？先怀疑「旧的面板进程还活着」。**
> 启动器收起后要**常驻一小段时间**才退出（立刻退会让 Dock 报「应用程序已不能再打开」，
> 见 `launcher/main.swift` 里 `kIdleSeconds` 的注释）。而它的面板几何、材质、成员清单
> 都是**进程启动时**从 `Info.plist` 读进内存的 —— 之后把 bundle 重建十遍也影响不到
> 那个已在跑的进程；点 Dock 图标时 LaunchServices 走 reopen，还是回到它。
>
> 判断：`pgrep -lf DockGroupLauncher`（有输出就是有残留）；清掉：`pkill -f DockGroupLauncher`。
>
> 2026-09-20 实测踩过：全局 layout 从 `dock` 改成 `auto`，`groups.json` 和
> `AI.app/Contents/Info.plist` 里都已经是 `auto`，`apply` 也确实重建了 bundle，
> 但点开面板仍是 242×69 的 dock 条 —— 同一个 cache 目录里「浏览器」组却是新的
> 211×239，区别只在于它那个旧进程已经自己退出了。
>
> 现在 `apply` / `rebuild` / `add` / `del` 都会走 `kill_launchers()` 自动收拾干净，
> 但**手工改 bundle、或直接改 Info.plist 不会**，那时要自己 `pkill`。

> ⚠️ **「不管选哪个排列版本，某个分组永远是同一种」？先查它有没有分组级覆盖。**
> `groups.json` 里分组可以自带 `layout` / `style` / `material`，**优先级高于全局**。
> 命令行：`dg layout <组名> <模式>` 加覆盖、`dg layout <组名> default` 清掉。
> 管理窗口里这类分组会标一个橙色滑块图标，右栏写明覆盖了什么并给「改回跟随全局」按钮。
>
> 2026-09-20 修的相关缺陷：管理窗口的 `save()` 原先把内存里的 `groups` **整体覆盖**
> 磁盘文件 —— 引擎给某分组加了覆盖、GUI 内存里随后也有了之后，用户在 GUI 里改**全局**
> 排列会把那份分组覆盖又写回去，于是全局怎么改都盖不过它，而且当时 GUI 根本不显示
> 分组级覆盖，完全无从排查。现在 `save()` 默认只写外观三项、**分组结构以磁盘为准**
> （要动结构得显式 `refreshGroups: true`），写完还会把内存对齐到磁盘。
> **教训：拿内存快照整体覆盖共享文件，迟早踩到。**

## 标准流程

1. **读现状**：`dg list`，或 `defaults read com.apple.dock persistent-apps` + percent-decode。
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
     → terminate（全局监听不会收到自己的点击，所以面板内按钮正常工作），
     但**必须加命中判断**：`if panel.frame.contains(NSEvent.mouseLocation) { return }`，
     否则面板内的点击有概率被当成「点外面」而直接退出。
     + `didResignKeyNotification` 兜底 + `cancelOperation` 接 Esc。
   - **格子不要用 NSButton**：在「非激活 App + 非激活面板」里，
     `acceptsFirstMouse` 语义可能吞掉第一次 `mouseDown`（表现为「点图标没反应」）。
     换成自绘 `NSView` 子类自己接 `mouseDown(with:)`，并显式
     `override func acceptsFirstMouse(for:) -> Bool { true }`、
     `override var mouseDownCanMoveWindow: Bool { false }`。
   - **不要在 `mouseEntered` 里才开 layer backing**（`wantsLayer = true`）：
     跟踪过程中切换 layer-backed 会让 AppKit 重建视图层级，可能打断鼠标跟踪。
     `wantsLayer` / 圆角 / 背景色都在 `init` 里设好，事件回调只改颜色。
   - 启动用 `NSWorkspace.openApplication(at:configuration:completionHandler:)`
     并在回调里再 `terminate`；不要 `open(url)` 后立刻 `terminate`，也别忘记兜底定时器。
   - **自检入口**：加一个环境变量（如 `DOCKGROUP_SELFTEST=<下标>`）启动后直接调用
     和点击完全相同的 pick(index)，就能把「启动链路」和「点击送达」两个问题分开定位。
     注意 `open` 不继承 shell 环境变量，要**直接跑 `Foo.app/Contents/MacOS/Foo`** 才能传入。
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

10. **弹出面板里「每个格子加底块」是错的**（实测三种版式出图比对）：
    - 每格加深灰圆角底块 + 描边 → 像一张表格，视觉很重 ❌
    - 每格加白色磨砂底块 → 像一排白瓷片，与浅色玻璃糊在一起 ❌
    - **不加底块，只有图标 + 标签** → 和原生 Dock Stack 一致，最干净 ✅
    - 尺寸（**以 `main.swift` 顶部常量为准**）：图标 `kIcon 58`、格子高 `kCellH 100`、
      内边距 `kPad 16`、间距 `kGap 7`。格子**宽度按布局分叉**：长条 `kCellW 86`、
      网格 `kCellWGrid 100`（网格要正方形，见第 21 条）。
      **格子别收到 80** —— 「DSH Desktop」会被截成「DSH Deskt...」。
      超长名字（`Numbers Creator Studio`、`Google Chrome`）在两种宽度下都会截断。
    - 换行时**每行单独居中**：最后一行不满还左对齐会明显歪。
    - 悬停高亮靠 `ItemView` 的 layer 圆角底（浅色模式淡黑、深色模式淡白），
      不要把底块画成常显的。

11. **「有个弹出窗口关不掉」的两个真凶**（都踩过）：
    - ① **重建面板时不 close 旧面板**：`afterAdd` 刷新网格会 `buildPanel`，
      只创建新面板而旧面板没关 → 旧窗口留在屏幕上，而关闭回调指向 `self.panel`
      （已是新面板）→ 那个旧窗口谁都关不掉。**必须 `panel?.close()`**。
    - ② **全局监听把「Dock 条上的点击」一律忽略**：本意是留给 Dock 的 reopen
      做展开/收起切换，结果点 Dock 上任何别的地方面板都不收 ——
      面板 level 是 101（`.popUpMenu`）压在所有窗口之上，就成了「赖着不走的窗」。
      正确做法：记下展开时的鼠标位置当**锚点**，只有点在锚点
      （自己的图标，约 ±44×±60）附近才放行给 reopen，其余 Dock 区点击一律收起。
    - 另外面板重建后要把 `didResignKey` 观察者**重挂到新面板**，
      挂在初始面板上等于新面板永远收不起来；重建前先 `removeObserver` 再关旧面板，
      否则那次关闭会触发 `hidePanel` 把 `shown` 状态搅乱。
    - `NSWindow.isReleasedWhenClosed` 对程序化创建的面板要显式设 **false**：
      面板被属性强引用着，让系统再 release 一次就是野指针（且释放时机是
      「当前事件结束后」，极难复现）。

12. **视觉验证：真机截图优先，离屏渲染只用来比版式**（这一条 2026-09-15 修正过 ——
    之前误以为截图被系统拦，其实只是 `-R` 参数格式写错了）。
    - **`screencapture -l <窗口号>` 和 `-R x,y,w,h` 在本机都能用。** 取窗口号：
      `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`，
      按 owner 名过滤（owner = Info.plist 的 `CFBundleName`，也就是组名）。
      **现成工具在 `scripts/winlist.swift`**：
      `swiftc -O -o /tmp/winlist scripts/winlist.swift -framework Cocoa && /tmp/winlist AI`
    - **判材质、判圆角必须用 `-R`（屏幕合成），不能用 `-l`（窗口本体）。**
      `-l` 拿不到窗口阴影，更要命的是 `.behindWindow` 毛玻璃在 `-l` 里会退化成
      不透明色块 —— hud 材质用 `-l` 看是深灰、用 `-R` 看可能还是浅的。
      **只信 `-l` 会得出完全错误的材质结论。**
    - 离屏渲染（`DOCKGROUP_RENDER=<png>`）仍然有用：不用真弹窗、能一次编译多个变体
      批量出图比版式。但它看不到窗口阴影和材质真身，**只能比布局，不能定材质**。
      实现：`cacheDisplay` 画进 bitmap，叠「模拟壁纸 + Dock 条 + 材质替身」写盘。
      注意 `open` 不继承环境变量，要**直接跑 `Foo.app/Contents/MacOS/Foo`**。

13. **拖放（把 Finder 里的 App 拖到 Dock 分组图标上）**：
    - Dock **不允许**「Dock 图标拖到 Dock 图标上」——拖动 Dock 图标时整个会话被
      Dock 接管（只能排序/拖出移除），没有任何 API 能给第三方。想要那种交互
      只能接管整个 Dock（Dockish 之类）。但「Finder 里的文件 → Dock 上的 App 图标」
      是系统支持的，走 **kAEOpenDocuments** 苹果事件。
    - 实现：delegate 的 `application(_:openFile:)`（签名是**单个** String，返回 Bool）
      与 `application(_:open urls:)` 都收，攒进集合后统一提交；Info.plist 里要有
      `CFBundleDocumentTypes` 声明 `com.apple.application`（`LSHandlerRank=Alternate`
      即可，不会变成 .app 的默认打开方式），否则 Dock 上不会高亮成放置目标。
    - **同一个拖放事件会被送两次**（实测相隔 7 秒），光靠短合并窗口挡不住：
      要按「同一批路径 + 10 秒内」去重；并且让 `dg add` 在**没有新增**时直接返回、
      不刷新不重启 Dock，这样重复事件退化成廉价空操作。
    - 启动器要回调 Python 脚本，脚本绝对路径由 Info.plist 的
      `DockGroupScript` 传进去（GUI 进程 PATH 只有 `/usr/bin:/bin`，别指望 `dg`）。

14. **面板「四角有尖尖的一块」= 圆角只裁到了 contentView**（用户直接反馈的坑）：
    - `NSVisualEffectView.layer.cornerRadius` + `masksToBounds` 只裁得到**视图自己
      画的像素**。窗口阴影和 `.behindWindow` 那层毛玻璃归窗口服务器管、画在 layer
      内容**之下**，够不着 —— 四个角就各露出一个直角块。
    - 三重修法，缺一不可：
      ① `contentView.superview`（theme frame）也设 `cornerRadius` + `masksToBounds`，
         再调 `window.invalidateShadow()` 让系统按新形状重算阴影贴图；
      ② 给毛玻璃设 **`maskImage`**（黑色圆角矩形：不透明处才显示毛玻璃）——
         这是唯一能裁掉 behindWindow 模糊的公开手段；
      ③ `window.isOpaque = false` + `backgroundColor = .clear`。
    - 验证只能靠 `-R` 区域截图（见第 12 条），`-l` 窗口截图里看不出来。

15. **深色材质必须把 `appearance` 设在毛玻璃视图自己身上**（踩过）：
    - 只在 `NSWindow.appearance` 上设 `.darkAqua`，`material = .hudWindow` 照样会按
      **浅色**外观解析成浅色玻璃，动态色（`labelColor` 等）也不翻白 —— 整块面板
      和 `menu` 肉眼几乎没区别，白标签还会压在浅底上消失。
    - 正解：`bg.appearance = NSAppearance(named: .darkAqua)`，且在设 `material` 之前
      设好；子视图会继承，动态色随之翻白。
    - 离屏渲染图看不出这个坑（毛玻璃在离屏里退化成透明），**只有 `-R` 真机截图能发现**。
    - 顺带：面板底色是深是浅，要和**材质**绑定而不是绑系统外观 —— 深色玻璃上的
      文字色得手动指定（`white α0.78`），不能指望 `secondaryLabelColor`。

16. **`bundle-stamp` 缓存会让「手动改过的 bundle」卡住**（踩过）：
    - `build_launcher_app` 按内容摘要（摘要含 `DockGroupMaterial`）决定要不要重写
      bundle。一旦手动改过 Info.plist / 换过二进制，戳记和实际内容就对不上了，
      下一次 `rebuild` 会算出「与戳记相同」而**跳过重写**，看起来就是「改了没生效」。
    - 处理：`rm -f ~/Dock\ Groups/.cache/*.bundle-stamp` 再 `dg rebuild`。

17. **材质是「分组覆盖全局」而不是纯全局**（`group_material()`）：
    分组自己写了 `material` 就用自己的，没写才退回 `groups.json` 顶层的默认值。
    历史坑：早先只读顶层 `cfg["material"]`，分组里写 material 是被静默忽略的。
    想全局定基调就 `dg style --all hud`，想给个别分组单独换就 `dg style 组名 menu`。

18. **`blendingMode = .behindWindow` 的面板会随背后内容忽深忽浅，必须盖匀色底**
    （2026-09-15，用户说「UI 还是很丑」后查出来的根因）：
    - 毛玻璃实时采样窗口**背后**的内容。面板弹在任意窗口之上，背后左边是深色终端、
      右边是浅色桌面时，玻璃就左半边深、右半边浅，**看起来像被劈成两半**。
      实测同一块面板内部亮度从 50 平滑爬到 154 —— 是材质的正常行为，不是渲染 bug。
      系统 Dock 也这样，但 Dock 背后永远只有壁纸；我们的面板背景不可控。
    - 修法：在材质之上叠一层半透明**匀色底**（`ShineView` 里 `outer.fill()` 那一笔），
      深色材质压黑、浅色材质压白，即「提高不透明度」而不是「染色」，不偏离材质色相。
      `kPanelTint = 0.5` 实测把全宽亮度差从 104 压到 ≤3，两种外观都验过。
    - 试过但**不行**的：`blendingMode = .withinWindow` —— hud 材质在这个模式下
      反而渲染成**浅灰**（实测），观感直接跑偏。
    - `ShineView` 层本身是必需的：`NSVisualEffectView.draw(_:)` 由系统实现，
      覆写它会把毛玻璃一起干掉，所以装饰必须叠成子视图，并让 `hitTest` 返回 nil
      以免吃掉点击（空白处点击要靠它下面的背景视图收到）。

19. **别被「陈旧进程」骗走半小时**（踩过）：
    直接跑 `Foo.app/Contents/MacOS/Foo` 做视觉验证时，如果上一轮的进程还在（面板
    还挂在屏幕上），截到的图可能是**旧构建**画出来的 —— 表现为「明明改了代码/plist
    却毫无变化」。判据：`/tmp/winlist` 输出的窗口**尺寸**。窗口宽高由布局常量算出
    （`kPad*2 + cols*kCellW + (cols-1)*kGap`），尺寸对不上就说明跑的不是当前构建。
    每次截图前先 `pkill -f DockGroupLauncher; sleep 1` 并确认 `pgrep` 为空。

20. **改了 `main.swift` 但 `rebuild` 根本不重编译 —— 最隐蔽的一层「没生效」**
    （2026-09-15，用户报「AI 文件夹还是那个样子」的根因）：
    - 原判据是 `src.stat().st_mtime > exe.stat().st_mtime`。但 `codesign --force
      --sign -` 会把签名写进 Mach-O（`__LINKEDIT`），**改动可执行文件本身** ——
      exe 的 mtime 因此永远比 `main.swift` 新。也就是说，**第一次签名之后这个判据
      就永久失效了**。
    - 表现极具迷惑性：改完 UI 跑 `dg rebuild`，它照样打印「已刷新：AI, 办公 …
      （Dock 已重启）」，但压根没调用 `swiftc`；Dock 上点开还是旧面板。而 exe 的
      mtime 是刚刚的，**光看时间戳完全看不出问题**（第 19 条那种「陈旧窗口尺寸」
      判据仍然有效，因为尺寸来自布局常量）。
    - 正解：判据换成**源码内容摘要**，戳记另存 `CACHE/.launcher.src-stamp`，跟被
      签名的产物彻底解耦，见 `launcher_binary()`。同时把二进制也纳入 bundle 的
      内容摘要 —— 否则会出现「源码变了、戳没变」而跳过拷贝。
    - 顺带修掉一个浪费：启动器所需的全部信息（分组名 / 文件夹 / 材质 / 脚本路径）
      都在 Info.plist 里，**二进制与分组无关**。现在一份编译产物给所有分组共用，
      rebuild 从「编译 N 次」变成「编译 1 次」（3 个分组：20s → 6.4s）。
    - 排查入口：面板每次构建会往 `.cache/<组名>.events.log` 写一行
      `panel: layout=[auto] entries=4 grid=2x2 size=211x239 material=[hud] dark=true
      window=NSAppearanceNameAqua`，`ShineView` 首次绘制写
      `shine: dark=true appearance=DarkAqua`。面板发白先看 `material`/`window`，
      网格不对先看 `layout`/`grid`/`size` —— 一行就能区分「配置没传进来」
      「列数算错」「材质没传对」「外观没跟上」和「二进制压根没换」。

21. **面板排列：默认长条，网格是可选项**（2026-09-20 定，用户直接反馈促成的）：
    - 起因：用户说「点击后只显示长条形的框」，想要手机那种四宫格 / 九宫格。
      根因是列数写成 `let cols = min(kMaxCols, n)`（`kMaxCols = 4`）——
      **n ≤ 4 时 cols 恒等于 n、rows 恒为 1**，换行代码（rows / 末行居中）早就写好了
      但永远触发不到。实测三个分组（4/4/3 个 App）点开全是单行长条。
    - 改完我先上了 `auto` 当默认，用户看了实机又要求**改回长条当默认**，理由是
      「四宫格都不像正方形，和手机对比感觉不太美观」。所以最终形态是：
      **`row` = 默认**（字面上就是原来的 `min(kMaxCols, n)`，长条观感一字不变）、
      **`auto` / 数字 = 可选项**，用 `dg layout --all auto` 才开。
    - `auto` 规则：1→1×1，2→2×1，**3~4→2×2 四宫格**，5~6→3×2，
      **7~9→3×3 九宫格**，≥10→按 `kMaxCols` 换行兜底。
      **1~2 个故意不用 2×2**：容器 239pt 高而只装 1~2 个图标，下半截空着像没加载完。
    - ⚠️ **「不像正方形」的修法是几何按模式分叉**：
      - 图标 `y = H - 12 - 58`、标签 `y = 10` 高 15，**都从格子底部量** →
        `kCellH` 最小 = 25+58+12 = **95，压不下去**。格子 86×100 本是竖长方形，
        2×2 面板必然 211×239，就是用户说的「不像正方形」。
      - 所以 `kCellWGrid = 100`（**必须等于 `kCellH`**）：`geometry(for:)` 里
        长条模式用 `kCellW 86`、网格模式用 `kCellWGrid 100` →
        2×2 = 239×239、3×3 = 346×346，都是正方形。
      - 长条模式保持 86 不动 —— 用户明确要「保留原本长条式」，改了就不叫原本了。
    - 尺寸公式：`w = kPad*2 + cols*cellW + (cols-1)*kGap`；
      `h = kPad*2 + rows*cellH + (rows-1)*kGap`，见 `PanelGeometry.panelSize`。
    - **`showPanel()` 不用改**：本来就有上下 clamp（`y + h > vis.maxY - 8` 时整体
      上顶到 maxY 之下），面板从 132 长到 346 也不会顶出屏幕或压住 Dock。
    - `layout` 走「分组覆盖全局」，机制同 `group_material()`；命令 `dg layout`，
      字段 `groups[].layout`。
    - ⚠️ **这套逻辑有三份实现，改一边必须改另外两边**：
      ① Swift 的 `columns(for:layout:)` + `geometry(for:)` —— 真正画面板的；
      ② Python 的 `layout_grid()` + `cell_w_for()` + `panel_size()` —— `dg layout` 预览；
      ③ `tools/readme_assets.py` 的 `draw_panel(cell_w=…)` —— README 配图，
         它直接 import dockgroup 取这些常量/函数，并有一条 assert 卡住常量漂移。
      改完对账：`dg layout` 打印的「n 个 App → 几×几  宽×高」应该和
      `dg logs <组名>` 里 `panel: … grid=…x… size=…x… cell=…x…` 完全一致。

22. **贴着 Dock 尺寸的三档排列：`dock` / `dock-name` / `dock-grid`**（2026-09-20 加，
    用户原话「长条框感觉有些大，改成和 dock 栏一样高度大小看看效果如何」）：
    - **Dock 条多高、图标多大，量出来而不是猜**。本机三个数（Dock 图标 64、底部 Dock、
      1408×881）：
      - `visibleFrame.minY - frame.minY` = **80** —— 系统给 Dock 留的总空间
      - 2x 截图里 Dock 条**上沿 77.5pt、下沿约 5.5pt** → **条高 ≈ 72pt**，多出的 8pt
        是系统留白
      - Dock 里的图标 = **42.5pt**（量 Finder 图标：按「蓝色像素包围盒」求宽高，两个方向
        都是 42.5）。⚠️ `defaults read com.apple.dock tilesize` 报的是 **64**，
        **和实际渲染对不上 —— 以截图为准，别信 prefs**。
      量法：`screencapture -x -R 0,<屏幕高-120>,1408,120`（第 12 条），Pillow 找边缘、
      找图标包围盒；顺带也能核对拼贴图标在 Dock 里被归一化后的真实大小。
    - **72pt 装不下「Dock 大小的图标 + 一行可读的字」**：格子最小
      `4 + 标签13 + 图标42 + 4 = 63`，面板至少 80pt。所以拆成两档而不是硬塞：
      - `dock` —— 条高 72、留白 **14**（和 Dock 条自己的留白节奏一致），
        图标 = 72-28 = **44 ≈ Dock 图标同大**，**不画名字**（改挂 `toolTip = title`，
        走系统原生悬停提示，原生 Dock 也是这个交互）→ 4 个 App = **254×72**
      - `dock-name` —— 让出 8pt 给名字（面板 **80**），图标锁 42 → 4 个 App = **378×80**
      - `dock-grid` —— **无字网格**（同日追加，用户原话「四宫格也需要类似 dock 栏双倍
        高度大小的无字版本」）。格子取正方，并让「两行 = 两倍条高」成立：
        `2*bar = pad*2 + 2*cell + gap` → `cell = bar - pad - gap/2`（bar=72 → **55**），
        图标 = 格子 × 0.8 ≈ **44**（正好又落回 Dock 图标同档）。于是 2×2 = **144×144**：
        既是 72×2，又天然是正方形。行数多了线性长高（6 个 App → 205×144）。
        与 `auto` 的分工：auto 是独立大格子（100）+ 名字，**完全不看 Dock 尺寸**；
        dock-grid 一切从条高推，所以永远和 Dock 成整数倍。
        ⚠️ 真机值会略小于预览值：`dockBarHeight()` 拿的是运行时可用区（本机实测给 **69**，
        不是标称的 72），所以 4 个 App 的真机面板是 **138×138**，而 `dg layout` 里显示的
        是按 `DOCK_BAR_DEFAULT=72` 估的 144 —— 对账时别把这两个数当成不一致。
    - **高度按屏幕实时推算，不写死**：`dockBarHeight()` = `可用区高度 - 8`，夹进
      `[56, 96]`；`reserved ≤ 20`（Dock 隐藏或贴侧边）时退回 72。用户改 Dock 图标大小
      后面板跟着走。Python 侧拿不到屏幕尺寸，只用 `DOCK_BAR_DEFAULT = 72` 做**预览估算**。
    - `PanelGeometry` 为此多了 `icon` / `showLabel` / `iconInset` / `labelY` 四个字段：
      **图标尺寸不再是全局常量 `kIcon`**，`ItemView` 要把整份几何带进来 ——
      否则 dock 模式会按长条模式的 58pt 画。
    - 面板日志加了 `icon=… label=…`，专治「图标大小 / 名字有没有按模式走」。
    - 想比不同尺寸而不动真机 bundle：`cp -R` 一个 `.app` 到 /tmp、拿 `PlistBuddy`
      改 `DockGroupLayout`，再跑 `DOCKGROUP_RENDER` 出图（第 21 条那个手法）；
      要判「和真实 Dock 的关系」就把渲染图按 2x 贴到真机截图上（面板底边落在 88pt）。

## 环境须知

- 用 `/usr/bin/python3`。**Pillow 不是系统自带的**（2026-09-20 实测：加 `-s` 禁掉
  user site 后 `import PIL` 直接 ModuleNotFoundError），得先
  `/usr/bin/python3 -m pip install --user Pillow` 装一次。装进的是 **CLT 那个
  Python 的 user site**（`~/Library/Python/3.9/lib/python/site-packages`），
  所以 Homebrew / venv / 托管 Python 都读不到 —— 解释器必须写死，不能换。
- **判断一个命令行工具是「系统自带」还是「CLT 提供」的判据**（2026-09-21 实测，三条互证）：
  ① `xcrun -f <tool>`：解析回 `/usr/bin/<tool>` 自身 = 系统自带；解析到
  `/Library/Developer/CommandLineTools/...` = CLT 提供（对照：`xcrun -f python3` → CLT 路径）。
  ② 直接看 `/Library/Developer/CommandLineTools/usr/bin/` 里有没有它。
  ③ 系统 shim 的硬链接数很高（`/usr/bin/python3` 是 78），独立二进制是 1。
  **实测结论：只有 `swiftc` 和 `python3` 来自 CLT，`codesign` / `iconutil` / `sips` 都是系统自带。**
  别再把后者说成「随 CLT 提供」—— 它们真缺了说明系统异常，装 CLT 解决不了。
- macOS 26 已移除 `/System/Library/Fonts/PingFang.ttc`；
  中文渲染改用 `/System/Library/Fonts/Hiragino Sans GB.ttc`（index 2 = W6）。
- **本机常见权限拦截**（会显著影响方案设计）：
  - `screencapture -l <窗口号>` / `-R x,y,w,h` **是可用的**（2026-09-15 实测）。
    报 `could not create image from rect` 基本是 `-R` 参数格式写错。区域坐标用
    「屏幕左上角为原点」，和 `CGWindowBounds` 一致。**判材质/圆角只认 `-R`。**
  - `tell application "Finder"` 报 `-10004` → 别用 Finder 自动化
  - `launchctl` 全部 I/O error → 监听类方案只能生成 plist，让用户在自己终端执行一次
  - `killall iconservicesd` 会把当前命令连带打死（exit 137）→ 别用
  - **`dg rebuild` / `dg apply` / `dg layout` 会 `killall Dock`，从沙箱里直跑会被连带
    打死（exit 137、没有任何输出，看起来像命令没执行）**。两个可行姿势：
    ① 带沙箱豁免执行；② 丢后台 + 落日志：
    `( dg layout --all dock > /tmp/dg.log 2>&1 & ); sleep 12; tail /tmp/dg.log`
    —— 判断有没有真的生效别只看退出码，直接查
    `groups.json` / `PlistBuddy -c "Print :DockGroupLayout" <组名>.app/Contents/Info.plist`。

## 排障

| 现象 | 处理 |
|---|---|
| 点击打开的是 Finder 窗口 | 用的是文件夹 Stack 却在左侧 → `placement` 改 `left` 后 `apply` |
| 有个弹出窗口关不掉 | 两个成因都已修：① 重建面板没 close 旧面板（`afterAdd` 刷新时最容易出现）② 全局监听把 Dock 区点击一律忽略。看日志里有没有 `buildPanel: closed previous panel` 和 `window … visible=false`：可见性为 true 的窗口多于 1 个就是又漏关了 |
| 点 Dock 上别的地方面板不收起 | 同上 ②：锚点判断（`click on own dock tile -> ignored` 才是正常放行） |
| 点图标没反应 | `logs <组名>` 看事件轨迹：只有 `=== launch` 说明点击没送达视图；<br>有 `mouseDown` 无 `launching` 说明下标/路径有问题；<br>有 `launching` 但 `openApplication` 报错说明 LaunchServices 拒绝；<br>出现 `dismiss: click outside panel` 说明被误判成点了外面 |
| 弹出栏被 Dock 挡住 | `isFloatingPanel` 把 level 压到 3 了 → 重跑 `apply` 重新编译 |
| 面板四角有直角块 | 圆角只裁到了 contentView。theme frame 也要设 `cornerRadius` + `masksToBounds`、给毛玻璃设 `maskImage`、再 `invalidateShadow()`（第 14 条） |
| 换了 material 但面板没变化 | ① `appearance` 必须设在毛玻璃视图上，只设 window 无效（第 15 条）② 二进制没跟着源码走（第 20 条）：看日志里的 `panel: material=[…]` |
| 面板比 Dock 高一截 | 默认是 `row`（132pt）。`dg layout --all dock` 换成和 Dock 条等高（72pt、无名字，悬停出提示）；`dock-name` 是保留名字的那档（80pt）；`dock-grid` 是**两倍条高的无字网格**（2×2 = 144×144）。三档都按屏幕可用区实时算高度（第 22 条） |
| dock 模式下图标大小 / 名字不对 | 看 `panel: … icon=… label=…`：`label=false` 是 `dock`，`icon` 应当是「条高 - 28」。数值不对 = 二进制没跟着源码走（第 20 条） |
| 改了 `main.swift`，rebuild 后界面没变 | 第 20 条。先看 `.cache/<组名>.events.log` 的 `panel:` / `shine:` 两行；强制重编：`rm -f ~/Dock\ Groups/.cache/.launcher.src-stamp` 再 `dg rebuild` |
| 点 Dock 图标看到的还是旧面板 | ① `.cache/<组名>.events.log` 里没有 `panel:` 行 = 跑的是旧二进制（rebuild 一次）② `winlist` 的窗口尺寸和布局常量算出来的对不上 = 陈旧进程（第 19 条） |
| 排列不是想要的（还是长条 / 没变网格） | 默认就是 `row` 长条。要网格得显式开：`dg layout --all auto`。① 分组自己写了 `layout` 会覆盖全局 → `dg layout` 看每组实际模式（它会打印「n 个 App → 几×几 宽×高」）；② `bundle-stamp` 缓存 → 清掉再 `dg rebuild`；③ 对账 `.cache/<组名>.events.log` 的 `panel: layout=… grid=… size=… cell=…` |
| 四宫格 / 九宫格看着不是正方形 | 网格模式必须用 `kCellWGrid 100`（= `kCellH`，见 `geometry(for:)`）。沿用长条的 86 时 2×2 会变成 211×239 的竖长方形 —— 这就是用户当初要求改回长条默认的原因（第 21 条） |
| 拖 App 上去 Dock 图标不高亮 | 检查 Info.plist 有没有 `CFBundleDocumentTypes`（`com.apple.application`），并确认 `lsregister -f` 注册过 |
| 拖一次却加了两遍 / Dock 莫名重启两次 | 同一拖放事件会被送两次 → 见技术点 13 的去重；`dg add` 无新增时应零副作用 |
| 想先看面板长什么样再动系统 | `DOCKGROUP_RENDER=/tmp/x.png <组名>.app/Contents/MacOS/DockGroupLauncher`，直接出 PNG，不动 Dock |
| 图标没跟着文件夹内容变 | `rebuild`；装了 watch 看 `launchctl list \| grep dockgroup` |
| Dock 条目被系统丢弃 | `restore` 回滚，改手动把 App 拖回 Dock |
| 想彻底撤销 | `dockgroup.py restore` |
