import Foundation
import Testing
@testable import ContextForwarder

@Suite("ForwardingRule")
struct ForwardingRuleTests {

    private struct CollaboratorAddedBody: Codable {
        let collaboratorId: String
        let role: String
    }

    @Test("decodeBody decodes the raw JSON payload")
    func decodeBody() throws {
        let json = #"{"collaboratorId":"acc-1","role":"editor"}"#.data(using: .utf8)!
        let record = ForwardedRecord(
            eventType: "CollaboratorAdded",
            streamName: "OCQuotingCaseGrouping-g1",
            eventId: "e-1",
            data: json)

        let body = try record.decodeBody(CollaboratorAddedBody.self)
        #expect(body.collaboratorId == "acc-1")
        #expect(body.role == "editor")
    }

    @Test("a rule translates matching records and can skip with nil")
    func ruleTranslates() async throws {
        let rule = ForwardingRule(eventTypes: ["CollaboratorAdded"]) { record in
            let body = try record.decodeBody(CollaboratorAddedBody.self)
            guard body.role != "viewer" else { return nil }  // demonstrate skip
            return PublishedLanguageEvent(
                eventId: record.eventId,
                eventType: "OpportunityCollaboratorAdded.v1",
                occurredAt: try record.decodeOccurred(),
                recipientIds: [body.collaboratorId],
                payload: ["role": body.role])
        }

        let occurredSeconds = Date().timeIntervalSinceReferenceDate
        let editor = ForwardedRecord(
            eventType: "CollaboratorAdded", streamName: "s", eventId: "e-1",
            data: #"{"collaboratorId":"acc-1","role":"editor","occurred":\#(occurredSeconds)}"#.data(using: .utf8)!)
        let viewer = ForwardedRecord(
            eventType: "CollaboratorAdded", streamName: "s", eventId: "e-2",
            data: #"{"collaboratorId":"acc-2","role":"viewer","occurred":\#(occurredSeconds)}"#.data(using: .utf8)!)

        #expect(try await rule.translate(editor)?.recipientIds == ["acc-1"])
        #expect(try await rule.translate(viewer) == nil)
        #expect(rule.eventTypes.contains("CollaboratorAdded"))
    }
}
