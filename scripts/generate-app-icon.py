#!/usr/bin/env python3
"""Optional asset authoring helper: python3 -m pip install Pillow==12.3.0.

The committed opaque PNGs are original geometric artwork; running builds
does not require Pillow or regenerate these files.
"""
import json
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "Apps/FirePrivacyApp/Assets.xcassets/AppIcon.appiconset"
scale = 3
canvas = Image.new("RGB", (1024 * scale, 1024 * scale))
pixels = canvas.load()
for y in range(canvas.height):
    for x in range(canvas.width):
        glow = max(0, 1 - (((x / scale - 512) / 750) ** 2 + ((y / scale - 380) / 700) ** 2))
        t = y / canvas.height
        pixels[x, y] = (int(8 + 6 * glow), int(17 + 12 * glow + 3 * (1 - t)), int(29 + 15 * glow))
draw = ImageDraw.Draw(canvas)


def path(start, segments):
    points = [start]
    current = start
    for c1, c2, end in segments:
        for step in range(1, 49):
            t = step / 48
            u = 1 - t
            points.append((u ** 3 * current[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t ** 3 * end[0],
                           u ** 3 * current[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t ** 3 * end[1]))
        current = end
    return [(round(x * scale), round(y * scale)) for x, y in points]


shield = path((512, 172), [
    ((590, 224), (701, 258), (787, 272)),
    ((788, 540), (756, 684), (512, 851)),
    ((269, 684), (236, 540), (237, 272)),
    ((324, 258), (434, 224), (512, 172)),
])
draw.polygon(shield, fill="#102F38")
draw.line(shield + [shield[0]], fill="#62D9C4", width=22 * scale, joint="curve")
flame = path((544, 312), [
    ((553, 393), (599, 414), (624, 470)),
    ((674, 575), (626, 678), (516, 696)),
    ((396, 707), (350, 630), (380, 545)),
    ((400, 488), (448, 463), (463, 420)),
    ((474, 443), (475, 466), (470, 490)),
    ((534, 439), (510, 373), (544, 312)),
])
draw.polygon(flame, fill="#FFAA6B")
inner = path((521, 504), [
    ((541, 544), (572, 563), (568, 604)),
    ((565, 646), (543, 666), (512, 671)),
    ((466, 673), (443, 646), (451, 614)),
    ((459, 578), (504, 556), (521, 504)),
])
draw.polygon(inner, fill="#102F38")
master = canvas.resize((1024, 1024), Image.Resampling.LANCZOS)
entries = []
sizes = {"iphone": [(20, 2), (20, 3), (29, 2), (29, 3), (40, 2), (40, 3), (60, 2), (60, 3)],
         "ipad": [(20, 1), (20, 2), (29, 1), (29, 2), (40, 1), (40, 2), (76, 1), (76, 2), (83.5, 2)],
         "ios-marketing": [(1024, 1)]}
DESTINATION.mkdir(parents=True, exist_ok=True)
for idiom, variants in sizes.items():
    for size, factor in variants:
        length = int(size * factor)
        filename = f"icon-{length}.png"
        master.resize((length, length), Image.Resampling.LANCZOS).save(DESTINATION / filename)
        entries.append({"filename": filename, "idiom": idiom, "scale": f"{factor}x", "size": f"{size}x{size}"})
(DESTINATION / "Contents.json").write_text(json.dumps({"images": entries, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
print("Generated opaque app icons for iPhone, iPad and App Store.")
