// Copyright 2026 Thomas Insam. All rights reserved.

import Photos
import SwiftUI
import UIKit

struct ThumbnailView: View {
    let asset: PHAssetProtocol
    var size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: asset.localIdentifier) {
            image = await asset.thumbnail(size: CGSize(width: 100, height: 100))
        }
    }
}
