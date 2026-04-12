import Photos
import SwiftUI
import SwiftyDropbox

@main
struct PhotoSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let syncCoordinator = SyncCoordinator(database: Database())

    @State private var errorMessage: String?

    init() {
        DropboxClientsManager.setupWithAppKey("ru820t3myp7s6vk")
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                StatusView(syncCoordinator: syncCoordinator)
            }
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
                UIApplication.shared.isIdleTimerDisabled = true
                requestPhotoPermission()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
            case .background:
                NSLog("Entering background, \(UIApplication.shared.backgroundTimeRemaining) remaining")
                UIApplication.shared.isIdleTimerDisabled = false
            default:
                break
            }
        }
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
