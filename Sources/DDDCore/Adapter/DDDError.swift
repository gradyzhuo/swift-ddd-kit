//
//  DDDError.swift
//
//
//  Created by Grady Zhuo on 2024/6/11.
//

import Foundation

public struct DDDError: Error {
    public let code: Int
    public let message: String
    public let userInfos: [String: Any]

    public init(code: Int, message: String, userInfos: [String: Any]) {
        self.code = code
        self.message = message
        self.userInfos = userInfos
    }
}

extension DDDError {
    public static let USECASE_EXECUTION_FAILURE_CODE = 1
    public static let USECASE_AGGREGATE_NOT_FOUND_CODE = 2
}

// MARK: - Define errors with enum-like.

extension DDDError {
    public static func executeUsecaseFailed(usecase: any Usecase, input: any Input, userInfos: [String: Any]? = nil) -> Self {
        let errorCode = DDDError.USECASE_EXECUTION_FAILURE_CODE
        let message = "[\(errorCode)] The error happened with executing usecase \(usecase) by input: \(input). "
        let useInfos = userInfos ?? [:]
        return .init(code: errorCode, message: message, userInfos: useInfos)
    }

    public static func aggregateNotFound(usecase: any Usecase, aggregateRootType: any AggregateRoot.Type, aggregateRootId: String) -> Self {
        let errorCode = DDDError.USECASE_AGGREGATE_NOT_FOUND_CODE
        let message = "[\(errorCode)] The aggregateRoot (\(aggregateRootId)@\(aggregateRootType.self))  not found with executing usecase \(usecase)."
        return .init(code: errorCode, message: message, userInfos: [:])
    }
    
    public static func operationNotAllow(operation: String, reason: String, userInfos: [String: Any]? = nil) -> Self {
        let errorCode = DDDError.USECASE_AGGREGATE_NOT_FOUND_CODE
        let message = "[\(errorCode)] `\(operation)` not allowed, because \(reason)."
        var userInfos = userInfos ?? [:]
        userInfos["operation"] = operation
        userInfos["reason"] = reason
        return .init(code: errorCode, message: message, userInfos: userInfos)
    }
}
