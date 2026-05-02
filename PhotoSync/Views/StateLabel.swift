import SwiftUI
import Photos

struct StateLabel: View {
    let leading: String
    let state: TaskProgress

    @State private var thumbnailSize: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(leading).bold()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(state.stringState)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding([.leading, .trailing])
            .padding([.top, .bottom], 15)
            .fixedSize(horizontal: false, vertical: true)
            
            if let assets = state.assets {
                HStack(spacing: 4) {
                    ForEach(assets.prefix(10), id: \.localIdentifier) { asset in
                        ThumbnailView(asset: asset, size: thumbnailSize)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(
                    for: CGFloat.self,
                    of: { $0.size.width },
                    action: { width in
                        thumbnailSize = itemSize(for: width)
                    }
                )
            }
        }
        .background {
            // background is a progress bar that fills up behind the label
            GeometryReader { metrics in
                if let progress = state.progressPercent {
                    let round = progress < 1 ? 4.0 : 0
                    Color.green
                        .opacity(state.opacity)
                        .frame(width: metrics.size.width * progress)
                        .clipShape(UnevenRoundedRectangle(
                            cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: round, topTrailing: round)))
                        .animation(.easeOut, value: progress)
                }
            }
        }
    }
    
}

// MARK: PREVIEWS

private func itemSize(for width: CGFloat, count: CGFloat = 10, spacing: CGFloat = 4, padding: CGFloat = 32) -> CGFloat {
    (width - padding - spacing * (count - 1)) / count
}

private extension TaskProgress {
    var stringState: String {
        if complete {
            if let total, total >= 0 {
                return "Complete • \(format(total))"
            } else {
                return "Complete"
            }
        } else if let total {
            return "\(format(progress)) / \(format(total))"
        } else {
            return "\(format(progress)) / …"
        }
    }

    func format(_ value: Int) -> String {
        switch unit {
        case .count:
            return "\(value)"
        case .bytes:
            return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
        }
    }
    
    var progressPercent: Double? {
        if complete {
            return 1
        }
        if total == 0 || total == nil {
            return nil
        }
        return max(Double(progress) / Double(total ?? 1), 0)
    }
    
    var opacity: Double {
        guard let total else { return 0 }
        if total < 0 {
            return 0.2
        } else if complete {
            return 0.12
        } else {
            return 0.2
        }
    }
}

#Preview {
    VStack(spacing: 2) {
        StateLabel(leading: "Fetching", state: mockTask(progress: 5))
        StateLabel(leading: "Uploading", state: mockTask(progress: 1))
        StateLabel(leading: "Uploading", state: mockTask(progress: 3))
        StateLabel(leading: "Uploading", state: mockTask(progress: 8, withAssets: true))
        StateLabel(leading: "Complete", state: mockTask(progress: 10))
    }
}
