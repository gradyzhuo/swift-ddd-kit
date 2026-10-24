// Fixture for Tests/ProjectorGeneratorFixtureTests — exercises the projector
// protocol the ModelGeneratorPlugin generates from projection-model.yaml.
import Foundation
import DDDCore
import EventSourcing
import KurrentSupport

public struct OrderSummary: ReadModel, Codable, Sendable {
    public let id: String
    public var customerId: String = ""
    public var totalAmount: Double = 0

    public init(id: String) { self.id = id }
}

public struct OrderSummaryInput: CQRSProjectorInput {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct OrderSummaryProjector: OrderSummaryProjectorProtocol {
    public typealias ReadModelType = OrderSummary
    public typealias Input = OrderSummaryInput
    public typealias Store = InMemoryEventStore<CustomMetadata>

    public static var categoryRule: StreamCategoryRule { .custom("Order") }

    public let store: InMemoryEventStore<CustomMetadata>

    public init(store: InMemoryEventStore<CustomMetadata>) { self.store = store }

    public func buildReadModel(input: Input) throws -> OrderSummary? { OrderSummary(id: input.id) }

    public func when(readModel: inout OrderSummary, event: OrderCreated) throws {
        readModel.customerId = event.customerId
        readModel.totalAmount = event.totalAmount
    }

    public func when(readModel: inout OrderSummary, event: OrderAmountUpdated) throws {
        readModel.totalAmount = event.newAmount
    }
}
