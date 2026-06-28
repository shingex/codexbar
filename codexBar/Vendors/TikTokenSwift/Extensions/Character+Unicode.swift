//
//  Character+Unicode.swift
//
//
//  Created by Richard Perry on 9/6/24.
//

import Foundation

extension Character {
    init?(unicodeValue: Int) {
        guard let unicodeScalar = Unicode.Scalar(unicodeValue) else {
            return nil
        }
        self.init(unicodeScalar)
    }
}
