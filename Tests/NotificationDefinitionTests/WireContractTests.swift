import Testing
@testable import NotificationDefinition

@Suite("RenderedNotification.payloadEntries")
struct RenderedNotificationPayloadEntriesTests {

    @Test("flattens a mail notification to \"mail.{field}\" keys")
    func flattensMail() {
        let notification = RenderedNotification(type: .mail, fields: ["subject": "Hi", "content": "Body"])
        #expect(notification.payloadEntries == ["mail.subject": "Hi", "mail.content": "Body"])
    }

    @Test("flattens an inApp notification to \"inApp.{field}\" keys")
    func flattensInApp() {
        let notification = RenderedNotification(type: .inApp, fields: ["title": "Hi", "content": "Body"])
        #expect(notification.payloadEntries == ["inApp.title": "Hi", "inApp.content": "Body"])
    }
}

@Suite("PayloadKey.parse")
struct PayloadKeyParseTests {

    @Test("parses a well-formed \"{type}.{field}\" key")
    func parsesHappyPath() {
        let parsed = PayloadKey.parse("mail.subject")
        #expect(parsed?.type == .mail)
        #expect(parsed?.field == "subject")
    }

    @Test("returns nil for an unknown type prefix")
    func returnsNilForUnknownType() {
        #expect(PayloadKey.parse("push.subject") == nil)
    }

    @Test("returns nil when there is no dot")
    func returnsNilForNoDot() {
        #expect(PayloadKey.parse("mailsubject") == nil)
    }

    @Test("returns nil when the field half is empty")
    func returnsNilForEmptyField() {
        #expect(PayloadKey.parse("mail.") == nil)
    }
}
