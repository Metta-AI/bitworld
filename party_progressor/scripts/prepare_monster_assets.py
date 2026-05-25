#!/usr/bin/env python3
"""Prepare imagegen monster sources for Party Progressor runtime sprites.

The preferred source path is an imagegen-produced transparent PNG named
`<monster>_full.png`. This script crops visible alpha, scales the art into the
32x32 sprite cell used by the game, and writes `<monster>.png`.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


DEFAULT_MONSTERS = [
    "pack_alpha",
    "thorn_mender",
    "banner_goblin",
    "net_thrower",
    "bog_witch",
    "leech_swarm",
    "fire_scorpion",
    "sand_burrower",
    "ice_shaman",
    "snow_stalker",
    "crystal_seer",
    "ruin_necromancer",
]


def alpha_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("source image has no opaque pixels")
    return bbox


def expanded_bbox(
    bbox: tuple[int, int, int, int],
    width: int,
    height: int,
    pad_ratio: float,
) -> tuple[int, int, int, int]:
    left, top, right, bottom = bbox
    pad_x = max(2, int((right - left) * pad_ratio))
    pad_y = max(2, int((bottom - top) * pad_ratio))
    return (
        max(0, left - pad_x),
        max(0, top - pad_y),
        min(width, right + pad_x),
        min(height, bottom + pad_y),
    )


def prepare_sprite(
    source: Path,
    target: Path,
    output_size: int,
    inner_size: int,
    pad_ratio: float,
) -> None:
    image = Image.open(source).convert("RGBA")
    bbox = expanded_bbox(alpha_bbox(image), image.width, image.height, pad_ratio)
    cropped = image.crop(bbox)
    cropped.thumbnail((inner_size, inner_size), Image.Resampling.LANCZOS)

    output = Image.new("RGBA", (output_size, output_size), (0, 0, 0, 0))
    x = (output_size - cropped.width) // 2
    y = max(0, output_size - cropped.height - 1)
    output.alpha_composite(cropped, (x, y))
    output.save(target)


def sprite_stats(path: Path) -> tuple[int, int]:
    image = Image.open(path).convert("RGBA")
    opaque = 0
    buckets: set[tuple[int, int, int]] = set()
    pixels = (
        image.get_flattened_data()
        if hasattr(image, "get_flattened_data")
        else image.getdata()
    )
    for r, g, b, a in pixels:
        if a < 12:
            continue
        opaque += 1
        buckets.add((r // 32, g // 32, b // 32))
    return opaque, len(buckets)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Crop imagegen monster sources into runtime 32x32 sprites."
    )
    parser.add_argument(
        "--asset-dir",
        default=Path(__file__).resolve().parents[1] / "data" / "generated" / "monsters",
        type=Path,
        help="Directory containing <monster>_full.png sources.",
    )
    parser.add_argument(
        "--monsters",
        default=",".join(DEFAULT_MONSTERS),
        help="Comma-separated monster slugs to prepare.",
    )
    parser.add_argument("--output-size", default=32, type=int)
    parser.add_argument("--inner-size", default=30, type=int)
    parser.add_argument("--pad-ratio", default=0.08, type=float)
    args = parser.parse_args()

    missing: list[str] = []
    prepared: list[Path] = []
    for monster in [part.strip() for part in args.monsters.split(",") if part.strip()]:
        source = args.asset_dir / f"{monster}_full.png"
        target = args.asset_dir / f"{monster}.png"
        if not source.exists():
            missing.append(source.as_posix())
            continue
        prepare_sprite(source, target, args.output_size, args.inner_size, args.pad_ratio)
        opaque, buckets = sprite_stats(target)
        if opaque < 80:
            raise SystemExit(f"{target} has too little visible sprite coverage")
        if buckets < 6:
            raise SystemExit(f"{target} has too few color/detail buckets")
        prepared.append(target)

    if missing:
        raise SystemExit("missing imagegen source(s):\n" + "\n".join(missing))

    for target in prepared:
        print(f"prepared {target}")


if __name__ == "__main__":
    main()
