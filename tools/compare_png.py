#!/usr/bin/env python3
"""对比两张 PNG 的逐像素差异 —— 验证「Swift 重写 Pillow 合成」是否等效。

用法：
    /usr/bin/python3 tools/compare_png.py <a.png> <b.png> [前缀]

输出：
    · MAE / 最大误差 / PSNR / 超阈值像素占比
    · <前缀>-diff.png   差异热力图（越红差异越大）
    · <前缀>-side.png   A | B | 差异 三联图

为什么要它：全 Swift 化的最大风险点是「图像能不能做得一样」。肉眼看着像不算数，
得给出量化指标。差异全都落在抗锯齿边缘 / 模糊过渡带，和差异成片出现在形状
或颜色上，是两回事。
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat

THRESH = 8          # 单通道差值超过它才算「明显不同」
AMPLIFY = 8         # 热力图放大倍数（差异小，不放大会看不见）


def label(img, text):
    """在图上加一行标注，方便对着三联图看。"""
    out = img.copy()
    d = ImageDraw.Draw(out)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 26, index=2)
    except Exception:
        font = ImageFont.load_default()
    d.rectangle((0, 0, out.width, 40), fill=(0, 0, 0, 210))
    d.text((12, 6), text, font=font, fill=(255, 255, 255, 255))
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    pa, pb = Path(sys.argv[1]), Path(sys.argv[2])
    prefix = sys.argv[3] if len(sys.argv) > 3 else "/tmp/cmp"

    a = Image.open(pa).convert("RGBA")
    b = Image.open(pb).convert("RGBA")
    if a.size != b.size:
        sys.exit(f"❌ 尺寸不同：{a.size} vs {b.size}")

    diff = ImageChops.difference(a, b)

    # ── 统计（用 PIL 内置算子，避免百万级 Python 循环）──
    stat = ImageStat.Stat(diff)
    mae_rgb = sum(stat.mean[:3]) / 3
    max_rgb = max(stat.extrema[c][1] for c in range(3))
    mae_a = stat.mean[3]

    # 超阈值像素：三通道任一超阈就算
    masks = [diff.getchannel(c).point(lambda v: 255 if v > THRESH else 0)
             for c in range(3)]
    mask = ImageChops.lighter(ImageChops.lighter(masks[0], masks[1]), masks[2])
    over = sum(1 for v in mask.getchannel(0).getdata() if v)
    total = a.width * a.height

    # PSNR（按 RGB 三通道的 MSE）
    sq = ImageStat.Stat(ImageChops.multiply(diff, diff)).mean[:3]
    mse = sum(sq) / 3
    psnr = float("inf") if mse <= 0 else 10 * math.log10(255 * 255 / mse)

    print(f"  尺寸        : {a.width}×{a.height}")
    print(f"  MAE (RGB)   : {mae_rgb:.4f} / 255")
    print(f"  MAE (alpha) : {mae_a:.4f} / 255")
    print(f"  最大通道差  : {max_rgb} / 255")
    print(f"  PSNR        : {psnr:.2f} dB" if psnr != float("inf") else "  PSNR        : ∞（完全相同）")
    print(f"  超阈值像素  : {over:,} / {total:,}  ({over / total * 100:.3f}%)   [阈值 >{THRESH}]")

    # ── 可视化 ──
    heat = diff.convert("L").point(lambda v: min(255, v * AMPLIFY))
    heat = heat.convert("RGBA")
    # 用红色叠加，差异的位置更醒目
    red = Image.new("RGBA", a.size, (255, 0, 0, 0))
    red.putalpha(heat.getchannel(0))
    heat = Image.alpha_composite(a.copy(), red)
    heat = label(heat, f"diff ×{AMPLIFY}  MAE={mae_rgb:.3f}  >{THRESH}: {over / total * 100:.3f}%")
    heat.save(f"{prefix}-diff.png")

    g = 24
    side = Image.new("RGBA", (a.width * 3 + g * 4, a.height + g * 2), (30, 30, 34, 255))
    for i, (im, t) in enumerate([(a, "A: Pillow"), (b, f"B: Swift ({pb.name})"), (heat, "diff")]):
        side.paste(label(im, t), (g + i * (a.width + g), g))
    side = side.resize((side.width // 2, side.height // 2), Image.LANCZOS)
    side.convert("RGB").save(f"{prefix}-side.png")

    print(f"\n  热力图 : {prefix}-diff.png")
    print(f"  三联图 : {prefix}-side.png")


if __name__ == "__main__":
    main()
