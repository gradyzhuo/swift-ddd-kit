import DDDCore
import EventSourcing
import Foundation

/// Metadata every contract store is instantiated with.
public struct ContractMetadata: EventMetadata, Equatable {
    public let tag: String

    public init(tag: String) {
        self.tag = tag
    }
}

/// The event `ContractEventMapper` maps. `metadata` is filled on read from
/// `customMetadata`, the way the generated mappers do it.
public struct ContractEvent: DomainEvent {
    public typealias Metadata = ContractMetadata

    public var id: UUID
    public var occurred: Date
    public var aggregateRootId: String
    public var metadata: ContractMetadata?
    public var value: Int

    public init(id: UUID = UUID(), aggregateRootId: String, value: Int, occurred: Date = .now) {
        self.id = id
        self.occurred = occurred
        self.aggregateRootId = aggregateRootId
        self.metadata = nil
        self.value = value
    }
}

/// An event type `ContractEventMapper` does not know: the mapper returns `nil`.
public struct ContractUnmappedEvent: DomainEvent {
    public typealias Metadata = Never

    public var id: UUID
    public var occurred: Date
    public var aggregateRootId: String
    public var metadata: Never?

    public init(id: UUID = UUID(), aggregateRootId: String, occurred: Date = .now) {
        self.id = id
        self.occurred = occurred
        self.aggregateRootId = aggregateRootId
        self.metadata = nil
    }
}

/// An event type `ContractEventMapper` throws on.
public struct ContractUndecodableEvent: DomainEvent {
    public typealias Metadata = Never

    public var id: UUID
    public var occurred: Date
    public var aggregateRootId: String
    public var metadata: Never?

    public init(id: UUID = UUID(), aggregateRootId: String, occurred: Date = .now) {
        self.id = id
        self.occurred = occurred
        self.aggregateRootId = aggregateRootId
        self.metadata = nil
    }
}

/// Stream naming for stores that need one (`ContractStream-<id>`).
public enum ContractStream: EventStreamNaming {
    public static var categoryRule: StreamCategoryRule { .custom("ContractStream") }
    public static var category: String { "ContractStream" }
}

/// Maps `ContractEvent`, returns `nil` for unknown types, throws for
/// `ContractUndecodableEvent`.
public struct ContractEventMapper: EventTypeMapper {
    public struct UndecodableEvent: Error {}

    public init() {}

    public func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "ContractEvent":
            guard var event = try eventData.decode(to: ContractEvent.self) else { return nil }
            event.metadata = eventData.customMetadata.isEmpty
                ? nil
                : try JSONDecoder().decode(ContractMetadata.self, from: eventData.customMetadata)
            return event
        case "ContractUndecodableEvent":
            throw UndecodableEvent()
        default:
            return nil
        }
    }
}
