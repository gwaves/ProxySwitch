"""
Generate the macOS app icon (AppIcon.appiconset).

Creates a blue globe with yellow switch-arrows overlay at all required
sizes for macOS (16x16 through 512x512 @2x = 1024x1024).

Usage:
    python generate_icon.py

Requirements:
    pip install Pillow
"""
import math
from PIL import Image, ImageDraw, ImageFont

def create_icon(size):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    margin = size * 0.04
    radius = (size - margin * 2) / 2
    cx, cy = size / 2, size / 2

    # Background gradient - dark blue circle
    bg_color = (30, 58, 138)       # Deep blue
    highlight_color = (59, 130, 246)  # Bright blue

    # Draw main circle background
    draw.ellipse([margin, margin, size - margin, size - margin], fill=bg_color)

    # Draw globe grid lines
    line_color = (96, 165, 250, 120)  # Light blue, semi-transparent
    line_width = max(1, int(size / 128))

    # Horizontal lines (latitude)
    for i in range(-2, 3):
        y_off = i * radius * 0.3
        r = radius * math.cos(math.asin(abs(i * 0.3))) if abs(i * 0.3) <= 1 else 0
        if r > 0:
            draw.arc(
                [cx - r + 0, cy + y_off - r * 0.3, cx + r + 0, cy + y_off + r * 0.3],
                0, 180, fill=line_color, width=line_width
            )
            draw.arc(
                [cx - r + 0, cy + y_off - r * 0.3, cx + r + 0, cy + y_off + r * 0.3],
                180, 360, fill=line_color, width=line_width
            )

    # Vertical ellipse (longitude center)
    vert_squeeze = 0.6
    draw.ellipse(
        [cx - radius * vert_squeeze, margin, cx + radius * vert_squeeze, size - margin],
        outline=line_color, width=line_width
    )

    # Outer circle (globe outline)
    draw.ellipse(
        [margin, margin, size - margin, size - margin],
        outline=(147, 197, 253, 180), width=line_width + 1
    )

    # Draw switch arrows - two curved arrows forming a cycle
    arrow_color = (250, 204, 21)  # Yellow/gold
    arrow_width = max(2, int(size / 32))

    # Arrow arc parameters
    arc_r = radius * 0.55
    arc_cx, arc_cy = cx, cy

    # Upper arrow (clockwise, right side)
    bbox1 = [arc_cx - arc_r, arc_cy - arc_r, arc_cx + arc_r, arc_cy + arc_r]
    draw.arc(bbox1, -30, 120, fill=arrow_color, width=arrow_width)

    # Arrowhead for upper arc (pointing right-down)
    ah_size = size * 0.07
    angle = math.radians(120)
    ax = arc_cx + arc_r * math.cos(angle)
    ay = arc_cy - arc_r * math.sin(angle)

    p1 = (ax + ah_size * math.cos(math.radians(150)),
          ay - ah_size * math.sin(math.radians(150)))
    p2 = (ax + ah_size * math.cos(math.radians(210)),
          ay - ah_size * math.sin(math.radians(210)))
    draw.polygon([p1, p2, (ax, ay)], fill=arrow_color)

    # Lower arrow (clockwise, left side)
    draw.arc(bbox1, 150, 300, fill=arrow_color, width=arrow_width)

    # Arrowhead for lower arc (pointing left-up)
    angle2 = math.radians(-60)
    ax2 = arc_cx + arc_r * math.cos(angle2)
    ay2 = arc_cy - arc_r * math.sin(angle2)

    p3 = (ax2 + ah_size * math.cos(math.radians(-30)),
          ay2 - ah_size * math.sin(math.radians(-30)))
    p4 = (ax2 + ah_size * math.cos(math.radians(-90)),
          ay2 - ah_size * math.sin(math.radians(-90)))
    draw.polygon([p3, p4, (ax2, ay2)], fill=arrow_color)

    return img


# macOS icon sizes required by Xcode asset catalog
sizes = [16, 32, 64, 128, 256, 512]
output_dir = '/Users/gwaves/code/proxy-switch/ProxySwitch/Assets.xcassets/AppIcon.appiconset'

for s in sizes:
    icon = create_icon(s)
    icon.save(f'{output_dir}/icon_{s}x{s}.png')
    print(f'Created {s}x{s}')

# @2x retina variants
for s in [16, 32, 64, 128, 256]:
    icon = create_icon(s * 2)
    icon.save(f'{output_dir}/icon_{s}x{s}@2x.png')
    print(f'Created {s}x{s}@2x')

print('Done!')
