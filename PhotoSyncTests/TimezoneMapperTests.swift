// Copyright 2024 Thomas Insam. All rights reserved.

import CoreLocation
import Testing
@testable import PhotoSync

struct TimezoneMapperTests {

    // MARK: - Known cities

    @Test func newYork() {
        let tz = TimezoneMapper.latLngToTimezone(CLLocationCoordinate2D(latitude: 40.71, longitude: -74.01))
        #expect(tz?.identifier == "America/New_York")
    }

    @Test func london() {
        let tz = TimezoneMapper.latLngToTimezone(CLLocationCoordinate2D(latitude: 51.51, longitude: -0.13))
        #expect(tz?.identifier == "Europe/London")
    }

    @Test func tokyo() {
        let tz = TimezoneMapper.latLngToTimezone(CLLocationCoordinate2D(latitude: 35.68, longitude: 139.69))
        #expect(tz?.identifier == "Asia/Tokyo")
    }

    @Test func sydney() {
        let tz = TimezoneMapper.latLngToTimezone(CLLocationCoordinate2D(latitude: -33.87, longitude: 151.21))
        #expect(tz?.identifier == "Australia/Sydney")
    }

    @Test func losAngeles() {
        let tz = TimezoneMapper.latLngToTimezone(CLLocationCoordinate2D(latitude: 34.05, longitude: -118.24))
        #expect(tz?.identifier == "America/Los_Angeles")
    }

    @Test func berlin() {
        let tz = TimezoneMapper.latLngToTimezone(CLLocationCoordinate2D(latitude: 52.52, longitude: 13.40))
        #expect(tz?.identifier == "Europe/Berlin")
    }

    @Test func mumbai() {
        let tz = TimezoneMapper.latLngToTimezone(CLLocationCoordinate2D(latitude: 19.08, longitude: 72.88))
        #expect(tz?.identifier == "Asia/Kolkata")
    }

    // MARK: - String variant

    @Test func stringVariantIsValidIdentifier() {
        let s = TimezoneMapper.latLngToTimezoneString(CLLocationCoordinate2D(latitude: 40.71, longitude: -74.01))
        #expect(!s.isEmpty)
        #expect(TimeZone(identifier: s) != nil)
    }

    // MARK: - Ocean (grid uses Etc/GMT± rather than "unknown")

    @Test func midPacificHasOceanTimezone() {
        let s = TimezoneMapper.latLngToTimezoneString(CLLocationCoordinate2D(latitude: 0, longitude: -160))
        #expect(s.hasPrefix("Etc/GMT"))
    }
}
