import Foundation
import Testing
@testable import EventSourcing

private struct TestAuditMeta: EventMetadata, Equatable {
    let operatorId: String
}

private struct OtherMeta: EventMetadata, Equatable {
    let tenantId: String
}

@Suite("EventMetadataContext")
struct EventMetadataContextTests {

    @Test("withValue inside closure exposes the set value")
    func withValueExposes() async throws {
        await EventMetadataContext<TestAuditMeta>._current.withValue(TestAuditMeta(operatorId: "u1")) {
            #expect(EventMetadataContext<TestAuditMeta>.current == TestAuditMeta(operatorId: "u1"))
        }
    }

    @Test("After withValue returns, current is back to nil")
    func currentRestoresAfterScope() async throws {
        await EventMetadataContext<TestAuditMeta>._current.withValue(TestAuditMeta(operatorId: "u1")) {
            _ = EventMetadataContext<TestAuditMeta>.current
        }
        #expect(EventMetadataContext<TestAuditMeta>.current == nil)
    }

    @Test("Nested withValue overrides; outer restored on inner exit")
    func nestedOverride() async throws {
        await EventMetadataContext<TestAuditMeta>._current.withValue(TestAuditMeta(operatorId: "outer")) {
            await EventMetadataContext<TestAuditMeta>._current.withValue(TestAuditMeta(operatorId: "inner")) {
                #expect(EventMetadataContext<TestAuditMeta>.current?.operatorId == "inner")
            }
            #expect(EventMetadataContext<TestAuditMeta>.current?.operatorId == "outer")
        }
    }

    @Test("Different M types have independent storage slots")
    func independentSlotsPerType() async throws {
        await EventMetadataContext<TestAuditMeta>._current.withValue(TestAuditMeta(operatorId: "u1")) {
            await EventMetadataContext<OtherMeta>._current.withValue(OtherMeta(tenantId: "t1")) {
                #expect(EventMetadataContext<TestAuditMeta>.current?.operatorId == "u1")
                #expect(EventMetadataContext<OtherMeta>.current?.tenantId == "t1")
            }
        }
    }

    @Test("Structured async let inherits the ambient context")
    func structuredAsyncLetInherits() async throws {
        let result = await EventMetadataContext<TestAuditMeta>._current.withValue(TestAuditMeta(operatorId: "u1")) {
            async let observed = EventMetadataContext<TestAuditMeta>.current
            return await observed
        }
        #expect(result?.operatorId == "u1")
    }

    @Test("Task.detached does NOT inherit ambient context")
    func detachedTaskDoesNotInherit() async throws {
        let detachedValue: TestAuditMeta? = await EventMetadataContext<TestAuditMeta>._current.withValue(TestAuditMeta(operatorId: "u1")) {
            await Task.detached { EventMetadataContext<TestAuditMeta>.current }.value
        }
        #expect(detachedValue == nil)
    }
}
