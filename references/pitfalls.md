# 踩坑记录

这些都是实测出来的，不是推测。每一条都附了当时的验证方式，便于复现。

---

## 1. 文件夹自定义图标：手写 `Icon\r` 是行不通的

**网上流传的做法**（写 `.icns` 到 `folder/Icon\r` 再 `SetFile -a C <folder>`）：

```
$ file "AI/Icon"$'\r'
AI/Icon: Mac OS X icon, 591656 bytes, "ic12" type          ← 合法 icns ✅
$ xattr -px com.apple.FinderInfo "AI"
00 00 00 00 00 00 00 00 04 00 00 00 ...                    ← 偏移 8 处 = 0x04 = kHasCustomIcon ✅
```

两处都对，但 Dock 上渲染出来**仍然是蓝色文件夹**。

**正确做法**是 AppKit 官方 API：

```javascript
ObjC.import('AppKit');
const img = $.NSImage.alloc.initWithContentsOfFile(pngPath);
$.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, folderPath, 0);
```

**验证方式**：用 `NSWorkspace.iconForFile:` 渲染该文件夹，再跟合成图做逐像素比对：

```python
ImageChops.difference(rendered, target).getbbox() is None   # True 才算真的生效
```

官方 API 下差异为空；手写 `Icon\r` 下渲染出的是通用文件夹图标。

---

## 2. Finder 自动化被 TCC 拦截 → 别名改走 Foundation

```
$ osascript -e 'tell application "Finder" to get name of startup disk'
execution error: "Finder"遇到一个错误：发生权限违例。 (-10004)
```

连最简单的语句都过不去，所以建别名不能用 `make new alias file`。

- **建**：`NSURL.bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:`
  带 `NSURLBookmarkCreationSuitableForBookmarkFile`（= `1 << 10` = 1024），
  再 `NSURL.writeBookmarkDataToURL:options:error:`（options = 0）
- **解析**：`NSURL.URLByResolvingAliasFileAtURLOptionsError` ——
  这是**类方法**，写成实例方法会得到 `TypeError: ... is not a function`

比 `ln -s` 好在：symlink 在 Finder / Stack 网格里带一个小箭头角标，真别名没有。

顺带一提，`NSURL.writeBookmarkDataToURL` 写出的文件 `file` 会识别为
`MacOS Alias file` —— 确认建对了。

---

## 3. 写 Dock 不能直接改 plist 文件

直接改 `~/Library/Preferences/com.apple.dock.plist` 会被 `cfprefsd` 的缓存覆盖 ——
表面上改动生效了，`killall Dock` 之后又回去了。

正确链路：

```bash
defaults export com.apple.dock /tmp/backup.plist   # ① 备份
# ② 用 plistlib 改这个文件
defaults import com.apple.dock /tmp/new.plist      # ③ 走 cfprefsd 导入
killall Dock                                        # ④ 重启 Dock
```

Python 里对应 `defaults export com.apple.dock -` 读 stdout、
`defaults import com.apple.dock -` 写 stdin。

### 字段速查

| 用途 | 关键字段 |
|---|---|
| 文件夹 Stack | `tile-type=directory-tile`、`displayas=0`（**必须 0**，否则不用自定义图标）、`showas=2`（网格）、`arrangement=1` |
| App | `tile-type=file-tile`、`file-type=41`、`bundle-identifier`、`file-label`、`file-data{_CFURLString, _CFURLStringType:15}`、`is-beta=False`、`dock-extra=False`、**`book`** |
| `showas` 取值 | 0=自动 1=扇形 2=网格 3=列表 |
| `displayas` 取值 | 0=文件夹 1=堆栈 |

### `book` 字段怎么来

Dock 给每个 tile 存一段 bookmark 二进制，magic 是 `book`。可以自己生成，格式一致：

```javascript
const d = $.NSURL.fileURLWithPath(path)
  .bookmarkDataWithOptionsIncludingResourceValuesForKeysRelativeToURLError(0, $(), $(), $());
return ObjC.unwrap(d.base64EncodedStringWithOptions(0));
```

Python 侧 `base64.b64decode` 即可。`GUID` 给个随机 31 位整数就行。

---

## 4. 文件夹放进左侧 App 区：能渲染，但点击不弹网格

**能渲染**：把 `directory-tile` 插进 `persistent-apps` 开头 → `killall Dock` → 回读，条目还在：

```
✅ 保留了    左侧条目数: 15    前 3 条: ['AI', 'App', 'Safari浏览器']
```

**但点击不行**：用户实测——**点击打开的是 Finder 窗口**。

结论：`persistent-apps` → 「打开该项目」；`persistent-others` → Stack 弹窗网格。
这个分支由 tile 所在**区域**决定，没有任何 plist 字段能改。

→ 想左侧 + 点击展开，只能做成真正的 App（见下一节）。

---

## 5. `NSPanel.isFloatingPanel` 会把窗口层级重置为 3

最隐蔽的一个坑。表现出来是「弹出的面板**有时**被 Dock 挡住」。

写个 6 行程序量一下：

```
默认 level                        = 0
设 level = .popUpMenu 之后         = 101
再设 isFloatingPanel = true 之后   = 3      ← 被重置了
Dock 层级 (CGWindowLevelForKey)    = 20
```

`isFloatingPanel = true` 不只是「让面板浮起来」，它会**覆盖你刚设的 level**。
最终面板层级 3 < Dock 的 20，重叠时就被压住。

**为什么是「有时」**：面板位置是 `鼠标y + 14`，点在图标偏上就够高、不碰 Dock；
点偏下就往 Dock 里扎 31pt，然后被盖住。

**改两处**：
1. 删掉 `isFloatingPanel = true`，只显式设 `level = .popUpMenu`
2. 定位改用 `NSScreen.visibleFrame`（已排除 Dock 与菜单栏）：
   `y = max(mouse.y + 14, visible.minY + 8)`，x 同样 clamp

验证（鼠标在 Dock 图标高度时）：

```
修前：面板底边 y=49    Dock 上沿 y=80   → 扎进 Dock 31pt，且层级 3 < 20
修后：面板底边 y=88    Dock 上沿 y=80   → 完全避开，且层级 101 > 20
```

---

## 6. 无法点击时的验证手段

这台机器 `screencapture` 被权限拦截（`could not create image from rect`），
UI 自动化也拿不到权限。所以：

**① 让被测程序自己写日志。** 启动器把面板 frame、屏内判定、条目数、
level 与 Dock 层级对比、是否避开 Dock 全部落到
`<落盘>/.cache/<组名>.launch.log`。没有这个，面板位置对不对完全无从验证。

**② 用 `CGWarpMouseCursorPosition` 制造场景。** 想复现「鼠标在 Dock 上」：

```javascript
ObjC.import('AppKit'); ObjC.import('CoreGraphics');
const h = $.NSScreen.mainScreen.frame.size.height;
$.CGWarpMouseCursorPosition($.CGPointMake(700, h - 35));   // AppKit y=35 ≈ Dock 图标中心
```

注意 CG 坐标原点在左上，AppKit 在左下，要 `h - y` 换算。
先记录原位置、测完复原，别把用户的鼠标留在奇怪的地方。

**③ 用系统自己渲染的结果当 oracle。** 想知道某个图标最终长什么样：
`NSWorkspace.iconForFile:` 渲染成 PNG，再跟期望图逐像素比。

---

## 7. 拼贴图标在 64px 下的可读性

Dock tile 的真实尺寸通常是 64px（`defaults read com.apple.dock tilesize`）。
在 128px 下看着还行的设计，到 64px 会完全塌掉。

**淘汰的方案**（都在 64px 下容器消失、几个图标散成一堆）：

- 半透明淡底 + 无边框
- 无底板纯拼贴
- 纯描边框

**能用的只有两类**：

- 实心卡片（白/浅灰底 + 细边 + 投影）
- 实心深色玻璃

参数（相对文件夹边长）：单个 App 图标 **0.44**、内边距 **0.085**、间距 **0.045**、
画布四周留白 **7.5%**（对齐普通 App 图标 86.5% 的内容占比）。

选风格时一定要按 128 / 96 / 64px 三档 + 模拟 Dock 条一起看，
只给大图会选错。

---

## 8. 作为 App 放进 Dock 时图标会被归一化

同一个拼贴图，作为**文件夹**放进 Dock 和作为 **App** 放进 Dock，渲染结果不同：

```
文件夹：内容占画布 89.9%（原样）
App   ：内容占画布 86.5%（系统归一化到标准 App 图标框）
```

所以逐像素比对会有约 18% 的差异 —— **这是正常的，不是 bug**。
归一化之后反而跟旁边的 App 图标更统一。

---

## 9. 其他环境坑

- **`launchctl` 完全不可用**：`list` 无输出，`bootstrap` / `load -w` / `bootout`
  一律 `5: Input/output error`。监听类方案只能生成 plist，
  让用户在自己终端跑一次 `launchctl bootstrap gui/$(id -u) <plist>`。
- **`killall iconservicesd` 会把自己打死**（exit 137），别用它清图标缓存；
  实在需要就 `killall Finder`。
- **macOS 26 移除了 `/System/Library/Fonts/PingFang.ttc`**；
  中文渲染改用 `/System/Library/Fonts/Hiragino Sans GB.ttc`（index 2 = W6）。
  PIL 加载 `.ttc` 要传 `index`，否则可能拿到不含中文的 face。
- **托管 Python 可能没有 Pillow**。用 `/usr/bin/python3`（系统自带 Pillow 11.x）。

---

## 10. 面板弹出来了，但点里面的图标没反应

用户实测：面板正常弹出，点网格里的图标**一点反应都没有**。

先把「启动」这条链路单独测通，把问题范围缩小。给启动器加一个自检入口：
环境变量 `DOCKGROUP_SELFTEST=<下标>` 时，启动后直接调用和点击完全相同的 `pick(index)`：

```
[1789308972.186] === launch pid=34245 group=测试
[1789308972.189] resolved 1 entries: Calculator
[1789308972.246] panel shown frame={{638, 514}, {116, 122}} level=101 key=true
[1789308972.247] selftest: picking index 0
[1789308972.773] pick index=0 entries=1
[1789308972.773] launching /System/Applications/Calculator.app
[1789308973.042] openApplication result app=计算器 pid=34251 err=nil
[1789308973.042] === exit
```

计算器确实被拉起（`pgrep` 验证过）—— 所以**解析路径、命中下标、LaunchServices 启动全部正常**，
问题只可能在「点击有没有送到视图上」。

> 小技巧：`open` 启动 App 不继承 shell 环境变量，所以自检要**直接跑 bundle 里的可执行文件**
> （`Foo.app/Contents/MacOS/Foo`）才能把 `DOCKGROUP_SELFTEST` 传进去。
> 直接跑可执行文件时 `Bundle.main` 仍能正确指向 .app，Info.plist 读得到。

点击链路上一共有三个可疑点，全都在这一版里拆掉了：

**① `NSButton` 的首次点击语义。** 在「非激活 App + 非激活面板」里，
未被激活的窗口上的控件可能因为 `acceptsFirstMouse` 返回 false 而吞掉第一次 `mouseDown`
（第一次点击只用来激活窗口）。虽然面板本身是 key 的（日志里 `key=true`），但这个语义不值得赌。

→ 换成自绘的 `NSView` 子类（`ItemView`），自己接 `mouseDown(with:)`，并显式：

```swift
override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
override var mouseDownCanMoveWindow: Bool { false }
```

**② 在事件回调里打开 layer backing。** 旧版在 `mouseEntered` 里才写 `wantsLayer = true`。
在跟踪过程中把视图切换成 layer-backed 会导致 AppKit 重建视图层级，
有概率打断正在进行的鼠标跟踪。

→ `wantsLayer` / 圆角 / 背景色全部在 `init` 里设好，事件回调里只改颜色。

**③ 全局监视器把面板内的点击误判成「点外面」。** 旧版是：

```swift
NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
    NSApp.terminate(nil)          // ← 无条件退出
}
```

按理全局监视器收不到自己窗口的事件，但这里不能「按理」。

→ 加命中判断，落在面板框内就忽略：

```swift
if p.frame.contains(NSEvent.mouseLocation) {
    trace("global monitor fired INSIDE panel frame -> ignored")
    return
}
```

### 做法：把事件轨迹写成日志

无法手动点击的环境里，唯一能定位的办法是让程序把每一步都记下来。
现在 `<落盘>/.cache/<组名>.events.log` 是追加式的事件轨迹，
配合 `dg logs <组名>` 直接给出断点判断：

| 日志里看到 | 说明 |
|---|---|
| 只有 `=== launch`，没有 `mouseDown hit item` | 点击没送达视图（窗口层级 / 事件路由） |
| 有 `mouseDown` 但没有 `launching` | 命中下标不对，或目标路径失效 |
| 有 `launching` 但 `openApplication` 报错 | LaunchServices 拒绝启动 |
| 出现 `dismiss: click outside panel` | 被误判成点了面板外 |

面板几何单独存 `<组名>.launch.log`（覆盖式 JSON），便于脚本校验定位；
事件轨迹存 `<组名>.events.log`（追加式），两者分开，互不干扰。


### 已实测确认（2026-09-15）

用户实测：**点击面板里的图标已能正常启动对应 App**。
关键是三处一起改：自绘 `NSView` + 显式 `acceptsFirstMouse` 返回 true、
`wantsLayer` 移出 `mouseEntered`、全局监视器加面板命中判断。


---

## 11. 性能：钱花在哪，以及三个反直觉的发现

先量再说。第一版 `preview`（6 个分组、21 个 App）冷启动要 **15.3s**，逐项拆解后发现
瓶颈和直觉不一样：

```
osascript    6 次   2.45s   平均 408ms   ← 真正的瓶颈
sips        10 次   0.21s   平均  21ms
iconutil     1 次   0.06s
make_mosaic        0.16s
```

### 发现 ①：慢的不是「起进程」，是「让 AppKit 渲染图标」

裸 `osascript` 启动只要 0.07s。但只要脚本里调 `NSWorkspace.iconForFile` 做一次
图标解析 + TIFF + PNG 编码，就变成 **~180ms/个**，且**与请求的尺寸无关**。

所以「批量化」省下的只是 0.07s/次的进程启动 —— 有价值，但不是主因。

### 发现 ②：`NSImage.size` 对 `TIFFRepresentation` 无效

```javascript
icon.size = $.NSMakeSize(256, 256);      // 看起来在降分辨率
const tiff = icon.TIFFRepresentation;    // 实际上还是全分辨率
```

实测请求 1024 / 512 / 256 / 128，产出文件**都是 1297 KB、耗时都 ~180ms**。
`size` 只是显示尺寸提示，不影响 `TIFFRepresentation` 的像素尺寸。

→ 想真正降分辨率，得自己建一个目标尺寸的 `NSBitmapImageRep` 再 `drawInRect`。
但既然耗时不变，**性价比更高的做法是在 Python 侧把落地缓存缩小**
（见发现 ③）。

### 发现 ③：缩小缓存 → 后续每次解码快 4 倍

图标格子最大约 540px（只有一个 App 的分组），所以缓存里留 512px 足够。
落地时用 PIL 缩一次（`_shrink_cache`），之后每次 `make_mosaic` 的解码开销大降：

| | 每个图标 | 21 个合计 |
|---|---|---|
| 原样缓存 1024px | 1297 KB | 27.2 MB |
| 缩到 512px | **102 KB** | **2.1 MB** |

效果：冷启动 **15.3s → 7.9s（快 48%）**，热缓存 **1.64s → 0.65s（快 2.5 倍）**。

### 坑：别把渐变改成「建 1×2 再 resize」

看起来更简洁，实际是错的：

```python
# ✗ 错：PIL 放大时按半像素对齐，2 像素源会变成上下各约 1/4 是平的
base = Image.new("RGBA", (1, 2)); base.putpixel(...); base.putpixel(...)
return base.resize((size, size), Image.BILINEAR)

# ✓ 对：逐行算好，一次性 putdata
ramp = [tuple(int(top[i] + (bottom[i]-top[i]) * y / span) for i in range(4)) for y in range(size)]
row = Image.new("RGBA", (1, size)); row.putdata(ramp)
return row.resize((size, size), Image.NEAREST)
```

PIL 的坐标映射是 `src = (dst + 0.5) * scale - 0.5`，2→1024 时源坐标会跑到 -0.5 ~ 1.5，
两端 clamp，导致渐变只占中间约一半。实测单通道最大差 18/255。
`putdata` 版本比原来的逐像素 `putpixel` 循环更快，且输出逐像素一致。

### 其它代码质量项

- **`jxa()` 的返回值分隔符**：原来用 `", "` 切分，路径里带逗号就会切错。
  改成各 JXA 脚本统一 `join(String.fromCharCode(10))` + Python 侧按行切分。
  > 用 `String.fromCharCode(10)` 而不是 `'\n'`，因为在多层字符串里转义太容易写错
  > （实测被工具链当成真换行写进过文件，直接把 JS 字符串弄断）。
- **路径类型统一**：内部一律 `Path`，公开函数入口 `Path(...)` 兜底，
  避免传 `str` 时 `out.parent` 抛 `AttributeError`。
- **`dock_read()` 记忆化**：原来 `list` 里每个分组查一次 `dock_has` → N 次 `defaults export`。
  加缓存后同一次命令只读一次，`dock_write` 负责同步缓存。
- **别名播种加 Python 侧存在性判断**：全都在就直接跳过，连 osascript 都不起。

### 回归验证方式

改完不能只看「跑通了」。用 `git show <旧提交>:scripts/dockgroup.py` 把旧版取出来，
新旧各渲染一遍，逐像素比：

```python
ImageStat.Stat(ImageChops.difference(old_img, new_img)).extrema   # 全为 0 才算没改坏
```

5 种风格全部 0/255。这一步正是靠它抓出了上面的渐变回归。

---

## 12. 「应用程序"X"已不能再打开」

用户报的症状：**点一下正常，再点一次弹这个错**。

有两个独立成因，都要修。

### 成因 A：每次 rebuild 都重写 bundle，LaunchServices 作废了 App 记录

`build_launcher_app` 原来无条件做这三件事：

```python
png_to_icns(mosaic, icon)          # 重写 AppIcon.icns
plistlib.dump(plist, info_file)    # 重写 Info.plist
codesign --force --sign - <app>    # 重写 _CodeSignature
```

哪怕图标和配置**一个字节都没变**，bundle 的内容也被改了。LaunchServices 会认为
这个 App 被替换过，作废先前登记的记录，之后再打开就报「已不能再打开」。
`lsregister -f` 也不总能救回来。

**修法：内容没变就一个字节都别动。**

```python
digest = hashlib.sha256(plistlib.dumps(plist) + mosaic.read_bytes()).hexdigest()
stamp = CACHE / f"{name}.bundle-stamp"
if force or not stamp.exists() or stamp.read_text().strip() != digest:
    # 只有这时才写 icns / Info.plist / codesign / lsregister
    ...
    stamp.write_text(digest)
```

验证方式：连续 `apply` 两次，看 `AppIcon.icns` 的 mtime 是否变 —— 第二次应该不动。

### 成因 B：用完立刻退出，连点时 Dock 会尝试再启动一个实例

启动器原来的收尾是 `NSApp.terminate(nil)`。于是：

1. 第一次点击 → 启动实例 → 弹面板 → 你选完 / 点别处 → 进程**退出**
2. 第二次点击 → 上一个实例可能还没退干净 → Dock 尝试**再启动一个实例** →
   LaunchServices 拒绝 → 弹「已不能再打开」

**注意这个用 `open` 命令复现不出来**：`open` 对已运行的 App 走的是 reopen 路径，
返回码 0，一切正常。Dock 点图标与 `open` 不是同一条路，这也是排查时最容易走偏的地方。

**修法：不要用完就退。** 收起面板后让进程留着，下次点击走 reopen：

```swift
private func hidePanel() {
    shown = false
    panel?.orderOut(nil)
    scheduleIdleExit()          // kIdleSeconds（默认 600s）后自动退出
}
```

于是点击变成**切换**语义 —— 面板开着再点一下就是收起，符合直觉：

```swift
func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if panel?.isVisible == true { hidePanel() } else { showPanel(...) }
    return true
}
```

验证（事件日志）：

```
[..] === launch pid=39592 group=AI
[..] panel shown frame={{680, 499}, {380, 122}} level=101 key=true
[..] reopen -> toggle close
[..] panel hidden                       ← 同一 pid，进程没退
[..] reopen -> toggle open
[..] panel shown frame={{584, 502}, {380, 122}} level=101 key=true
```

### 配套：全局监视器要让开 Dock 区域

改成常驻后有个新坑：点击 Dock 图标时，**全局鼠标监视器也会收到那一下**。
它按「点面板外」处理就会先收起面板，紧接着 reopen 又来展开 —— 净效果是第二次点击
看上去毫无反应。所以监视器要跳过 Dock/菜单栏那条带：

```swift
if let vis = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) })?.visibleFrame,
   !NSMouseInRect(m, vis, false) {
    return   // 落在 Dock 或菜单栏区域，交给 reopen 决定
}
```

### 附带清掉的一个隐患

早期版本装过的 LaunchAgent（`com.wangjian.dockgroup.plist`）指向**旧脚本路径**。
如果它被加载着，每次分组文件夹变动都会用旧脚本 + 旧 Swift 源码覆盖新 bundle ——
既让「点图标没反应」的修复失效，也会持续触发成因 A。
升级或迁移目录后，务必检查并清掉这类陈旧的 plist：

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/<旧label>.plist
```

### 已实测确认（2026-09-15）

用户在本机实测：**连点分组图标不再报错，展开 / 收起均正常**。
有效性来自三条修复同时生效，缺任何一条都不行：

1. bundle 内容未变时不再重写 —— 否则 LaunchServices 会持续作废 App 记录
2. 启动器常驻、第二次点击走 reopen —— 否则会尝试新启实例被拒
3. 全局鼠标监视器跳过 Dock / 菜单栏区域 —— 否则会与 reopen 打架，表现为「第二次点击没反应」


---

## 13. 纯白底板会让白底 App 图标糊掉

用户反馈：**背景太白，有的应用图标不太好辨认**。

原因很具体：很多 App 图标本身就是**白色的圆角方块**（Hermes、WorkBuddy、
以及不少开发工具都是），把这样的图标放进纯白底板：

```
纯白底板 (255) + 白底图标 (255)  →  边界消失，只剩中间的彩色 logo 可见，图标形状丢了
```

这不是「图标做得不好」，是**底板与图标同色**导致的。两条修法一起上：

### ① 底板改成与 Dock 栏同调的浅灰

新增 `dock` 风格，上下渐变 `(225,227,234)` → `(198,201,213)`，而不是 `(255,…)`。
（第一版给的 `(238,239,243)` 顶色还是太接近白，用户实测仍觉得太白；
  需要更强对比用 `dock-deep`：`(209,212,221)` → `(176,180,194)`。）
白底图标在这个灰度上就显出轮廓了。图标本身偏灰白的还可以再用 `dock-deep`
（`(226,228,234)` → `(188,191,203)`），对比更强。

### ② 每个 App 图标叠一层很轻的投影

只换底色还不够 —— 白图标在白/浅灰底上依然只有「半个」可见。给每个格子里的图标
加一层柔和投影，轮廓才真正立起来（iOS 的主屏图标也做了同样的事）：

```python
def _drop_shadow(canvas, icon, pos, blur=0.011, offset=0.007, strength=0.34):
    S = canvas.width
    mask = Image.new("L", canvas.size, 0)
    mask.paste(icon.split()[3], (pos[0], pos[1] + max(1, int(S * offset))))
    mask = mask.filter(ImageFilter.GaussianBlur(max(2, int(S * blur))))
    mask = mask.point(lambda v: int(v * strength))
    canvas.paste(Image.new("RGBA", canvas.size, (30, 32, 42, 255)), (0, 0), mask)
```

参数按画布边长的比例给（blur 1.1%、下移 0.7%、强度 0.34），这样换尺寸不用重调。
只在浅色风格上开（`icon_shadow=True`）；深色风格上阴影没有意义。

### 选风格的方法论

一定要做一张**「把候选图标夹在真实 App 图标中间、按真实 Dock 尺寸并排」**的对比图。
单独看大图很容易选错 —— 白色底板单看挺干净，放进 Dock 一比就发现它和邻居的
白底图标糊在一起了。

---

## 14. 弹出面板「太白」，白底图标在里面看不清

用户反馈的其实是**面板**，不是拼贴图标底板：
面板用的 `.popover` 材质接近纯白，而 Dock 栏是灰玻璃 —— 两者观感差很多，
白底 App 图标放进近白的面板里同样会糊。

### 修法：材质从 `.popover` 换成 `.menu`

`macOS` 没有公开的「Dock 材质」，与 Dock 栏观感最接近的公开选项是 `.menu`
（菜单栏和 Dock 用的是同一族材质，浅色模式半透明灰玻璃、深色模式自动变深）。

```swift
bg.material = .menu     // 而不是 .popover
```

顺带在 `ItemView.draw` 里给图标加投影，白图标在灰玻璃上轮廓更清楚：

```swift
if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4,
                  color: NSColor.black.withAlphaComponent(0.30).cgColor)
    icon.draw(in: iconRect)
    ctx.restoreGState()
}
```

### 两个坑

**① Swift 4 起 `NSVisualEffectMaterial` 改名了**

```swift
// ✗  'NSVisualEffectMaterial' has been renamed to 'NSVisualEffectView.Material'
func material(named name: String) -> NSVisualEffectMaterial
// ✓
func material(named name: String) -> NSVisualEffectView.Material
```

**② 让材质可配置，而不是在代码里写死**

面板观感是纯主观的东西，写死 `.menu` 用户不满意还得改代码重编译。
把材质名从 Info.plist 读（`DockGroupMaterial`），配置里一个字符串就能换：

```swift
bg.material = material(named: (Bundle.main.object(
    forInfoDictionaryKey: "DockGroupMaterial") as? String) ?? "menu")
```

Python 侧把它拼进 Info.plist，并纳入 bundle 的 stamp 哈希 ——
材质变了 bundle 才会重建，LaunchServices 记录才不会无故失效。


---

## 15. macOS 26 会给传统 .icns 图标套一层系统底板（改不了）

**这是整个项目里最反直觉、也是最终定调的一个发现。**

用传统 `.icns` 提供 App 图标时，macOS 26 会把我们的图标**缩小到约 60%**，
垫在一张系统生成的浅灰圆角底板上。结果：

- 我们精心挑的底板色只占内层 ~60%，外圈那圈浅灰是系统给的，**改不了**
- 内部的 App 图标因此只有整个 tile 的 ~25%，天然偏小

实测排除了两条可能的绕路：

| 尝试 | 结果 |
|---|---|
| 图标做成满幅（无透明边距、直角） | 仍被垫底板、仍被缩小 |
| 换材质 / 换底色 / bump CFBundleVersion | 内层变了，外圈那圈系统浅灰不变 |

也验证了它**不是**我们独有的问题：用 `NSWorkspace.iconForFile` 渲染
Notes / Clash Verge / 微信，内容占比同样是 0.87、四角同样透明 ——
所有传统 `.icns` 图标在 macOS 26 上都是这个待遇，我们的分组图标
在 Dock 里看起来和邻居是一致的。

> 只有按 macOS 26 新规范（asset catalog 的图标组合器）提供图标才可能避开，
> 那需要 Xcode，超出本工具「零依赖」的范围。

### 引申的取舍

既然内层变小了，**底板选深色反而更好**：
浅色底板 + 白底 App 图标 = 糊成一团；
深色底板（`graphite` / `glass-dark`）+ 白底图标 = 对比强烈、一眼可辨。

所以默认风格从 `dock` 改成了 `graphite`。

### 顺带一个测量教训

判断「Dock 是否显示了我画的图」时，别用「取四角像素」——
系统底板的圆角很大，四角本来就是透明的，会误判成「没有底板」。
正确做法是把我们画的图按 Dock 渲染结果的 bbox 对齐后逐像素比，
或者干脆把两边并排存成图直接看。
