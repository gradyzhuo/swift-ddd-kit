//
//  ExitCode.swift
//
//
//  Created by Grady Zhuo on 2024/6/2.
//

import Foundation

public struct ExitCode {
    private(set) var name: String
    private(set) var code: Int

    private init(name: String, code: Int) {
        self.name = name
        self.code = code
    }

    public static var success: ExitCode = .init(name: "Success", code: 0)
    public static var failure: ExitCode = .init(name: "Failure", code: 1)
}
