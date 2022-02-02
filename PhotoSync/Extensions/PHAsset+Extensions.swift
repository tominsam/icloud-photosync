//
//  PHAsset+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 5/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Photos

extension PHAsset {
    static var dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM"
        return dateFormatter
    }()

    /// The path in dropbox where we want this asset to be. This method is slow (multiple
    /// milliseconds) so exercise caution - don't call it on first sync.
    var dropboxPath: String {
        let datePath: String
        if let creationDate = creationDate {
            // Can we get a timezone from the photo location? Assume the photo was taken in that TZ
            if let location = location, let timezone = TimezoneMapper.latLngToTimezone(location.coordinate) {
                Self.dateFormatter.timeZone = timezone
            } else {
                // Otherwise we'll just have to assume UTC for safety
                Self.dateFormatter.timeZone = TimeZone(identifier: "UTC")
            }
            datePath = Self.dateFormatter.string(from: creationDate)
        } else {
            // no creation date?
            datePath = "No date"
        }

        // This includes the file extension.
        let filename = (PHAssetResource.assetResources(for: self)
            .first(where: { [.photo, .video, .fullSizePhoto, .fullSizeVideo].contains($0.type) })?
            .originalFilename)!
        return "/\(datePath)/\(filename)".lowercased()
    }
}
