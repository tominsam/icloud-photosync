//  Copyright 2020 Thomas Insam. All rights reserved.

import SwiftyDropbox
import UIKit


extension SwiftyDropbox.UploadRequest {
    enum UploadError: Error {
        case api(CallError<ESerial.ValueType>)

        var localizedDescription: String {
            switch self {
            case .api(let error):
                error.description
            }
        }
    }

    func asyncResponse() async throws -> RSerial.ValueType {
        return try await withCheckedThrowingContinuation { continuation in
            self.response(queue: nil) { result, error in
                if let result = result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: UploadError.api(error!))
                }
            }
        }
    }
}

extension SwiftyDropbox.RpcRequest {
    enum RpcError: Error {
        case api(CallError<ESerial.ValueType>)

        var localizedDescription: String {
            switch self {
            case .api(let error):
                error.description
            }
        }
    }

    func asyncResponse() async throws -> RSerial.ValueType {
        return try await withCheckedThrowingContinuation { continuation in
            self.response(queue: nil) { result, error in
                if let result = result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: RpcError.api(error!))
                }
            }
        }
    }
}
