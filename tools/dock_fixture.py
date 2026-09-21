#!/usr/bin/env python3
"""生成一份「像真的一样」的 Dock 配置样本，给对照测试当输入。

为什么需要它：dock_sync 是整个工具里唯一会改用户 Dock 的地方，也是最该被测死的一段；
但真跑一遍的代价是「两套实现先后把用户的 Dock 真改掉两次」。所以改成：造一份样本
plist，两边都拿它当输入，比**写出来的字节**。输入一致、输出可比，测的仍然是同一段逻辑。

样本刻意覆盖 dock_sync 的全部分支：

  · 自动落位      成员 App 在 Dock 里的位置决定分组图标插在哪
  · 剔除已折叠的  成员被折叠进分组后，原来那几个图标要从 Dock 上消失（prune）
  · 清掉旧的分组  已经存在同名分组图标时，先摘掉再重插（否则会留一串重复项）
  · 右侧区过滤    persistent-others 里指向 ~/Dock Groups 的残留要清掉
  · 兜底追加      成员一个都不在 Dock 里的分组，追加到末尾
  · placement     placement="right" 的分组要落到分隔线右侧

用法：
  python3 tools/dock_fixture.py <输出目录> <Dock Groups 目录>

输出：
  <输出目录>/dock.plist       样本 Dock 配置
  <输出目录>/groups.json      配套的分组配置
  <输出目录>/<组名>/          分组文件夹（里面是指向真 App 的别名）
"""

import json
import plistlib
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))


def build(out_dir: Path, home: Path) -> None:
    # dockgroup 的路径常量在 import 时就算好了，所以必须先设好 DOCKGROUP_HOME 再导入。
    # 调用方（tools/compare_cli.sh）已经设了；这里再兜一层，防止有人手工跑时误伤真环境。
    import os
    os.environ["DOCKGROUP_HOME"] = str(home)
    import dockgroup  # noqa: E402

    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(home, ignore_errors=True)

    # ── 分组文件夹：用别名，因为真实用法就是这样（Finder 里拖进去的是别名）
    members = {
        "测试组": ["/System/Applications/Calculator.app", "/System/Applications/Notes.app"],
        "备用组": ["/System/Applications/System Settings.app"],
        "右侧组": ["/System/Applications/Music.app"],
    }
    for name, apps in members.items():
        folder = home / name
        folder.mkdir(parents=True, exist_ok=True)
        dockgroup.jxa("mkalias", folder, *[Path(a) for a in apps])

    cfg = {
        "style": "graphite",
        "groups": [
            {"name": "测试组", "enabled": True, "placement": "left", "apps": []},
            {"name": "备用组", "enabled": True, "placement": "left", "apps": []},
            {"name": "右侧组", "enabled": True, "placement": "right", "apps": []},
        ],
        "material": "hud",
        "layout": "row",
    }
    (home / "groups.json").write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # ── Dock 样本
    left = [
        dockgroup.make_app_tile(Path("/System/Applications/Mail.app"), "Mail"),
        dockgroup.make_app_tile(Path("/System/Applications/Calculator.app"), "Calculator"),
        dockgroup.make_app_tile(Path("/System/Applications/Notes.app"), "Notes"),
        dockgroup.make_app_tile(Path("/System/Applications/App Store.app"), "App Store"),
        # 已经存在的旧分组图标（同名的）—— 应被摘掉再重插，不能留两条
        dockgroup.make_tile(home / "测试组", "测试组"),
    ]
    right = [
        dockgroup.make_tile(Path.home() / "Downloads", "Downloads"),
        # 指向上一次落盘目录的残留 —— 应被清掉
        dockgroup.make_tile(home / "备用组", "备用组"),
        dockgroup.make_tile(Path("/System/Library/CoreServices/Finder.app"), "回收站"),
    ]
    pl = {"persistent-apps": left, "persistent-others": right, "orientation": "bottom"}

    (out_dir / "dock.plist").write_bytes(plistlib.dumps(pl))
    print(f"样本已生成：{out_dir}/dock.plist")
    print(f"  左侧 {len(left)} 项、右侧 {len(right)} 项")
    print(f"  落盘目录：{home}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build(Path(sys.argv[1]), Path(sys.argv[2]))
