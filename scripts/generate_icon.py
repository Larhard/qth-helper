#!/usr/bin/env python3
"""
Generates the QTH Dashboard app icon (assets/icon/app_icon.png).

Design mirrors the in-app wind-rose / bearing-ring aesthetic:
  - Near-black circular background
  - White bearing ring with cardinal crosshair tick marks
  - Red arc at North (matches the wind-rose N indicator: kDEmg = #FF3333)
  - Green heading arrow pointing up (matches GPS colour: kDGps = #55DD55)
  - Subtle concentric inner ring for depth

Run:
    python scripts/generate_icon.py          # or python3 on Linux/macOS
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
CX, CY = HALF, HALF

# ── Palette (matches app's kD* constants) ────────────────────────────────────
BG          = (10,  10,  10, 255)   # near-black — same as app panels
RING        = (255, 255, 255, 110)  # white ring, ~43 % opacity
TICK_CARD   = (255, 255, 255, 170)  # cardinal tick marks
TICK_INTER  = (255, 255, 255,  90)  # intercardinal ticks
NORTH_RED   = (255,  51,  51, 255)  # #FF3333 = kDEmg (North arc)
GPS_GREEN   = ( 85, 221,  85, 255)  # #55DD55 = kDGps (arrow body)
GPS_GLOW    = ( 85, 221,  85,  65)  # green glow behind arrow
GPS_HILITE  = (160, 245, 160, 150)  # highlight edge on arrow tip
INNER_RING  = (255, 255, 255,  38)  # secondary inner ring

img  = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# ── Background circle ─────────────────────────────────────────────────────────
draw.ellipse([0, 0, SIZE-1, SIZE-1], fill=BG)

# ── Main bearing ring ─────────────────────────────────────────────────────────
RING_R = int(HALF * 0.76)

def ring_box(r):
    return [CX-r, CY-r, CX+r, CY+r]

draw.ellipse(ring_box(RING_R), outline=RING, width=7)

# ── Inner decorative ring ─────────────────────────────────────────────────────
INNER_R = int(HALF * 0.50)
draw.ellipse(ring_box(INNER_R), outline=INNER_RING, width=4)

# ── Cardinal (N/E/S/W) and intercardinal tick marks ───────────────────────────
# Ticks point INWARD from the ring (matches app's bearing ring ticks).
for i in range(8):
    if i == 0:
        continue  # North handled separately
    angle_deg  = i * 45 - 90   # -90° so 0° = up
    rad        = math.radians(angle_deg)
    sin_a      = math.sin(rad)
    cos_a      = math.cos(rad)
    is_card    = (i % 2 == 0)
    tick_len   = RING_R * (0.16 if is_card else 0.10)
    tick_w     = 9 if is_card else 5
    color      = TICK_CARD if is_card else TICK_INTER
    x1 = CX + sin_a * RING_R
    y1 = CY + cos_a * RING_R
    x2 = CX + sin_a * (RING_R - tick_len)
    y2 = CY + cos_a * (RING_R - tick_len)
    draw.line([(x1, y1), (x2, y2)], fill=color, width=tick_w)

# ── North indicator: thick red arc on ring + inward pointer ──────────────────
# Arc spans ±22° around North (top of ring).
# PIL arc angles: 0° = right, going clockwise; 270° = top.
ARC_HALF = 22
arc_start = 270 - ARC_HALF
arc_end   = 270 + ARC_HALF

# Draw the arc with multiple widths for a soft glow effect
for w, alpha in [(30, 60), (22, 120), (14, 200), (8, 255)]:
    col = (*NORTH_RED[:3], alpha)
    draw.arc(ring_box(RING_R), arc_start, arc_end, fill=col, width=w)

# Inward red pointer from ring centre of arc
POINTER_LEN = RING_R * 0.22
x1 = CX
y1 = CY - RING_R
x2 = CX
y2 = CY - RING_R + POINTER_LEN
draw.line([(x1, y1), (x2, y2)], fill=NORTH_RED, width=16)

# ── Heading arrow (green, pointing up — same shape as ArrowWidget) ────────────
AR = HALF * 0.58   # arrow radius (tip distance from centre)

def ap(dx, dy):
    return (CX + dx * AR, CY + dy * AR)

ARROW = [
    ap( 0.000, -1.000),  # tip
    ap( 0.330, -0.200),  # right wing outer
    ap( 0.110, -0.200),  # right wing inner / shaft
    ap( 0.110,  0.740),  # shaft bottom-right
    ap(-0.110,  0.740),  # shaft bottom-left
    ap(-0.110, -0.200),  # left wing inner / shaft
    ap(-0.330, -0.200),  # left wing outer
]

# Soft green glow layer
glow = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
ImageDraw.Draw(glow).polygon(ARROW, fill=GPS_GLOW)
img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(radius=30)))
draw = ImageDraw.Draw(img)

# Arrow body
draw.polygon(ARROW, fill=GPS_GREEN)

# Highlight on tip's left edge for depth
draw.polygon([ap(0, -1), ap(0, -0.2), ap(-0.11, -0.2), ap(-0.33, -0.2)],
             fill=GPS_HILITE)

# ── Centre dot ────────────────────────────────────────────────────────────────
dot_r = HALF * 0.042
draw.ellipse([CX-dot_r, CY-dot_r, CX+dot_r, CY+dot_r],
             fill=(160, 245, 160, 255))

# ── Outer border ring (very subtle frame) ─────────────────────────────────────
draw.ellipse([8, 8, SIZE-9, SIZE-9], outline=(60, 60, 60, 160), width=8)

# ── Clip to circle (anti-aliased mask) ───────────────────────────────────────
mask = Image.new('L', (SIZE, SIZE), 0)
ImageDraw.Draw(mask).ellipse([0, 0, SIZE-1, SIZE-1], fill=255)
img.putalpha(mask)

# ── Save flat + adaptive foreground ─────────────────────────────────────────
out_dir = os.path.join(os.path.dirname(__file__), '..', 'assets', 'icon')
os.makedirs(out_dir, exist_ok=True)

flat_path = os.path.join(out_dir, 'app_icon.png')
flat = Image.new('RGB', (SIZE, SIZE), (10, 10, 10))
flat.paste(img, mask=img.split()[3])
flat.save(flat_path, 'PNG', optimize=True)
print("Icon saved  -> " + flat_path)

fg_path = os.path.join(out_dir, 'app_icon_fg.png')
img.save(fg_path, 'PNG', optimize=True)
print("Adaptive FG -> " + fg_path)
