//  Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import Photos

@objc(Photo)
public class Photo: NSManagedObject, ManagedObject {
    public static var defaultSortDescriptors = [
        NSSortDescriptor(key: "created", ascending: false),
        NSSortDescriptor(key: "photoKitId", ascending: true)
    ]

    // Properties from photokit
    @NSManaged public var photoKitId: String!
    @NSManaged public var created: Date?
    @NSManaged public var modified: Date?

    // The filename of the image in PhotoKit. Expensive to calculate (because we
    // need to fetch all representations of the photo)
    @NSManaged public var filename: String!

    // The path we want the image to have on disk. Derived from photokit data
    // Doesn't need the original version to be downloaded to achieve this, but
    // is a little expensive
    @NSManaged public var preferredPath: String!

    // The path we expect the file to have on disk - this is de-duplicated based
    // on if there's an existing file at the current path
    @NSManaged public var path: String!

    // The dropbox contenthash of the image. nil becaue we need the
    // image data to calculate this, so I'll only set it when I
    // have read the image.
    @NSManaged public var contentHash: String?
}

public extension Photo {
    @discardableResult
    static func insertOrUpdate(_ assets: [PHAsset], into context: NSManagedObjectContext) async throws -> [Photo] {
        guard !assets.isEmpty else { return [] }
        let existing = try await Photo.matching("photoKitId IN (%@)", args: [assets.map { $0.localIdentifier }], in: context).uniqueBy(\.photoKitId)
        return assets.map { asset in
            let photo = existing[asset.localIdentifier] ?? context.performAndWait { context.insertObject() }
            photo.update(from: asset)
            return photo
        }
    }

    static func forAsset(_ asset: PHAsset, in context: NSManagedObjectContext) async throws -> Photo? {
        return try await Photo.matching("photoKitId = %@", args: [asset.localIdentifier], in: context).first
    }

    static func generateUniqueFilenames(in context: NSManagedObjectContext) async throws {
        let request = NSBatchUpdateRequest(entity: entity())
        request.predicate = NSPredicate(format: "1=1")
        request.propertiesToUpdate = ["path": NSNull()]
        try context.execute(request)

        var allAssignedPaths = Set<String>()
        let allPhotos: [Photo] = try await Photo.matching(nil, in: context)
            .filter { $0.preferredPath != nil }
            .sorted { (lhs, rhs) -> Bool in
                if let ld = lhs.created, let rd = rhs.created, ld != rd {
                    return ld < rd
                }
                return lhs.photoKitId < rhs.photoKitId
            }

        for photo in allPhotos {
            // Are there any existing photos with this exact path? Can happen, Photos
            // makes no attempt to keep filenames unique. Keep appending a number to the
            // filename until we get something unique. Remember that files systems are
            // often not case sensitive!
            // TODO extract this from the inner loop because it's the slowest part of startup now
            var path = photo.preferredPath!
            while allAssignedPaths.contains(path) {
                let newPath = path.incrementFilenameMagicNumber()
                NSLog("%@", "Generating new version of \(path) -> \(newPath)")
                path = newPath
            }
            allAssignedPaths.insert(path)
            photo.path = path
        }
        try await context.performSave(andReset: true)
    }

    private func update(from asset: PHAsset) {
        photoKitId = asset.localIdentifier
        created = asset.creationDate
        if modified != asset.modificationDate {
            // if the file has been changed, invalidate the content hash
            contentHash = nil
            // and the path (because you can change the date on photos)
            path = nil
            modified = asset.modificationDate
        }

        if filename == nil {
            filename = asset.filename ?? "DUMMY" // slow!
        }

        // We're storing a path for the image in core data rather than deriving it every time, because
        // (a) it's slow to derive (because fetching the file type is expensive) and (b) we want it to be
        // consistent for every run of the app.
        if preferredPath == nil {
            preferredPath = asset.dropboxPath(fromFilename: filename)
        }

    }
}

extension String {
    static let trailingDigit = try! NSRegularExpression(pattern: #"^(.*)\s\((\d+)\)$"#, options: [])

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
        return ((prefix as NSString).appendingPathComponent(filename + suffix) as NSString).appendingPathExtension(pathExtension)!
    }
}
