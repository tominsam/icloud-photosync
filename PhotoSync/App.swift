import Photos
import SwiftUI
import SwiftyDropbox

@main
struct PhotoSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let syncCoordinator = SyncCoordinatorImpl(database: Database())

    @State private var errorMessage: String?

    init() {
        DropboxClientsManager.setupWithAppKey("ru820t3myp7s6vk")
        logTempDirectory()
        AssetData.cleanupTempDirectory()
    }

    private func logTempDirectory() {
        let tmp = FileManager.default.temporaryDirectory
        NSLog("%@", "Temp directory: \(tmp.path)")
        guard let enumerator = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else { return }
        var totalBytes = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += size
            NSLog("%@", "  \(url) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
        }
        NSLog("%@", "Temp total: \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))")
    }

    var body: some Scene {
        WindowGroup {
            StatusView(syncCoordinator: syncCoordinator)
            .tint(.green)
            .onOpenURL { url in
                // deep link back from the dropbox client for auth
                DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { authResult in
                    switch authResult {
                    case .success:
                        requestPhotoPermission()
                    case .cancel, .none:
                        break
                    case let .error(_, description):
                        errorMessage = description ?? "Unknown Dropbox error"
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                // Startup
                requestPhotoPermission()
            }
        }
//        .onChange(of: scenePhase) { _, newPhase in
//            switch newPhase {
//            case .active:
//                UIApplication.shared.isIdleTimerDisabled = true
//            case .background:
//                NSLog("Entering background, \(UIApplication.shared.backgroundTimeRemaining) remaining")
//                UIApplication.shared.isIdleTimerDisabled = false
//            default:
//                break
//            }
//        }
    }

    private func requestPhotoPermission() {
        switch PHPhotoLibrary.authorizationStatus() {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { _ in
                DispatchQueue.main.async { requestPhotoPermission() }
            }
        case .authorized, .limited:
            syncCoordinator.maybeSync()
        default:
            errorMessage = "Photo permission not granted"
        }
    }
}
