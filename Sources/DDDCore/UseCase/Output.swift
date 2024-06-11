//
//  Output.swift
//
//
//  Created by Grady Zhuo on 2024/6/2.
//

import Foundation

public protocol Output: Sendable, Codable {
    var id: String? { get }
    var message: String? { get }
}
