// Copyright 2026 Thomas Insam. All rights reserved.

import Testing
@testable import PhotoSync

struct FilenameTests {

    // MARK: - stripFilenameMagicNumber

    @Test func stripLeavesPlainFilenameAlone() {
        #expect("photo.jpg".stripFilenameMagicNumber() == "photo.jpg")
    }

    @Test func stripRemovesTrailingNumber() {
        #expect("photo (1).jpg".stripFilenameMagicNumber() == "photo.jpg")
        #expect("photo (42).jpg".stripFilenameMagicNumber() == "photo.jpg")
    }

    @Test func stripLowercasesExtension() {
        #expect("photo.JPG".stripFilenameMagicNumber() == "photo.jpg")
        #expect("photo (1).JPG".stripFilenameMagicNumber() == "photo.jpg")
    }

    @Test func stripPreservesPath() {
        #expect("2024/01/photo (1).jpg".stripFilenameMagicNumber() == "2024/01/photo.jpg")
    }

    @Test func stripOnlyStripsOneLevel() {
        // "(1)" embedded in the base name (no space before paren) is left alone
        #expect("my(1)photo.jpg".stripFilenameMagicNumber() == "my(1)photo.jpg")
    }

    // MARK: - incrementFilenameMagicNumber

    @Test func incrementAddsOneToPlainFilename() {
        #expect("photo.jpg".incrementFilenameMagicNumber() == "photo (1).jpg")
    }

    @Test func incrementBumpsExistingNumber() {
        #expect("photo (1).jpg".incrementFilenameMagicNumber() == "photo (2).jpg")
        #expect("photo (9).jpg".incrementFilenameMagicNumber() == "photo (10).jpg")
    }

    @Test func incrementLowercasesExtension() {
        #expect("photo.JPG".incrementFilenameMagicNumber() == "photo (1).jpg")
    }

    @Test func incrementPreservesPath() {
        #expect("2024/01/photo.jpg".incrementFilenameMagicNumber() == "2024/01/photo (1).jpg")
    }

    // MARK: - round-trip

    @Test func stripInvertsIncrement() {
        let original = "photo.jpg"
        #expect(original.incrementFilenameMagicNumber().stripFilenameMagicNumber() == original)
        #expect(original.incrementFilenameMagicNumber().incrementFilenameMagicNumber().stripFilenameMagicNumber() == original)
    }
}
