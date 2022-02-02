//  Copyright 2020 Thomas Insam. All rights reserved.

import SwiftyDropbox
import UIKit

extension SwiftyDropbox.CallError: Error {}

extension SwiftyDropbox.UploadRequest {
    func asyncResponse() async throws -> RSerial.ValueType {
        return try await withCheckedThrowingContinuation { continuation in
            self.response(queue: nil) { result, error in
                if let result = result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: error!)
                }
            }
        }
    }
}

extension SwiftyDropbox.RpcRequest {
    func asyncResponse() async throws -> RSerial.ValueType {
        return try await withCheckedThrowingContinuation { continuation in
            self.response(queue: nil) { result, error in
                if let result = result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: error!)
                }
            }
        }
    }
}
