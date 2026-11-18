#!/usr/bin/env python3
"""Build a macOS app iconset from the 1024px master.

The master is full-bleed and square. The iconset places that artwork in the
macOS squircle (~824px on a 1024 canvas) with a transparent margin and a soft
shadow, then writes every size iconutil expects.

Pillow does the mask. If it is not installed, `sips` (macOS Command Line Tools)
resizes the committed masked PNG instead. `make app` then runs `iconutil`.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

SIZES = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)

CANVAS = 1024
BODY = 824


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--master", type=Path, default=here / "AppIcon-1024.png")
    parser.add_argument("--masked", type=Path, default=here / "AppIcon-masked-1024.png")
    parser.add_argument("--iconset", type=Path, required=True)
    parser.add_argument(
        "--write-masked",
        action="store_true",
        help="Also refresh the committed masked PNG (needs Pillow).",
    )
    args = parser.parse_args()

    iconset = args.iconset
    iconset.mkdir(parents=True, exist_ok=True)

    try:
        from PIL import Image, ImageFilter
    except ImportError:
        return resize_with_sips(args.masked, iconset)

    if not args.master.is_file():
        print(f"error: missing master artwork {args.master}", file=sys.stderr)
        return 1
    masked = render_masked(Image.open(args.master))
    if args.write_masked:
        args.masked.parent.mkdir(parents=True, exist_ok=True)
        masked.save(args.masked, "PNG")
    for name, pixels in SIZES:
        resized = masked if pixels == CANVAS else masked.resize((pixels, pixels), Image.Resampling.LANCZOS)
        resized.save(iconset / name, "PNG")
    return 0


def render_masked(master):
    from PIL import Image, ImageFilter

    art = master.convert("RGBA").resize((BODY, BODY), Image.Resampling.LANCZOS)
    mask = squircle_mask(BODY)
    art.putalpha(mask)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    margin = (CANVAS - BODY) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shade = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 0))
    shade.putalpha(mask.point(lambda value: int(value * 0.38)))
    shadow.paste(shade, (margin, margin + 14), shade)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=18))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.paste(art, (margin, margin), art)
    return canvas


def squircle_mask(size: int):
    """Superellipse approximation of the macOS continuous-corner squircle."""
    from PIL import Image

    scale = 4
    big = size * scale
    mask = Image.new("L", (big, big), 0)
    pixels = mask.load()
    half = big / 2
    radius = half - scale
    exponent = 5.0
    for y in range(big):
        ny = abs((y + 0.5 - half) / radius) ** exponent
        if ny > 1:
            continue
        for x in range(big):
            if abs((x + 0.5 - half) / radius) ** exponent + ny <= 1:
                pixels[x, y] = 255
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def resize_with_sips(masked: Path, iconset: Path) -> int:
    sips = shutil.which("sips")
    if sips is None or not masked.is_file():
        print(
            "error: Pillow is not installed and sips cannot resize "
            f"{masked.name}. On macOS, Command Line Tools provide sips; "
            "commit packaging/AppIcon-masked-1024.png next to the master.",
            file=sys.stderr,
        )
        return 1
    for name, pixels in SIZES:
        destination = iconset / name
        if pixels == CANVAS:
            shutil.copyfile(masked, destination)
            continue
        subprocess.run(
            [sips, "-z", str(pixels), str(pixels), str(masked), "--out", str(destination)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
