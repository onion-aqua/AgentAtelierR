"""将用户提供的状态图标截图转换为透明 PNG。

依赖：Python 3、Pillow、numpy。
示例：
  python tool/prepare_virtual_phone_assets.py --signal signal.png \
      --battery battery.png --island island.png

源图通过参数传入，不依赖其他电脑或旧会话中的绝对路径。
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def remove_white_background(image: Image.Image, kind: str) -> Image.Image:
    """沿上下边缘估计渐变底色，保留前景的柔边和灰色非激活信号格。"""
    rgb = np.asarray(image.convert("RGB"), dtype=np.float32)
    height, width, _ = rgb.shape
    edge = min(10, max(2, height // 10))
    top = np.median(rgb[:edge], axis=0)
    bottom = np.median(rgb[-edge:], axis=0)
    fraction = np.linspace(0, 1, height)[:, None, None]
    background = top[None] * (1 - fraction) + bottom[None] * fraction
    contrast = np.maximum(background - rgb, 0).max(axis=2) / 255

    if kind == "signal":
        # 白色核心不透明度为 90%，原始浅灰格保留为较低不透明度。
        alpha = np.clip((contrast - 0.045) / 0.88, 0, 1) ** 0.72 * 0.9
    else:
        # 原图电池轮廓是中灰色，适当提亮后在黑色顶部栏仍清晰。
        alpha = np.clip((contrast - 0.035) / 0.56, 0, 1) ** 0.72 * 0.9

    rgba = np.empty((height, width, 4), dtype=np.uint8)
    rgba[:, :, :3] = (245, 248, 255)
    if kind == "battery":
        saturation = rgb.max(axis=2) - rgb.min(axis=2)
        colored = (saturation > 35) & (rgb[:, :, 0] > 120)
        red = colored & (rgb[:, :, 1] < 110)
        orange = colored & ~red
        rgba[red, :3] = (255, 78, 88)
        rgba[orange, :3] = (255, 161, 51)
    rgba[:, :, 3] = np.rint(alpha * 255).astype(np.uint8)
    rgba[rgba[:, :, 3] < 2] = 0
    return Image.fromarray(rgba)


def normalized_crop(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    # 不用整张截图的背景确定裁切边界，避免把浅色底纹带进资源。
    alpha = image.getchannel("A")
    bbox = alpha.point(lambda value: 255 if value > 16 else 0).getbbox()
    if bbox is None:
        raise ValueError("没有找到图标前景，请检查输入截图。")
    left, top, right, bottom = bbox
    cropped = image.crop((max(0, left - 2), max(0, top - 2),
                          min(image.width, right + 2), min(image.height, bottom + 2)))
    # 统一资源画布和主体尺寸，切换格数时不会引起布局跳动。
    content_size = (size[0] - 8, size[1] - 8)
    cropped = cropped.resize(content_size, Image.Resampling.LANCZOS)
    # Lanczos 在高对比边缘会轻微过冲，限制 alpha 后仍保持半透明核心。
    cropped.putalpha(cropped.getchannel("A").point(lambda value: min(value, 230)))
    canvas = Image.new("RGBA", size)
    canvas.alpha_composite(cropped, (4, 4))
    return canvas


def prepare_strip(path: Path, count: int, kind: str, output: Path) -> list[Path]:
    with Image.open(path) as source:
        source = source.convert("RGBA")
    size = (80, 68) if kind == "signal" else (80, 44)
    result = []
    for index in range(count):
        left = round(index * source.width / count)
        right = round((index + 1) * source.width / count)
        segment = source.crop((left, 0, right, source.height))
        icon = normalized_crop(remove_white_background(segment, kind), size)
        destination = output / f"{kind}_{index}.png"
        icon.save(destination, optimize=True)
        result.append(destination)
    return result


def prepare_island(path: Path, output: Path) -> Path:
    with Image.open(path) as source:
        image = source.convert("RGBA")
    alpha = image.getchannel("A")
    if alpha.getextrema()[0] == 255:
        raise ValueError("灵动岛源图没有透明背景；请提供带 alpha 的 PNG，避免误裁黑色主体。")
    bbox = alpha.getbbox()
    if bbox is None:
        raise ValueError("灵动岛源图完全透明。")
    cropped = image.crop(bbox)
    canvas = Image.new("RGBA", (cropped.width + 6, cropped.height + 6))
    canvas.alpha_composite(cropped, (3, 3))
    destination = output / "dynamic_island.png"
    canvas.save(destination, optimize=True)
    return destination


def create_preview(paths: list[Path], island: Path, output: Path) -> None:
    # 并列在纯黑及灰蓝背景显示，验证透明边缘与灵动岛黑色主体。
    preview = Image.new("RGB", (760, 380), (13, 17, 24))
    draw = ImageDraw.Draw(preview)
    draw.text((24, 18), "Transparent status assets / 90% core opacity", fill="white")
    for row, prefix, count in [(0, "signal", 5), (1, "battery", 6)]:
        y = 55 + row * 105
        for index in range(count):
            path = next(item for item in paths if item.name == f"{prefix}_{index}.png")
            icon = Image.open(path).convert("RGBA")
            x = 24 + index * 120
            preview.paste(icon, (x, y), icon)
            draw.text((x, y + 72), path.stem, fill=(178, 190, 210))
    draw.rounded_rectangle((24, 275, 736, 360), radius=22, fill=(45, 52, 78))
    icon = Image.open(island).convert("RGBA")
    icon.thumbnail((240, 72), Image.Resampling.LANCZOS)
    preview.paste(icon, ((760 - icon.width) // 2, 282), icon)
    draw.text((40, 308), "dynamic_island", fill="white")
    output.parent.mkdir(parents=True, exist_ok=True)
    preview.save(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--signal", type=Path, required=True)
    parser.add_argument("--battery", type=Path, required=True)
    parser.add_argument("--island", type=Path, required=True)
    project = Path(__file__).resolve().parent.parent
    parser.add_argument("--output", type=Path, default=project / "assets/images/virtual_phone")
    parser.add_argument("--preview", type=Path, default=project / "build/phone-status-assets-preview.png")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    paths = prepare_strip(args.signal, 5, "signal", args.output)
    paths += prepare_strip(args.battery, 6, "battery", args.output)
    island = prepare_island(args.island, args.output)
    create_preview(paths, island, args.preview)
    for path in paths + [island]:
        with Image.open(path) as image:
            print(f"{path.name}: {image.width}x{image.height}, alpha={image.getchannel('A').getextrema()}")
    print(f"Preview: {args.preview}")


if __name__ == "__main__":
    main()
