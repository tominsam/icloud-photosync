// Copyright 2026 Thomas Insam. All rights reserved.


import CoreLocation
import Foundation

/// Converts a GPS coordinate to a TimeZone using a precomputed 0.25° lookup grid.
///
/// The grid is stored in `Resources/timezone_polygons.bin` — a flat uint16 array (1440×720 cells,
/// lat 90→-90, lng -180→180) compressed with lzma via `NSData.compressed(using: .lzma)`.
/// Each cell contains an index into the timezone string table stored in the same file.
///
/// To regenerate: `pip3 install timezonefinder && python3 scripts/generate_timezone_grid.py`
/// Requires Swift to be on PATH (uses a Swift snippet to compress the output with lzma).
final class TimezoneMapper {

    static func latLngToTimezoneString(_ location: CLLocationCoordinate2D) -> String {
        return grid.lookup(lat: Float(location.latitude), lng: Float(location.longitude))
    }

    static func latLngToTimezone(_ location: CLLocationCoordinate2D) -> TimeZone? {
        let id = latLngToTimezoneString(location)
        return TimeZone(identifier: id)
    }

    private static let grid: TimezoneGrid = {
        guard let url = Bundle(for: TimezoneMapper.self).url(forResource: "timezone_polygons", withExtension: "bin"),
              let compressed = try? Data(contentsOf: url),
              let data = try? (compressed as NSData).decompressed(using: .lzma) as Data else {
            return TimezoneGrid()
        }
        return TimezoneGrid(data: data)
    }()
}

// MARK: - Grid

private struct TimezoneGrid {
    let step: Float
    let width: Int
    let height: Int
    let zones: [String]
    let cells: [UInt16]

    /// Empty fallback used when the resource file cannot be loaded.
    init() {
        step = 1; width = 0; height = 0; zones = ["unknown"]; cells = []
    }

    /// Parse the binary grid file written by the generation script.
    /// Format: magic(4) step(f32) width(u16) height(u16) numZones(u16)
    ///         [u8 len + UTF-8 bytes] × numZones
    ///         [u16] × (width × height)  — row-major, lat 90→-90, lng -180→180
    init(data: Data) {
        var offset = 4 // skip "TZGR" magic

        func readU8() -> UInt8 {
            defer { offset += 1 }
            return data[offset]
        }
        func readU16() -> UInt16 {
            defer { offset += 2 }
            return data[offset..<offset+2].withUnsafeBytes { $0.load(as: UInt16.self) }
        }
        func readF32() -> Float {
            defer { offset += 4 }
            return data[offset..<offset+4].withUnsafeBytes { $0.load(as: Float.self) }
        }

        step   = readF32()
        width  = Int(readU16())
        height = Int(readU16())

        let numZones = Int(readU16())
        var zoneList = [String]()
        zoneList.reserveCapacity(numZones)
        for _ in 0..<numZones {
            let len = Int(readU8())
            zoneList.append(String(bytes: data[offset..<offset+len], encoding: .utf8) ?? "unknown")
            offset += len
        }
        zones = zoneList

        let cellCount = width * height
        cells = (0..<cellCount).map { i in
            data[offset + i*2 ..< offset + i*2 + 2].withUnsafeBytes { $0.load(as: UInt16.self) }
        }
    }

    func lookup(lat: Float, lng: Float) -> String {
        guard width > 0 else { return "unknown" }
        let col = max(0, min(Int((lng + 180.0) / step), width  - 1))
        let row = max(0, min(Int((90.0  - lat)  / step), height - 1))
        let idx = Int(cells[row * width + col])
        return idx < zones.count ? zones[idx] : "unknown"
    }
}
