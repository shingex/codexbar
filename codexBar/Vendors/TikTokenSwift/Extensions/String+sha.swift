//
//  File.swift
//  
//
//  Created by Richard Perry on 9/6/24.
//

import Foundation
import CryptoKit

extension String {
    var sha256: String {
        let inputData = Data(self.utf8)
        let hashed = SHA256.hash(data: inputData)
        let hashString = hashed.compactMap { String(format: "%02x", $0) }.joined()
        return hashString
    }
}
