#!/usr/bin/env python3
"""Generate DayPilot's DayPilot.icns app icon.

Renders a squircle-based macOS app icon at every size `iconutil` requires, then
packages it. The design is a dark obsidian tile with a radial vignette, a
concentric triple radar ring around an emerald-cyan focal point — the visual
language of "listening for signal", which is the whole product.

Pure Pillow. No network, no signing, no Xcode.

Usage:
    python3 Scripts/generate_icon.py [--output Resources/AppIcon.icns]
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

# macOS wants the icon to fill the full tile; Apple's own icons use a squircle
# that runs to the edges.
CANVAS = 1024
ICON_BASE = "icon"

# macOS icon set naming: name@scale where scale is 1 or 2. All sizes below are
# required for a correctly scalable .icns.
ICON_SIZES: tuple[tuple[str, int], ...] = (
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
)


def superellipse_points(size: int, exponent: float = 5.0, steps: int = 720) -> list[tuple[float, float]]:
    """Points tracing a squircle, the continuous-curvature rounded square Apple
    uses for icons. A plain rounded rectangle has a curvature discontinuity
    where the arc meets the edge; a superellipse does not.
    """
    half = size / 2.0
    points = []
    for index in range(steps):
        angle = (2.0 * math.pi * index) / steps
        cosine = math.cos(angle)
        sine = math.sin(angle)
        x = half * math.copysign(abs(cosine) ** (2.0 / exponent), cosine)
        y = half * math.copysign(abs(sine) ** (2.0 / exponent), sine)
        points.append((x + half, y + half))
    return points


def rounded_mask(size: int) -> Image.Image:
    """A squircle mask, supersampled so the edge stays smooth at every export
    size. Aliasing on a 1024 canvas shows immediately in the Finder and in the
    Dock, so the mask is built at 4x and downscaled.
    """
    supersample = 4
    big = size * supersample
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon(superellipse_points(big), fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def radial_vignette(size: int, inner: tuple[int, int, int], outer: tuple[int, int, int]) -> Image.Image:
    """A radial gradient background, built small and scaled up.

    Per-pixel computation of a gradient in Python is slow, so it is computed at
    a low resolution and resampled — at 1024px the eye cannot see the seams,
    and the whole render stays well under a second.
    """
    resolution = 128
    gradient = Image.new("RGB", (resolution, resolution))
    pixels = gradient.load()
    centre = (resolution - 1) / 2.0
    max_distance = math.hypot(centre, centre)

    for y in range(resolution):
        for x in range(resolution):
            distance = math.hypot(x - centre, y - centre) / max_distance
            # Smoothstep, so the falloff does not band at the outer edge.
            factor = distance * distance * (3.0 - 2.0 * distance)
            pixels[x, y] = tuple(
                int(inner[channel] + (outer[channel] - inner[channel]) * factor)
                for channel in range(3)
            )
    return gradient.resize((size, size), Image.BICUBIC)


def tile(size: int) -> Image.Image:
    """The full icon at the requested square size."""
    if size < 512:
        # Below 512 the detail in the rings stops reading; render the small
        # sizes from a downsample of the master rather than recomputing them,
        # which keeps the rings from turning into mush.
        return None  # type: ignore[return-value]

    image = radial_vignette(size, inner=(24, 30, 34), outer=(8, 11, 14))

    centre = size / 2.0
    unit = size / 1024.0

    # ---- Concentric radar rings -----------------------------------------
    ring_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ring_draw = ImageDraw.Draw(ring_layer)

    rings = [
        (200.0, 26.0, 90),    # outer, faint
        (150.0, 22.0, 140),   # middle
        (100.0, 20.0, 205),   # inner, brightest
    ]
    for radius, width, opacity in rings:
        ring_draw.ellipse(
            [
                centre - radius * unit,
                centre - radius * unit,
                centre + radius * unit,
                centre + radius * unit,
            ],
            outline=(125, 255, 214, opacity),
            width=max(1, int(width * unit)),
        )

    # ---- Focal point ------------------------------------------------------
    glow_radius = 62.0 * unit
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(
        [
            centre - glow_radius * 2.6,
            centre - glow_radius * 2.6,
            centre + glow_radius * 2.6,
            centre + glow_radius * 2.6,
        ],
        fill=(16, 212, 168, 90),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=28 * unit))

    core = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    core_draw = ImageDraw.Draw(core)
    core_draw.ellipse(
        [
            centre - glow_radius,
            centre - glow_radius,
            centre + glow_radius,
            centre + glow_radius,
        ],
        fill=(176, 255, 238, 255),
    )

    image = Image.alpha_composite(image.convert("RGBA"), glow)
    image = Image.alpha_composite(image, ring_layer)
    image = Image.alpha_composite(image, core)

    # ---- Specular sheen along the top edge, so the tile reads as glass ----
    sheen = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sheen_draw = ImageDraw.Draw(sheen)
    sheen_draw.ellipse(
        [
            centre - 300 * unit,
            centre - 420 * unit,
            centre + 300 * unit,
            centre - 60 * unit,
        ],
        fill=(255, 255, 255, 26),
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(radius=40 * unit))
    image = Image.alpha_composite(image, sheen)

    return image


def build_master() -> Image.Image:
    """The 1024 master render, cropped to the squircle."""
    master = tile(CANVAS)
    mask = rounded_mask(CANVAS)
    master.putalpha(mask)
    return master


def export_iconset(master: Image.Image, directory: str) -> str:
    iconset = os.path.join(directory, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    for name, size in ICON_SIZES:
        path = os.path.join(iconset, f"{name}.png")
        master.resize((size, size), Image.LANCZOS).save(path, format="PNG")
        print(f"  wrote {name}.png ({size}px)")

    return iconset


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        default=os.path.join("Resources", "AppIcon.icns"),
        help="Destination .icns path (default: Resources/AppIcon.icns)",
    )
    args = parser.parse_args()

    if shutil.which("iconutil") is None:
        print("error: iconutil not found; install the Xcode command line tools", file=sys.stderr)
        return 1

    destination = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(destination), exist_ok=True)

    print(f"Rendering {CANVAS}px master…")
    master = build_master()

    with tempfile.TemporaryDirectory(prefix="daypilot-icon-") as workspace:
        iconset = export_iconset(master, workspace)

        # iconutil writes the set as a single .icns.
        result = subprocess.run(
            ["iconutil", "--convert", "icns", "--output", destination, iconset],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"error: iconutil failed\n{result.stderr}", file=sys.stderr)
            return 1

    print(f"\nWrote {destination} ({os.path.getsize(destination)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
