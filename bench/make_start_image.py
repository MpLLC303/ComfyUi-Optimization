#!/usr/bin/env python3
"""Create the 640x640 start frame used by the I2V benchmark workflow (idempotent)."""

import os
import sys

from PIL import Image, ImageDraw


def main():
    path = sys.argv[1]
    if os.path.exists(path):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im = Image.new("RGB", (640, 640))
    d = ImageDraw.Draw(im)
    for y in range(640):
        d.line([(0, y), (639, y)], fill=(40 + y // 4, 90, 200 - y // 4))
    d.ellipse([220, 160, 420, 360], fill=(230, 190, 150))
    d.rectangle([250, 360, 390, 600], fill=(60, 60, 110))
    im.save(path)


if __name__ == "__main__":
    main()
