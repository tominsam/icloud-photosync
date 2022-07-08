//
//  Data+Extension.swift
//  PhotoSync
//
//  Created by Thomas Insam on 5/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import AVFoundation
import CryptoKit
import FileProvider
import Foundation

extension InputStream {
    private static func sha256(data: Data) -> Data {
        return Data(CryptoKit.SHA256.hash(data: data))
    }

    // Method: https://www.dropbox.com/developers/reference/content-hash
    // based on https://gist.github.com/crspybits/8a5c8df80fa9d5da955f338c4fef124f
    // This should be async, it's potentially reading hundreds of megs off disk,
    // but in practice it seems to be really really fast, so it's not a priority
    func dropboxContentHash() -> String {
        let blockSize = 1024 * 1024 * 4

        var inputBuffer = [UInt8](repeating: 0, count: blockSize)
        open()
        defer { close() }

        var concatenatedSHAs = Data()

        while true {
            let length = read(&inputBuffer, maxLength: blockSize)
            if length == 0 {
                // EOF
                break
            } else if length < 0 {
                assertionFailure()
            }

            let dataBlock = Data(bytes: inputBuffer, count: length)
            let sha = Self.sha256(data: dataBlock)
            concatenatedSHAs.append(sha)
        }

        let finalSHA = Self.sha256(data: concatenatedSHAs)
        let hexString = finalSHA.map { String(format: "%02hhx", $0) }.joined()

        return hexString
    }
}

extension Data {
    func dropboxContentHash() -> String {
        return InputStream(data: self).dropboxContentHash()
    }
}

extension URL {
    func dropboxContentHash() -> String {
        return InputStream(url: self)!.dropboxContentHash()
    }
}
