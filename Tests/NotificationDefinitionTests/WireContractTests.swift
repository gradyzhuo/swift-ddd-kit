import Testing
@testable import NotificationDefinition

@Suite("RenderedNotification.payloadEntries")
struct RenderedNotificationPayloadEntriesTests {

    @Test("flattens a mail notification to \"mail.{field}\" keys")
    func flattensMail() {
        let notification = RenderedNotification(
            type: .mail, recipients: [], fields: ["subject": "Hi", "content": "Body"])
        #expect(notification.payloadEntries == ["mail.subject": "Hi", "mail.content": "Body"])
    }

    @Test("flattens an inApp notification to \"inApp.{field}\" keys")
    func flattensInApp() {
        let notification = RenderedNotification(
            type: .inApp, recipients: [], fields: ["title": "Hi", "content": "Body"])
        #expect(notification.payloadEntries == ["inApp.title": "Hi", "inApp.content": "Body"])
    }

    @Test("flattens an inApp notification's render field to \"inApp.render\"")
    func flattensInAppRenderField() {
        let notification = RenderedNotification(
            type: .inApp, recipients: [], fields: ["title": "Hi", "content": "Body", "render": "plaintext"])
        #expect(notification.payloadEntries["inApp.render"] == "plaintext")
    }
}

@Suite("RenderedNotification.recipients")
struct RenderedNotificationRecipientsTests {

    @Test("RenderedNotification carries its own recipients")
    func renderedNotificationCarriesRecipients() {
        let notification = RenderedNotification(
            type: .mail, recipients: ["acct-1", "acct-2"], fields: ["subject": "s", "content": "c"])
        #expect(notification.recipients == ["acct-1", "acct-2"])
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
