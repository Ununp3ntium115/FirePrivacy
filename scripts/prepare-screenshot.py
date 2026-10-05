#!/usr/bin/env python3
"""Check a native PNG capture and remove alpha using macOS's JPEG exporter.

This only prepares the file format; it does not redraw, resize, or synthesize
the app screenshot. App Store screenshot size and content still need review.
"""
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import zlib


def png_details(path):
    if path.stat().st_size > 100 * 1024 * 1024:
        raise ValueError("Screenshot PNG exceeds the expected size.")
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Screenshot is not a PNG file.")
    offset, dimensions, alpha, ended = 8, None, False, False
    while offset + 12 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("Screenshot contains a truncated PNG chunk.")
        payload = data[offset + 8:end - 4]
        expected_crc = struct.unpack_from(">I", data, end - 4)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != expected_crc:
            raise ValueError("Screenshot PNG checksum is invalid.")
        if kind == b"IHDR":
            if offset != 8 or length != 13:
                raise ValueError("Screenshot PNG header is invalid.")
            width, height, depth, color, _, _, _ = struct.unpack(">IIBBBBB", payload)
            if width < 1 or height < 1:
                raise ValueError("Screenshot dimensions are invalid.")
            dimensions = (width, height)
            # RGB/8-bit without transparency is directly suitable for export.
            alpha = color != 2 or depth != 8
        elif kind == b"tRNS":
            alpha = True
        elif kind == b"IEND":
            ended = True
            break
        offset = end
    if dimensions is None or not ended:
        raise ValueError("Screenshot PNG is incomplete.")
    return dimensions, alpha


def prepare(path):
    dimensions, needs_conversion = png_details(path)
    result = path
    if needs_conversion:
        if sys.platform != "darwin":
            raise ValueError("Removing screenshot alpha requires macOS sips.")
        result = path.with_suffix(".jpg")
        subprocess.run(["/usr/bin/sips", "--setProperty", "format", "jpeg",
                        "--setProperty", "formatOptions", "100", str(path),
                        "--out", str(result)], check=True, capture_output=True)
        metadata = subprocess.check_output(["/usr/bin/sips", "--getProperty", "pixelWidth",
                                             "--getProperty", "pixelHeight", str(result)], text=True)
        width = re.search(r"pixelWidth:\s*(\d+)", metadata)
        height = re.search(r"pixelHeight:\s*(\d+)", metadata)
        if not width or not height or (int(width[1]), int(height[1])) != dimensions:
            result.unlink(missing_ok=True)
            raise ValueError("JPEG export changed screenshot dimensions.")
        if result.read_bytes()[:2] != b"\xff\xd8":
            result.unlink(missing_ok=True)
            raise ValueError("Screenshot export is not a JPEG file.")
        path.unlink()
    print(json.dumps({"screenshot": str(result), "width": dimensions[0],
                      "height": dimensions[1], "alpha": False}))


if __name__ == "__main__":
    try:
        prepare(Path(sys.argv[1]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Screenshot preparation failed: {error}") from None
