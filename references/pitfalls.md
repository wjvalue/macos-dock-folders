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
