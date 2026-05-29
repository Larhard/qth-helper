#!/usr/bin/env python3
"""
Generates the QTH Helper app icon (assets/icon/app_icon.png).

Design: dark navy circle, 8-spoke compass rose, concentric rings,
        the same cyan navigation arrow as used inside the app.

Run:
    python scripts/generate_icon.py
"""
import os
import math
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    print("Pillow not found — installing…")
    import subprocess
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'Pillow'])
    from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
HALF = SIZE // 2

# ── Canvas ──────────────────────────────────────────────────────────────────
img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# ── Background circle ────────────────────────────────────────────────────────
BG = (10, 15, 30, 255)
draw.ellipse([0, 0, SIZE - 1, SIZE - 1], fill=BG)

# ── Compass-rose spokes (8 directions) ───────────────────────────────────────
SPOKE_COLOR = (18, 35, 65, 255)
for angle_deg in range(0, 360, 45):
    rad = math.radians(angle_deg)
    sx, sy = math.sin(rad), -math.cos(rad)
    x1 = HALF + sx * HALF * 0.08
    y1 = HALF + sy * HALF * 0.08
    x2 = HALF + sx * HALF * 0.86
    y2 = HALF + sy * HALF * 0.86
    draw.line([(x1, y1), (x2, y2)], fill=SPOKE_COLOR, width=5)

# ── Concentric rings ─────────────────────────────────────────────────────────
for frac, alpha in [(0.84, 35), (0.56, 22), (0.30, 14)]:
    r = HALF * frac
    draw.ellipse(
        [HALF - r, HALF - r, HALF + r, HALF + r],
        outline=(0, 110, 170, alpha),
        width=3,
    )

# ── Cardinal tick marks ───────────────────────────────────────────────────────
TICK_COLOR = (0, 80, 120, 160)
for angle_deg in range(0, 360, 90):
    rad = math.radians(angle_deg)
    sx, sy = math.sin(rad), -math.cos(rad)
    inner = HALF * 0.78
    outer = HALF * 0.88
    x1 = HALF + sx * inner
    y1 = HALF + sy * inner
    x2 = HALF + sx * outer
    y2 = HALF + sy * outer
    draw.line([(x1, y1), (x2, y2)], fill=TICK_COLOR, width=8)

# ── Navigation arrow (same proportions as the in-app ArrowWidget) ────────────
R = HALF * 0.72   # radius that the arrow tip reaches

def pt(dx_frac, dy_frac):
    """Convert arrow-space fraction to pixel coordinate."""
    return (HALF + dx_frac * R, HALF + dy_frac * R)

ARROW_SHAPE = [
    pt( 0.000, -1.000),   # tip
    pt( 0.320, -0.180),   # right wing outer
    pt( 0.110, -0.180),   # right wing inner / shaft start
    pt( 0.110,  0.750),   # shaft bottom right
    pt(-0.110,  0.750),   # shaft bottom left
    pt(-0.110, -0.180),   # left wing inner / shaft start
    pt(-0.320, -0.180),   # left wing outer
]

# Soft glow behind arrow
glow_img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
glow_draw = ImageDraw.Draw(glow_img)
glow_draw.polygon(ARROW_SHAPE, fill=(0, 180, 255, 90))
glow_blurred = glow_img.filter(ImageFilter.GaussianBlur(radius=22))
img = Image.alpha_composite(img, glow_blurred)

# Re-draw the main layers on top of the glow
draw = ImageDraw.Draw(img)

# Arrow body — bright cyan
draw.polygon(ARROW_SHAPE, fill=(0, 225, 255, 255))

# Subtle highlight on the left edge of the tip for depth
highlight = [
    pt( 0.000, -1.000),
    pt( 0.000, -0.180),
    pt(-0.110, -0.180),
    pt(-0.320, -0.180),
]
draw.polygon(highlight, fill=(80, 240, 255, 180))

# ── Centre dot ───────────────────────────────────────────────────────────────
dot_r = HALF * 0.045
draw.ellipse(
    [HALF - dot_r, HALF - dot_r, HALF + dot_r, HALF + dot_r],
    fill=(0, 200, 235, 255),
)

# ── Outer border ring ─────────────────────────────────────────────────────────
draw.ellipse([6, 6, SIZE - 7, SIZE - 7], outline=(0, 70, 120, 200), width=7)

# ── Clip to circle (anti-aliased mask) ───────────────────────────────────────
mask = Image.new('L', (SIZE, SIZE), 0)
ImageDraw.Draw(mask).ellipse([0, 0, SIZE - 1, SIZE - 1], fill=255)
img.putalpha(mask)

# ── Save ──────────────────────────────────────────────────────────────────────
out_dir = os.path.join(os.path.dirname(__file__), '..', 'assets', 'icon')
os.makedirs(out_dir, exist_ok=True)

flat_path = os.path.join(out_dir, 'app_icon.png')

# Flat icon (transparent background turned to #0A0F1E for flutter_launcher_icons)
flat = Image.new('RGB', (SIZE, SIZE), (10, 15, 30))
flat.paste(img, mask=img.split()[3])
flat.save(flat_path, 'PNG', optimize=True)
print(f"Icon saved  → {flat_path}")

# Also save the RGBA version (with transparency) for adaptive foreground
fg_path = os.path.join(out_dir, 'app_icon_fg.png')
img.save(fg_path, 'PNG', optimize=True)
print(f"Adaptive FG → {fg_path}")
