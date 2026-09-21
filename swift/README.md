# swift/ —— dockgroup 的 Swift 实现

> **迁移已完成（2026-09-21 收官）**：20 / 20 个命令全部对照通过，这里是 `dg` 的
> 唯一引擎。`scripts/dockgroup.py`（Python 版）保留作源码安装的回退，待预编译
> 分发稳定后退役。

## 为什么会有这个目录

全 Swift 化的目标是**零运行期依赖**。迁移前一半功能在 Python（`dockgroup.py`，2400 行）
和 Pillow 手上，用户必须装 Xcode Command Line Tools **和** Pillow 才能跑。
全搬到 Swift 之后只剩编译期需要 CLT；再配合预编译二进制，用户端连 CLT 都不必装。

起因是 [issue #1](https://github.com/wjvalue/macos-dock-folders/issues/1) 里一位用户
指出「Python 有多种安装方式，CLT 只是其一」并建议用全 Swift 替代 python + Pillow。
对这条建议的核查、以及图像部分的可行性验证，见
[`references/spike-swift-mosaic.md`](../references/spike-swift-mosaic.md)。

## 怎么迁移：绞杀者模式

**两套实现并存 → 逐命令对齐 → 全部对齐后再切换。**

不一次性重写：2400 行的量一次搬完，中途项目会处于不可用状态，回归风险也大。

每个搬过来的命令都要在 `tools/compare_cli.sh` 里登记一项。那个脚本会同时跑两套实现
并逐行 diff —— **这是唯一的正确性关卡**。靠肉眼看输出会漏掉一个空格的差别，
而空格恰恰最容易出问题：`{:<10}` 是按字符数补位（不是显示宽度）、
`print` 的换行次数、中文名算几个位置。

```bash
swift/build.sh          # 编译到 build/dg-swift（可用参数指定输出路径）
tools/compare_cli.sh    # 跑对照测试
```

## 进度

**20 / 20 全部对照通过**（2026-09-21 收官，`2d122ca`）。覆盖不止「终端输出逐行
一致」：

- **输出**：每个命令的终端输出逐行 diff —— `{:<10}` 按字符数补位、`print` 的
  换行次数、中文名算几个位置，全在比对范围
- **写盘**：`init` 写出的 `groups.json` 逐字节一致（自实现的有序 JSON）
- **产物**：`rebuild` 生成的 Info.plist / bundle 结构 / 合成图标逐项比对；
  图标像素 MAE 实测 0.35（CoreText vs FreeType），阈值 3.0
- **异常分支**：doctor 的「依赖缺失」「产物路径失效」在正常环境跑不到，靠
  `DOCKGROUP_HOME` / `PATH` 逼出来 —— 那恰恰是用户出事时看到的几行

> ⚠️ `rebuild` / `apply` 会 `killall Dock`，从沙箱里直接跑会把当前命令连带打死
> （exit 137、零输出）。对照测试因此走内部命令 `__build-group`：只构建、不重启 Dock。

## 结构

```
main.swift            入口与命令分发
build.sh              编译脚本（把仓库位置烧进二进制）
Core/
  Paths.swift         路径常量（照抄 dockgroup.py 顶部那组定义）
  JSON.swift          有序 JSON 的解析与序列化
  Plist.swift         保序 XML plist（Info.plist 的键顺序不能漂）
  Config.swift        groups.json 读写、分组级覆盖解析
  Dock.swift          Dock plist 读取、别名解析、分组文件夹扫描
  Quarantine.swift    隔离属性检测与清理、结束常驻启动器
  Hash.swift          MD5 / SHA256（CryptoKit）
  Mosaic.swift        分组图标合成（从 tools/mosaic_poc 移植，已对齐 Pillow）
  AppIcon.swift       从 .app 提取图标（直接调 NSWorkspace，不走 JXA）
  Icns.swift          PNG → .icns
  AppTile.swift       Dock tile 构造（GUID / bookmark）
  Group.swift         建别名、收成员、build_group
  LauncherApp.swift   构建启动器 .app（编译 / 图标 / plist / 签名）
  Sh.swift            跑外部命令
  Util.swift          pad（按字符数补位）、pyLess（码点序比较）、DgError
Commands/            20 个命令，一个文件一个命令
  Add / Del / New            增删（含交互引导）
  Apply / Rebuild            写 Dock / 全量重建
  Style / Layout             外观：图标风格、面板材质、排列
  Gui                        管理窗口（构建 + 打开 DockGroup.app）
  List / Doctor / Init       查看与体检
  Preview / Test / Logs      预览、试弹、日志
  Open / Remove / Restore    文件夹、移除、回滚
  Watch                      文件夹监听（watch-install / watch-uninstall）
```

`tools/compare_cli.sh` 覆盖**三类**场景：

- **正常路径** —— 每个已搬迁的命令跑一遍
- **异常分支** —— `doctor` 的「依赖缺失」「产物路径失效」在正常环境下根本跑不到，
  得靠 `DOCKGROUP_HOME` 和 `PATH` 逼出来。而那恰恰是 doctor 存在的意义，
  出事时用户看到的就是那几行，不能只测 happy path。
- **有副作用的命令** —— `init` 会写 `groups.json`，不能直接跑两遍（第二遍就走进
  「配置已存在」那条分支了）。改成隔离落盘 + 每轮清空，并把**生成出来的
  `groups.json` 也并进输出**一起比 —— 写盘格式对不对，只有这样才测得出来。

## 几条不能破的约定

- **编译方式不变**：`swiftc` 直接编译，不引 Xcode 工程 / SPM / 第三方依赖。
  这个项目一直刻意保持「只用 CLT」这条路子。
- **`Core/BuildInfo.swift` 是生成文件**，内容是本机绝对路径 —— 已在 .gitignore 里，
  别提交。仓库位置只能在编译期烧进去，因为 Swift 没有 Python 的 `__file__`。
- **`main.swift` 必须是顶层代码入口** —— 多文件编译时只有它能放顶层语句。
- **JSON 不能用 `JSONSerialization` / `JSONEncoder`**：前者返回无序字典会丢键顺序，
  后者 prettyPrinted 是 `"key" : value`（冒号前多一个空格）。两个都会让
  `groups.json` 的 diff 全是噪音 —— 这是 2026-09-20 实际踩过的。
- **排序要加 tiebreaker**：Swift 的 `sort` **不保证稳定**，Python 的 `sorted` 是稳定的。
