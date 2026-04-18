// Copyright 2026 Thomas Insam. All rights reserved.

import Photos
import SwiftUI
import UIKit

struct ThumbnailView: View {
    let asset: PHAssetProtocol

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
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task {
            image = await asset.thumbnail(size: CGSize(width: 180, height: 180))
        }
    }
}
