import Foundation
import PublishedLanguage
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

    @Test("a rule translates matching records and can skip with empty array")
    func ruleTranslates() async throws {
        let rule = ForwardingRule(eventTypes: ["CollaboratorAdded"]) { record in
            let body = try record.decodeBody(CollaboratorAddedBody.self)
            guard body.role != "viewer" else { return [] }  // demonstrate skip
            return [PublishedLanguageEvent(
                eventId: record.eventId,
                eventType: "OpportunityCollaboratorAdded.v1",
                occurredAt: try record.decodeOccurred(),
                recipientIds: [body.collaboratorId],
                payload: ["role": body.role])]
        }

        let occurredSeconds = Date().timeIntervalSinceReferenceDate
        let editor = ForwardedRecord(
            eventType: "CollaboratorAdded", streamName: "s", eventId: "e-1",
            data: #"{"collaboratorId":"acc-1","role":"editor","occurred":\#(occurredSeconds)}"#.data(using: .utf8)!)
        let viewer = ForwardedRecord(
            eventType: "CollaboratorAdded", streamName: "s", eventId: "e-2",
            data: #"{"collaboratorId":"acc-2","role":"viewer","occurred":\#(occurredSeconds)}"#.data(using: .utf8)!)

        let editorEvents = try await rule.translate(editor)
        #expect(editorEvents.count == 1)
        #expect(editorEvents[0].recipientIds == ["acc-1"])
        let viewerEvents = try await rule.translate(viewer)
        #expect(viewerEvents.isEmpty)
        #expect(rule.eventTypes.contains("CollaboratorAdded"))
    }

    @Test("a rule can translate one record into multiple published events")
    func ruleTranslatesToMultipleEvents() async throws {
        let rule = ForwardingRule(eventTypes: ["CollaboratorAdded"]) { record in
            let body = try record.decodeBody(CollaboratorAddedBody.self)
            return [
                PublishedLanguageEvent(
                    eventId: "\(record.eventId)#mail",
                    eventType: "OpportunityCollaboratorAdded.v1",
                    occurredAt: try record.decodeOccurred(),
                    recipientIds: [body.collaboratorId],
                    payload: ["mail.role": body.role]),
                PublishedLanguageEvent(
                    eventId: "\(record.eventId)#inApp",
                    eventType: "OpportunityCollaboratorAdded.v1",
                    occurredAt: try record.decodeOccurred(),
                    recipientIds: [body.collaboratorId],
                    payload: ["inApp.role": body.role]),
            ]
        }
        let record = ForwardedRecord(
            eventType: "CollaboratorAdded", streamName: "s-1", eventId: "e-1",
            data: #"{"collaboratorId":"acc-1","role":"editor","occurred":1756252800}"#.data(using: .utf8)!)

        let events = try await rule.translate(record)

        #expect(events.count == 2)
        #expect(events[0].eventId == "e-1#mail")
        #expect(events[1].eventId == "e-1#inApp")
    }

    @Test("a rule can still skip a record by returning an empty array")
    func ruleSkipsWithEmptyArray() async throws {
        let rule = ForwardingRule(eventTypes: ["CollaboratorAdded"]) { record in
            let body = try record.decodeBody(CollaboratorAddedBody.self)
            return body.role == "viewer" ? [] : [PublishedLanguageEvent(
                eventId: record.eventId,
                eventType: "OpportunityCollaboratorAdded.v1",
                occurredAt: try record.decodeOccurred(),
                recipientIds: [body.collaboratorId],
                payload: ["role": body.role])]
        }
        let record = ForwardedRecord(
            eventType: "CollaboratorAdded", streamName: "s-1", eventId: "e-1",
            data: #"{"collaboratorId":"acc-1","role":"viewer"}"#.data(using: .utf8)!)

        let events = try await rule.translate(record)
        #expect(events.isEmpty)
    }
}
