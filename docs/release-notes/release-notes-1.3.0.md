# v1.3.0 — DockGroup.app「下载即用」

从这版起，**下载一个 .app 双击就能用**，不用再解压源码包跑安装脚本。

## 下载哪个

| 资产 | 适合谁 |
|---|---|
| **`DockGroup-1.3.0-macos.zip`**（推荐） | 普通用户：解压出 `DockGroup.app`，双击即用 |
| `dockgroup-1.3.0-prebuilt.zip` | 想要 `dg` 命令行 + `install.command` 装法的老用户 |
| Source code (zip/tar.gz) | 想改代码的人 |

## DockGroup.app 怎么用

1. 下载 `DockGroup-1.3.0-macos.zip`，解压出 `DockGroup.app`
2. **首次打开会被 Gatekeeper 拦一次**（ad-hoc 签名 + 隔离标记）。放行方法分版本：
   - **macOS 14 及更早**：右键 →「打开」→ 再点「打开」；
   - **macOS 15+（含 26）**：右键已经没有「打开」旁路。点掉弹窗后去
     **系统设置 → 隐私与安全性**，底部会出现「"DockGroup" 已被阻止」→
     点 **「仍要打开」** → 验证密码 / Touch ID；
     或者终端一条命令：`xattr -cr ~/Downloads/DockGroup.app`（按实际路径）
3. 它自己装好引擎（universal 二进制，**不需要 CLT / Python / Pillow**），
   然后自动打开分组管理窗口；之后每次双击 = 确认安装（幂等升级）+ 开窗口
4. 建议拖进「应用程序」当常驻入口

装了什么：`~/.local/bin/dg`（引擎短命令）、`~/Library/Application Support/DockGroup/`（源码与二进制载荷，.app 挪走/删除都不影响）、`~/Dock Groups/.cache/`（预编译启动器/管理窗口，apply 免编译）。

## 其他变更

- `swift/Bootstrap/main.swift`：自安装入口，与 `install.command` 预编译路径一一对应
- `tools/build-app.sh`：组装 .app + ad-hoc 签名 + 打 macos.zip（载荷取自 git archive HEAD，与 zip 内源码逐字节一致）
- README 安装说明重排为三种方式；踩坑记录新增 pitfalls #22

## 已知限制

- 无 Apple 开发者账号，未公证 —— 下载的 .app 首开必被拦一次，右键打开即可
- macOS 12.0+
