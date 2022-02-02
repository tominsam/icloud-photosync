//
//  PhotoCell.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Photos
import UIKit

class PhotoCell: UICollectionViewCell, Reusable {
    static var reuseIdentifier: String = "PhotoCell"

    var imageRequestId: PHImageRequestID?

    lazy var imageView = UIImageView().configured {
        $0.contentMode = .scaleAspectFill
        $0.backgroundColor = .secondarySystemGroupedBackground
        $0.clipsToBounds = true
        $0.tintColor = .label
    }

    lazy var iconView = UIImageView().configured {
        $0.tintColor = .white
        $0.layer.shadowColor = UIColor.black.cgColor
        $0.layer.shadowRadius = 8
        $0.layer.shadowOpacity = 0.7
    }

    lazy var errorImage: UIImage = {
        let config = UIImage.SymbolConfiguration(textStyle: .title1)
        return UIImage(systemName: "clear", withConfiguration: config)!
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubviewWithInsets(imageView)
        contentView.addSubviewWithConstraints(iconView, [
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            iconView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(photo: Photo) {
        if let id = imageRequestId {
            PHImageManager.default().cancelImageRequest(id)
        }

        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.photoKitId], options: nil).firstObject

        let config = UIImage.SymbolConfiguration(scale: .small)
        if asset == nil {
            iconView.image = UIImage(systemName: "trash.fill", withConfiguration: config)
        } else if asset?.isFavorite == true {
            iconView.image = UIImage(systemName: "heart.fill", withConfiguration: config)
        } else {
            iconView.image = nil
        }

        if let asset = asset {
            imageRequestId = PHImageManager.default().requestImage(for: asset, targetSize: contentView.frame.size, contentMode: .aspectFill, options: nil) { image, _ in
                self.imageView.image = image
            }
        } else {
            imageView.image = nil
            imageRequestId = nil
        }
    }
}
