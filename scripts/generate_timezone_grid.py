#!/usr/bin/env python3
"""
Regenerates PhotoSync/Resources/timezone_polygons.bin

Requires: pip3 install timezonefinder

Output: a zlib-compressed binary file containing a 0.25° lat/lng lookup grid.

Uncompressed format:
  magic:     4 bytes  "TZGR"
  step:      float32  grid step in degrees (0.25)
  width:     uint16   longitude cells (1440)
  height:    uint16   latitude cells (720)
  num_zones: uint16   number of unique timezone strings
  zones:     [uint8 length + UTF-8 bytes] × num_zones  (index 0 = "unknown")
  grid:      [uint16] × (width × height), row-major, lat 90→-90, lng -180→180

The file on disk is the zlib-compressed form of the above.
"""

import os, struct
from timezonefinder import TimezoneFinder

STEP   = 0.25
WIDTH  = int(360 / STEP)   # 1440
HEIGHT = int(180 / STEP)   # 720
OUTPUT = os.path.join(os.path.dirname(__file__), "../PhotoSync/Resources/timezone_polygons.bin")

tf = TimezoneFinder()

zone_to_idx = {"unknown": 0}
zones = ["unknown"]
grid = []

import time
start = time.time()
for r in range(HEIGHT):
    lat = 90.0 - (r + 0.5) * STEP
    for c in range(WIDTH):
        lng = -180.0 + (c + 0.5) * STEP
        tz = tf.timezone_at(lat=lat, lng=lng) or "unknown"
        if tz not in zone_to_idx:
            zone_to_idx[tz] = len(zones)
            zones.append(tz)
        grid.append(zone_to_idx[tz])
    if (r + 1) % 72 == 0:
        print(f"  {(r+1)/HEIGHT*100:.0f}% ({time.time()-start:.1f}s)")

print(f"Done: {len(zones)} timezones, {len(grid):,} cells ({time.time()-start:.1f}s)")

buf = bytearray()
buf += b"TZGR"
buf += struct.pack("<f", STEP)
buf += struct.pack("<HH", WIDTH, HEIGHT)
buf += struct.pack("<H", len(zones))
for z in zones:
    b = z.encode("utf-8")
    buf += struct.pack("B", len(b))
    buf += b
buf += struct.pack(f"<{len(grid)}H", *grid)

raw_path = OUTPUT + ".raw"
with open(raw_path, "wb") as f:
    f.write(buf)
print(f"Raw binary: {len(buf):,} bytes → compressing with lzma via Swift...")

import subprocess, os
swift_script = """
import Foundation
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let compressed = try! (raw as NSData).compressed(using: .lzma) as Data
try! compressed.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("Wrote \\(compressed.count) bytes")
"""
script_path = "/tmp/compress_grid.swift"
with open(script_path, "w") as f:
    f.write(swift_script)
subprocess.run(["swift", script_path, raw_path, OUTPUT], check=True)
os.remove(raw_path)
os.remove(script_path)
