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

**先装一次短命令**，之后所有操作都用 `dg`，不用再敲长路径：

```bash
mkdir -p ~/.local/bin
printf '#!/bin/bash\nexec /usr/bin/python3 "%s/scripts/dockgroup.py" "$@"\n' "$PWD" > ~/.local/bin/dg
chmod +x ~/.local/bin/dg          # 确认 ~/.local/bin 在 PATH 里
```

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
dg list / open / test / logs / remove / clean / watch-install / restore
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
    - 尺寸：图标 64、格子 96×104、内边距 20、间距 10。
      **格子别收到 80** —— 「DSH Desktop」会被截成「DSH Deskt...」。
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
      `panel: material=[hud] dark=true window=NSAppearanceNameAqua`，`ShineView`
      首次绘制写 `shine: dark=true appearance=DarkAqua`。面板发白时先看这两行，
      能立刻区分「材质没传对」「外观没跟上」和「二进制压根没换」。

## 环境须知

- 用 `/usr/bin/python3`（系统自带 Pillow）。托管 Python 可能**没有** PIL。
- macOS 26 已移除 `/System/Library/Fonts/PingFang.ttc`；
  中文渲染改用 `/System/Library/Fonts/Hiragino Sans GB.ttc`（index 2 = W6）。
- **本机常见权限拦截**（会显著影响方案设计）：
  - `screencapture -l <窗口号>` / `-R x,y,w,h` **是可用的**（2026-09-15 实测）。
    报 `could not create image from rect` 基本是 `-R` 参数格式写错。区域坐标用
    「屏幕左上角为原点」，和 `CGWindowBounds` 一致。**判材质/圆角只认 `-R`。**
  - `tell application "Finder"` 报 `-10004` → 别用 Finder 自动化
  - `launchctl` 全部 I/O error → 监听类方案只能生成 plist，让用户在自己终端执行一次
  - `killall iconservicesd` 会把当前命令连带打死（exit 137）→ 别用

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
| 改了 `main.swift`，rebuild 后界面没变 | 第 20 条。先看 `.cache/<组名>.events.log` 的 `panel:` / `shine:` 两行；强制重编：`rm -f ~/Dock\ Groups/.cache/.launcher.src-stamp` 再 `dg rebuild` |
| 点 Dock 图标看到的还是旧面板 | ① `.cache/<组名>.events.log` 里没有 `panel:` 行 = 跑的是旧二进制（rebuild 一次）② `winlist` 的窗口尺寸和布局常量算出来的对不上 = 陈旧进程（第 19 条） |
| 拖 App 上去 Dock 图标不高亮 | 检查 Info.plist 有没有 `CFBundleDocumentTypes`（`com.apple.application`），并确认 `lsregister -f` 注册过 |
| 拖一次却加了两遍 / Dock 莫名重启两次 | 同一拖放事件会被送两次 → 见技术点 13 的去重；`dg add` 无新增时应零副作用 |
| 想先看面板长什么样再动系统 | `DOCKGROUP_RENDER=/tmp/x.png <组名>.app/Contents/MacOS/DockGroupLauncher`，直接出 PNG，不动 Dock |
| 图标没跟着文件夹内容变 | `rebuild`；装了 watch 看 `launchctl list \| grep dockgroup` |
| Dock 条目被系统丢弃 | `restore` 回滚，改手动把 App 拖回 Dock |
| 想彻底撤销 | `dockgroup.py restore` |
