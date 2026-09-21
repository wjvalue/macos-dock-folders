# swift/ —— dockgroup 的 Swift 实现

> 迁移进行中。这个目录与 `scripts/dockgroup.py` **并存**，不是替代关系。

## 为什么会有这个目录

全 Swift 化的目标是**零运行期依赖**。现在一半功能在 Python（`dockgroup.py`，2400 行）
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

| 命令 | 状态 |
|---|---|
| `list` | ✅ 已搬迁，对照通过（32 行逐字符一致） |
| 其余 19 个 | ⬜ 未搬迁 —— 会明确提示去用 Python 版 |

基础模块里 `Core/Config.swift`（groups.json 读入再序列化）也已逐字节对齐。

## 结构

```
main.swift            入口与命令分发
build.sh              编译脚本（把仓库位置烧进二进制）
Core/
  Paths.swift         路径常量（照抄 dockgroup.py 顶部那组定义）
  JSON.swift          有序 JSON 的解析与序列化
  Config.swift        groups.json 读写、分组级覆盖解析
  Dock.swift          Dock plist 读取、别名解析、分组文件夹扫描
  Sh.swift            跑外部命令
Commands/
  List.swift          dg list
```

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
