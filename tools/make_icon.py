#!/usr/bin/env python3
"""Draw a minimal app icon (a chevron in a rounded square) and pack an .icns."""
import os, subprocess, sys, tempfile

OUT = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns"

SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3a3f4b"/><stop offset="1" stop-color="#15171c"/>
    </linearGradient>
  </defs>
  <rect x="64" y="64" width="896" height="896" rx="200" fill="url(#g)"/>
  <path d="M512 250 L742 774 L512 646 L282 774 Z" fill="#ffffff" opacity="0.95"/>
</svg>"""

with tempfile.TemporaryDirectory() as td:
    svg = os.path.join(td, "icon.svg")
    open(svg, "w").write(SVG)
    iconset = os.path.join(td, "AppIcon.iconset")
    os.makedirs(iconset)
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for s in sizes:
        png = os.path.join(iconset, f"icon_{s}x{s}.png")
        # qlmanage/sips cannot rasterize SVG reliably; use CoreGraphics via a tiny swift-free path.
        r = subprocess.run(["/usr/bin/qlmanage", "-t", "-s", str(s), "-o", td, svg],
                           capture_output=True)
        produced = os.path.join(td, "icon.svg.png")
        if os.path.exists(produced):
            subprocess.run(["/usr/bin/sips", "-z", str(s), str(s), produced, "--out", png],
                           capture_output=True)
            os.remove(produced)
        else:
            sys.exit(0)  # no rasterizer: skip icon silently
    # standard iconset naming
    for s in sizes:
        src = os.path.join(iconset, f"icon_{s}x{s}.png")
        if s in (32, 64, 256, 512, 1024) and os.path.exists(src):
            half = s // 2
            dst = os.path.join(iconset, f"icon_{half}x{half}@2x.png")
            subprocess.run(["/bin/cp", src, dst], capture_output=True)
    subprocess.run(["/usr/bin/iconutil", "-c", "icns", iconset, "-o", OUT], capture_output=True)
