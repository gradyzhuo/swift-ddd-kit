//
//  DDDError.swift
//
//
//  Created by Grady Zhuo on 2024/6/11.
//

import Foundation

public struct DDDError: Error {
    public let code: Code
    public let message: String
    public let userInfos: [String: Any]

    public init(code: Code, message: String, userInfos: [String: Any]) {
        self.code = code
        self.message = message
        self.userInfos = userInfos
    }
}

extension DDDError {
    public enum Code: Int {
        case undefined = 900
        case usecaseExecutionFailure = 101
        case aggregateNotFound = 201
        case aggregateOperationNotAllowed = 202
    }
}

// MARK: - Define errors with enum-like.

extension DDDError {
    public static func executeUsecaseFailed(usecase: any Usecase, input: any Input, userInfos: [String: Any]? = nil) -> Self {
        let errorCode = DDDError.Code.usecaseExecutionFailure
        let message = "[\(errorCode)] The error happened with executing usecase \(usecase) by input: \(input). "
        let useInfos = userInfos ?? [:]
        return .init(code: errorCode, message: message, userInfos: useInfos)
    }

    public static func aggregateNotFound(usecase: any Usecase, aggregateRootType: any AggregateRoot.Type, aggregateRootId: String) -> Self {
        aggregateNotFound(usecase: "\(usecase)", aggregateRootType: aggregateRootType, aggregateRootId: aggregateRootId)
    }
    
    public static func aggregateNotFound(usecase: String, aggregateRootType: any AggregateRoot.Type, aggregateRootId: String) -> Self {
        let errorCode = DDDError.Code.aggregateNotFound
        let message = "[\(errorCode)] The aggregateRoot (\(aggregateRootId)@\(aggregateRootType.self))  not found with executing usecase \(usecase)."
        return .init(code: errorCode, message: message, userInfos: [:])
    }
    
    public static func operationNotAllow(operation: String, reason: String, userInfos: [String: Any]? = nil) -> Self {
        let errorCode = DDDError.Code.aggregateOperationNotAllowed
        let message = "[\(errorCode)] `\(operation)` not allowed, because \(reason)."
        var userInfos = userInfos ?? [:]
        userInfos["operation"] = operation
        userInfos["reason"] = reason
        return .init(code: errorCode, message: message, userInfos: userInfos)
    }
}
