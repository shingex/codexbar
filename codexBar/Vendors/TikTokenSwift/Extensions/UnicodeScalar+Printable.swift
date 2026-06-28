//
//  UnicodeScalar+Printable.swift
//
//
//  Created by Richard Perry on 9/5/24.
//

import Foundation

extension Unicode.Scalar {
    var pythonIsPrintable: Bool {
        switch properties.generalCategory {
        case .control, .format: 
            return false
        default: 
            return true
        }
    }
}
