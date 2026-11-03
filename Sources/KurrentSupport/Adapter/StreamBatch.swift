//
//  StreamBatch.swift
//  KurrentSupport
//
//  Values exchanged by `EventStoreClient.appendAtomically(_:)`.
//

import KurrentDB

/// One stream's share of an atomic multi-stream append.
public struct StreamBatch: Sendable {
    public let stream: String
    /// Same meaning as `EventStoreClient.append`'s `category`; neither conformance routes by it.
    public let category: String
    public let expectedRevision: StreamRevision
    /// Non-empty (the caller's job).
    public let events: [EventData]

    public init(stream: String, category: String, expectedRevision: StreamRevision, events: [EventData]) {
        self.stream = stream
        self.category = category
        self.expectedRevision = expectedRevision
        self.events = events
    }
}

/// A stream's revision after an atomic multi-stream append: the revision of its last new event.
public struct StreamBatchResult: Sendable, Equatable {
    public let stream: String
    public let revision: UInt64

    public init(stream: String, revision: UInt64) {
        self.stream = stream
        self.revision = revision
    }
}

/// A stream whose expected revision did not hold in an atomic multi-stream append.
public struct StreamConflict: Sendable, Equatable {
    public let stream: String
    /// The batch's own expected revision.
    public let expected: StreamRevision
    /// The stream's revision when the append was checked; `nil` when the stream does not exist.
    public let current: UInt64?

    public init(stream: String, expected: StreamRevision, current: UInt64?) {
        self.stream = stream
        self.expected = expected
        self.current = current
    }

    // Written by hand: `StreamRevision` is not `Equatable`, and a retroactive conformance
    // would clash once swift-kurrentdb adds its own.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.stream == rhs.stream, lhs.current == rhs.current else { return false }
        switch (lhs.expected, rhs.expected) {
        case (.any, .any), (.noStream, .noStream), (.streamExists, .streamExists):
            return true
        case let (.at(lhsRevision), .at(rhsRevision)):
            return lhsRevision == rhsRevision
        // Listed case by case rather than `default`, so a new `StreamRevision` case
        // fails to compile here instead of comparing unequal to itself.
        case (.any, _), (.noStream, _), (.streamExists, _), (.at, _):
            return false
        }
    }
}
