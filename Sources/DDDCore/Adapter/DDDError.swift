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
    public let userInfos: [String: Sendable]

    public init(code: Code, message: String, userInfos: [String:Sendable]) {
        self.code = code
        self.message = message
        self.userInfos = userInfos
    }
}

extension DDDError {
    public enum Code: Int, Sendable {
        case undefined = 900
        case usecaseExecutionFailure = 101
        case aggregateNotFound = 201
        case projectorConstructionFailed = 301
        case aggregateOperationNotAllowed = 202
        case eventsNotFound = 401
        case commitConflict = 501
        case streamPurged = 502
        case storeUnavailable = 503
        case storeCorrupted = 504
    }
}

extension DDDError.Code {
    @available(*, deprecated, renamed: "projectorConstructionFailed")
    public static var presenterConstructionFailed: Self { .projectorConstructionFailed }
}

// MARK: - Define errors with enum-like.

extension DDDError {
    public static func executeUsecaseFailed(usecase: any Usecase, input: any UseCaseInput, userInfos: [String: Sendable]? = nil) -> Self {
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
    
    public static func operationNotAllow(operation: String, reason: String, userInfos: [String: Sendable]? = nil) -> Self {
        let errorCode = DDDError.Code.aggregateOperationNotAllowed
        let message = "[\(errorCode)] `\(operation)` not allowed, because \(reason)."
        var userInfos = userInfos ?? [:]
        userInfos["operation"] = operation
        userInfos["reason"] = reason
        return .init(code: errorCode, message: message, userInfos: userInfos)
    }
    
    public static func eventsNotFoundInProjector(operation: String, projectorType: String, userInfos: [String: Sendable]? = nil) -> Self {
        let errorCode = DDDError.Code.eventsNotFound
        let reason = "events not found to build readModel in projector \(projectorType)"
        let message = "[\(errorCode)] `\(operation)` not allowed, because \(reason)."
        var userInfos = userInfos ?? [:]
        userInfos["operation"] = operation
        userInfos["reason"] = reason
        return .init(code: errorCode, message: message, userInfos: userInfos)
    }

    @available(*, deprecated, renamed: "eventsNotFoundInProjector(operation:projectorType:userInfos:)")
    public static func eventsNotFoundInPresenter(operation: String, presenterType: String, userInfos: [String: Sendable]? = nil) -> Self {
        eventsNotFoundInProjector(operation: operation, projectorType: presenterType, userInfos: userInfos)
    }

    public static func projectorOperationFailed(projectorType: String, id: String, reason: String, userInfos: [String: Sendable]? = nil) -> Self {
        let errorCode = DDDError.Code.projectorConstructionFailed
        let message = "[\(errorCode)] It's failed in \(projectorType):\(id), because \(reason)."
        var userInfos = userInfos ?? [:]
        userInfos["reason"] = reason
        return .init(code: errorCode, message: message, userInfos: userInfos)
    }

    @available(*, deprecated, renamed: "projectorOperationFailed(projectorType:id:reason:userInfos:)")
    public static func presenterOperationFailed(presenterType: String, id: String, reason: String, userInfos: [String: Sendable]? = nil) -> Self {
        projectorOperationFailed(projectorType: presenterType, id: id, reason: reason, userInfos: userInfos)
    }
}

// MARK: - EventStore errors

extension DDDError {
    /// Payload of a `commitConflict` error: the stream's tail revision did not
    /// match what the caller expected. `nil` means "no stream".
    ///
    /// Diagnostic only — do not show it to end users verbatim.
    public struct CommitConflict: Sendable, Equatable {
        public let id: String
        public let expected: UInt64?
        public let actual: UInt64?

        public init(id: String, expected: UInt64?, actual: UInt64?) {
            self.id = id
            self.expected = expected
            self.actual = actual
        }
    }

    /// `EventStore.append` found the stream somewhere other than `expected`.
    /// Nothing was written.
    public static func commitConflict(id: String, expected: UInt64?, actual: UInt64?) -> Self {
        let errorCode = DDDError.Code.commitConflict
        let conflict = CommitConflict(id: id, expected: expected, actual: actual)
        let expectedText = expected.map { "\($0)" } ?? "no stream"
        let actualText = actual.map { "\($0)" } ?? "no stream"
        let message = "[\(errorCode)] Append to \(id) expected \(expectedText) but found \(actualText)."
        return .init(code: errorCode, message: message, userInfos: ["commitConflict": conflict])
    }

    /// The conflict details when `code == .commitConflict`, otherwise `nil`.
    public var commitConflict: CommitConflict? {
        guard code == .commitConflict else { return nil }
        return userInfos["commitConflict"] as? CommitConflict
    }

    /// `EventStore.append` targeted an id that was purged. Nothing was written,
    /// and the id can never be written again.
    public static func streamPurged(id: String) -> Self {
        let errorCode = DDDError.Code.streamPurged
        let message = "[\(errorCode)] \(id) was purged and cannot be written again."
        return .init(code: errorCode, message: message, userInfos: ["id": id])
    }

    /// Why a store could not serve a request (`code == .storeUnavailable`).
    public enum StoreUnavailableReason: String, Sendable, Equatable {
        /// The location the store was opened on cannot be used (file store: not a
        /// file URL, or a regular file where a directory is expected).
        case invalidLocation
        /// The stream name is longer than the store can represent (file store: more
        /// than 120 UTF-8 bytes, the most its file names allow).
        case streamNameTooLong
        /// Reading from or writing to the backing storage failed. Nothing was written.
        case io
        /// Another open store instance holds the location.
        case occupied
        /// The store was closed.
        case closed
    }

    /// The store could not serve the request. Nothing was written.
    ///
    /// - Parameters:
    ///   - reason: Why the store could not serve the request.
    ///   - path: The location or file involved (file store: its directory or a
    ///     stream's file), except for `.streamNameTooLong`, where it holds the
    ///     stream name.
    ///   - detail: Free-form diagnostic text. Do not parse it, and do not show it to
    ///     end users verbatim.
    public static func storeUnavailable(reason: StoreUnavailableReason, path: String, detail: String? = nil) -> Self {
        let errorCode = DDDError.Code.storeUnavailable
        var message = "[\(errorCode)] \(reason.rawValue): \(path)"
        var userInfos: [String: Sendable] = ["reason": reason, "path": path]
        if let detail {
            message += " (\(detail))"
            userInfos["detail"] = detail
        }
        return .init(code: errorCode, message: message, userInfos: userInfos)
    }

    /// The reason when `code == .storeUnavailable`, otherwise `nil`.
    public var storeUnavailableReason: StoreUnavailableReason? {
        guard code == .storeUnavailable else { return nil }
        return userInfos["reason"] as? StoreUnavailableReason
    }

    /// The stored data of `stream` cannot be read. Other streams are unaffected.
    /// (File store: its file does not decode, has an unknown format version or names
    /// another stream.)
    ///
    /// `purge` discards that stream's events and leaves the id unwritable; it does
    /// not repair the data.
    public static func storeCorrupted(stream: String) -> Self {
        let errorCode = DDDError.Code.storeCorrupted
        let message = "[\(errorCode)] The stored data of \(stream) cannot be read."
        return .init(code: errorCode, message: message, userInfos: ["stream": stream])
    }

    /// The stream name when `code == .storeCorrupted`, otherwise `nil`.
    public var corruptedStream: String? {
        guard code == .storeCorrupted else { return nil }
        return userInfos["stream"] as? String
    }
}
