"""
Generate menu bar icons for the ProxySwitch status bar item.

Creates two variants:
  - MenuBarIcon.png / @2x — filled globe (proxy enabled state)
  - MenuBarIcon_off.png / @2x — outline globe (proxy disabled state)

Usage:
    python generate_menubar_icon.py

Requirements:
    pip install Pillow
"""
from PIL import Image, ImageDraw
import math


def create_menu_bar_icon(size, filled=False):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cx, cy = size / 2, size / 2
    r = size * 0.4

    if filled:
        # Filled globe for "proxy on" state
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(26, 26, 26, 230))

        # Grid lines
        lc = (180, 180, 180, 180)
        lw = max(1, size // 24)
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=lc, width=lw)

        # Center vertical longitude line
        sq = 0.5
        draw.ellipse([cx - r * sq, cy - r, cx + r * sq, cy + r], outline=lc, width=lw)

        # Horizontal latitude lines
        for i in [-0.35, 0, 0.35]:
            yy = cy + r * i
            rr = r * math.sqrt(1 - i * i) if abs(i) < 1 else 0
            if rr > 0:
                draw.line([cx - rr, yy, cx + rr, yy], fill=lc, width=lw)

        # Small green switch-indicator dot
        dot_r = size * 0.08
        dot_x = cx + r * 0.6
        dot_y = cy - r * 0.6
        draw.ellipse([dot_x - dot_r, dot_y - dot_r, dot_x + dot_r, dot_y + dot_r],
                     fill=(52, 199, 89, 255))
    else:
        # Outline globe for "proxy off" state
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(26, 26, 26, 200), width=max(1, size // 20))

        lc = (26, 26, 26, 160)
        lw = max(1, size // 28)

        sq = 0.5
        draw.ellipse([cx - r * sq, cy - r, cx + r * sq, cy + r], outline=lc, width=lw)

        for i in [-0.35, 0, 0.35]:
            yy = cy + r * i
            rr = r * math.sqrt(1 - i * i) if abs(i) < 1 else 0
            if rr > 0:
                draw.line([cx - rr, yy, cx + rr, yy], fill=lc, width=lw)

    return img


# Generate both on/off variants at 1x and 2x
for suffix, filled in [('', True), ('_off', False)]:
    for scale in [1, 2]:
        s = 16 * scale
        icon = create_menu_bar_icon(s, filled=filled)
        tag = f'@{scale}x' if scale == 2 else ''
        icon.save(f'/Users/gwaves/code/proxy-switch/ProxySwitch/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon{suffix}{tag}.png')
        print(f'Created MenuBarIcon{suffix}{tag}.png ({s}x{s})')

print('Done!')
