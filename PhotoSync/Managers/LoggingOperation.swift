//  Copyright 2020 Thomas Insam. All rights reserved.

import Foundation
import Photos
import SwiftyDropbox
import UIKit

protocol LoggingOperation {}

extension LoggingOperation {
//    func logError(error: String) {
//        DispatchQueue.main.async {
//            AppDelegate.shared.syncManager.logError(error: error)
//        }
//    }
//
//    func logError<T>(path: String, error: CallError<T>) {
//        switch error {
//        case .routeError(let boxed, _, _, _):
//            if let uploadError = boxed.unboxed as? Files.UploadError {
//                logError(error: "Failed to upload \(path): \(uploadError.description)")
//            } else if let deleteError = boxed.unboxed as? Files.DeleteError {
//                logError(error: "Failed to delete \(path): \(deleteError.description)")
//            } else {
//                logError(error: "Dropbox error: \(error.description)")
//            }
//        default:
//            logError(error: "Dropbox error: \(error.description)")
//        }
//    }
//
//    func logProgress() {
//        DispatchQueue.main.async {
//            AppDelegate.shared.syncManager.logProgress()
//        }
//    }
}
