// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import Photos

// Protocol allows mocking for tests
protocol PhotoProtocol {
    var photoKitId: String! { get }
    var cloudIdentifier: String? { get }
    var created: Date? { get }
    var preferredPath: String? { get }
    var contentHash: String? { get }
}

/// Core data object representing a photo from PhotoKit. These are very cheap to fetch from
/// the system - the DB object is here because some photo properties are _very_ expensive
/// (for example the contentHash property requires us to download the original binary asset)
/// so this table represents the most valuable data the app holds.
@objc(Photo)
class Photo: NSManagedObject, ManagedObject, PhotoProtocol {
    static var defaultSortDescriptors = [
        NSSortDescriptor(key: "created", ascending: false),
        NSSortDescriptor(key: "photoKitId", ascending: true)
    ]

    // Properties from photokit
    @NSManaged var cloudIdentifier: String?
    @NSManaged var photoKitId: String!
    @NSManaged var created: Date?
    @NSManaged var modified: Date?

    // The filename of the image in PhotoKit. Slightly expensive to calculate
    // (because we need to fetch all representations of the photo) so we
    // cache it.
    @NSManaged var filename: String?

    // The path we want the image to have on disk. Derived from photokit data
    // Doesn't need the original version to be downloaded to achieve this, but
    // is a little more expensive to calculate than filename, so we cache it.
    @NSManaged var preferredPath: String?

    // The dropbox contenthash of the image. Optional because we need the
    // image data to calculate this, so I'll only set it when I
    // have read the image.
    @NSManaged var contentHash: String?
}

extension Photo {
    /// Inset a batch of PHAssets into the database, including calculating their filenames. If the
    /// assets already exist we won't re-calculate the filename if the image is unchanged, so it's
    /// much cheaper to call a second time.
    @discardableResult
    static func insertOrUpdate(_ assets: [PHAssetProtocol], into context: NSManagedObjectContext) throws -> ([Photo], Bool) {
        guard !assets.isEmpty else { return ([], false) }

        let localIds: [String] = assets.map { $0.localIdentifier }
        // dict of photo ID -> photo of existing DB objects
        let existing = try Photo.matching(
            "photoKitId IN (%@)",
            args: [localIds],
            in: context
        ).uniqueBy(\.photoKitId)

        // Fetch the cloud IDs for photos where we need that (photoKitID can vary between
        // device so it's no good for deterministic sorting)
        let missingCloudkitIds: [String] = existing.keys.filter { existing[$0]?.cloudIdentifier == nil }.compactMap(\.self)
        let cloudIds: [String: Result<PHCloudIdentifier, any Error>]
        if missingCloudkitIds.isEmpty {
            cloudIds = [:]
        } else {
            NSLog("%@", "Need to load cloudkit IDs for \(missingCloudkitIds)")
            cloudIds = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: missingCloudkitIds)
        }

        var changed = false
        let photos = assets.map { asset in
            let photo = existing[asset.localIdentifier] ?? context.insertObject()
            if photo.update(from: asset) {
                changed = true
            }
            if photo.cloudIdentifier == nil {
                guard case .success(let cloudId) = cloudIds[asset.localIdentifier] else {
                    fatalError()
                }
                photo.cloudIdentifier = cloudId.stringValue
                changed = true
            }
            return photo
        }
        return (photos, changed)
    }

    static func forLocalIdentifier(_ localIdentifier: String, in context: NSManagedObjectContext) throws -> Photo? {
        return try Photo.matching("photoKitId = %@", args: [localIdentifier], in: context).first
    }

    struct PhotoMapping {
        let photoKitId: String
        let path: String
        let contentHash: String?
    }

    /// Returns an array containing every photo in the database, along with the _unique_
    /// path into the destination that we want that photo to have. Photo filenames are
    /// in folders by month, and take the filename from Photos.app, but filenames in there
    /// are not guaranteed to be unique (especially for imports) so collisions will happen.
    /// This method will generate stable and unique filenames for a set of photos - duplicate filenames
    /// in a single folder will have "(1)", etc appended after them.
    ///
    /// If the user deletes one of of a pair of files with the same name,
    /// I want to restore the original name to whichever is left - that means
    /// that the path generation code needs to be safe, and return the same
    /// result when called repeatedly on the same data set, but also generate
    /// new data when called on a new dataset. (And be consistent cross-platform)
    /// That's done by having every Photo have a cached "this is the path that
    /// I want" that is expensive to calculate, then on parse we loop through
    /// the photos in a _consistent order_ and generate the actual output paths.
    /// This should be deterministic when you leave both files in place.
    static func allPhotosWithUniqueFilenames(in context: NSManagedObjectContext) throws -> [PhotoMapping] {
        let allPhotos = try Photo.matching(nil, in: context)
        return uniqueFilenames(from: allPhotos)
    }

    /// Pure deduplication logic, separated from CoreData for testability.
    static func uniqueFilenames(from photos: [PhotoProtocol]) -> [PhotoMapping] {
        let sorted = photos.filter { $0.preferredPath != nil }.sorted { lhs, rhs in
            // The output order of this function _must_ be deterministic! I have to
            // round the dates because different OS versions will return non-zero
            // nanoseconds, but the files we write have integer mtimes.
            if let lc = lhs.created?.integral(), let rc = rhs.created?.integral(), lc != rc { return lc < rc }
            //if let lm = lhs.modified?.integral(), let rm = rhs.modified?.integral(), lm != rm { return lm < rm }
            if let li = lhs.cloudIdentifier, let ri = rhs.cloudIdentifier, li != ri { return li < ri }
            return lhs.photoKitId < rhs.photoKitId
        }
        var assigned = Set<String>()
        return sorted.map { photo in
            // Photos makes no attempt to keep filenames unique. Keep appending a number to the
            // filename until we get something unique. Remember that file systems are
            // often not case sensitive!
            var path = photo.preferredPath!
            while assigned.contains(path.lowercased()) {
                path = path.incrementFilenameMagicNumber()
            }
            assigned.insert(path.lowercased())
            return PhotoMapping(photoKitId: photo.photoKitId, path: path, contentHash: photo.contentHash)
        }
    }

    private func update(from asset: PHAssetProtocol) -> Bool {
        var changed = false

        if photoKitId != asset.localIdentifier || created != asset.creationDate {
            photoKitId = asset.localIdentifier
            created = asset.creationDate
            changed = true
        }

        if modified == nil || asset.modificationDate == nil || abs(modified!.timeIntervalSinceReferenceDate - asset.modificationDate!.timeIntervalSinceReferenceDate) > 20 {
            // if the file has been changed, invalidate the content hash
            // and the path (because you can change the date on photos, and
            // even though we're exporting the original, the destination path
            // will use the edited date)
            filename = nil
            contentHash = nil
            preferredPath = nil
            cloudIdentifier = nil
            modified = asset.modificationDate
            changed = true
        }

        if filename == nil {
            filename = asset.filename? // slow!
                .stripFilenameMagicNumber()
            changed = true
        }

        // We're storing a path for the image in core data rather than deriving it every time, because
        // (a) it's slow to derive (because fetching the file type is expensive) and (b) we want it to be
        // consistent for every run of the app.
        if let filename = filename, preferredPath == nil {
            preferredPath = asset.dropboxPath(fromFilename: filename)
            changed = true
        }
        return changed
    }
}

extension String {
    static let trailingDigit = try! NSRegularExpression(pattern: #"^(.*)\s\((\d+)\)$"#, options: [])

    func stripFilenameMagicNumber() -> String {
        // Cut the filename into a path, the filename without extension, and the extension
        let prefix = (self as NSString).deletingLastPathComponent
        var filename = ((self as NSString).deletingPathExtension as NSString).lastPathComponent
        let pathExtension = (self as NSString).pathExtension

        // Look for an existing " (1)" at the end of the filename and extract it if present
        if let match = Self.trailingDigit.firstMatch(in: filename, options: [], range: NSRange(filename.startIndex ..< filename.endIndex, in: filename)) {
            let filenameRange = Range(match.range(at: 1), in: filename)!
            filename = String(filename[filenameRange])
        }

        // Glue the path back together
        return ((prefix as NSString).appendingPathComponent(filename) as NSString).appendingPathExtension(pathExtension.lowercased())!
    }

    func incrementFilenameMagicNumber() -> String {
        // Cut the filename into a path, the filename without extension, and the extension
        let prefix = (self as NSString).deletingLastPathComponent
        var filename = ((self as NSString).deletingPathExtension as NSString).lastPathComponent
        let pathExtension = (self as NSString).pathExtension

        // Look for an existing " (1)" at the end of the filename and extract it if present
        let index: Int
        if let match = Self.trailingDigit.firstMatch(in: filename, options: [], range: NSRange(filename.startIndex ..< filename.endIndex, in: filename)) {
            let filenameRange = Range(match.range(at: 1), in: filename)!
            let indexRange = Range(match.range(at: 2), in: filename)!
            index = Int(String(filename[indexRange]))!
            filename = String(filename[filenameRange])
        } else {
            index = 0
        }

        // We're going to append a number onto the filename now. It'll be one more than the
        // previous number if there was already a number on the filename, otherwise it'll be "1"
        let suffix = " (\(index + 1))"

        // Glue the path back together
        return ((prefix as NSString).appendingPathComponent(filename + suffix) as NSString).appendingPathExtension(pathExtension.lowercased())!
    }
}

extension Date {
    func integral() -> Date {
        let cal = Calendar.current
        return cal.date(bySetting: .nanosecond, value: 0, of: self) ?? self
    }
}
