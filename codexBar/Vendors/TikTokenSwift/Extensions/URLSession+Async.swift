//
//  URLSession+Async.swift
//
//
//  Created by Richard Perry on 9/6/24.
//

import Foundation

extension URLSession {
    func asyncData(from: URL) async throws -> (Data, URLResponse) {
        if #available(iOS 15.0, *) {
            try await self.data(from: from)
        } else {
            try await withCheckedThrowingContinuation { continuation in
                let sess = URLSession.shared
                let req = URLRequest(url: from)
                let task = sess.dataTask(with: req) { data, resp, err in
                    if let error = err {
                        continuation.resume(throwing: error)
                    } else if let dat = data, let response = resp {
                        continuation.resume(returning: (dat, response))
                    }
                }
                task.resume()
            }
        }
    }
}
