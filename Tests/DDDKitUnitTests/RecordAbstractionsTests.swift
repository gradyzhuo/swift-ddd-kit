import Testing
import Foundation
import DDDCore
import EventSourcing

private struct ProbeRecord: RecordedEventLike {
    let id = UUID()
    let eventType = "Probe"
    let revision: UInt64 = 0
    let customMetadata = Data()
    let streamName = "Probe-1"
    func decode<T: Decodable>(to type: T.Type) throws -> T? { nil }
}

private struct ProbeMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? { nil }
}

@Suite("Record abstractions live in EventSourcing")
struct RecordAbstractionsTests {
    @Test("mapper, record and CustomMetadata are usable without KurrentSupport")
    func usableWithoutKurrentSupport() throws {
        let mapper: any EventTypeMapper = ProbeMapper()
        #expect(try mapper.mapping(eventData: ProbeRecord()) == nil)
        #expect(CustomMetadata(operatorId: "u-1").operatorId == "u-1")
    }
}
