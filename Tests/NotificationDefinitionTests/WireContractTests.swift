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

    @Test("flattens a mail notification's template and slot fields to \"mail.template*\" keys")
    func flattensMailTemplateFields() {
        let notification = RenderedNotification(
            type: .mail, recipients: [],
            fields: [
                "subject": "S", "content": "C",
                "template": "one-button",
                "template.action_url": "https://example.test/cases/42",
            ])
        #expect(notification.payloadEntries["mail.template"] == "one-button")
        #expect(notification.payloadEntries["mail.template.action_url"] == "https://example.test/cases/42")
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

    @Test("splits on the first dot only, so a slot key keeps its dotted field name")
    func parsesDottedSlotField() {
        let parsed = PayloadKey.parse("mail.template.action_url")
        #expect(parsed?.type == .mail)
        #expect(parsed?.field == "template.action_url")
    }
}

@Suite("RenderedNotification entry id and variables")
struct RenderedNotificationEntryAndVariablesTests {

    @Test("entryId flattens to \"{type}.entry\" for mail and inApp")
    func entryIdFlattens() {
        let mail = RenderedNotification(
            type: .mail, entryId: "assigned-member-added-mail-for-members", recipients: [],
            fields: ["subject": "S", "content": "C"])
        let inApp = RenderedNotification(
            type: .inApp, entryId: "assigned-member-added-in-app-for-members", recipients: [],
            fields: ["title": "T", "content": "C"])
        #expect(mail.payloadEntries["mail.entry"] == "assigned-member-added-mail-for-members")
        #expect(inApp.payloadEntries["inApp.entry"] == "assigned-member-added-in-app-for-members")
    }

    @Test("each variable flattens to \"{type}.var.{Placeholder}\"")
    func variablesFlatten() {
        let notification = RenderedNotification(
            type: .mail, entryId: "e", recipients: [],
            fields: ["subject": "S", "content": "C"],
            variables: ["AssignedDepartment": "審計一組", "QuotingCaseGroupName": "6666"])
        #expect(notification.payloadEntries == [
            "mail.subject": "S",
            "mail.content": "C",
            "mail.entry": "e",
            "mail.var.AssignedDepartment": "審計一組",
            "mail.var.QuotingCaseGroupName": "6666",
        ])
    }

    @Test("defaults keep the legacy payload exactly: no entry key, no var keys")
    func defaultsKeepLegacyPayload() {
        let notification = RenderedNotification(
            type: .inApp, recipients: ["acct-1"], fields: ["title": "T", "content": "C", "render": "plaintext"])
        #expect(notification.entryId == nil)
        #expect(notification.variables == [:])
        #expect(notification.payloadEntries == [
            "inApp.title": "T", "inApp.content": "C", "inApp.render": "plaintext",
        ])
    }

    @Test("a variable resolving to an empty string is still emitted")
    func emptyVariableValueIsEmitted() {
        let notification = RenderedNotification(
            type: .mail, entryId: "e", recipients: [],
            fields: ["subject": "S", "content": "C"], variables: ["CollaboratorDescription": ""])
        #expect(notification.payloadEntries["mail.var.CollaboratorDescription"] == "")
    }

    @Test("a fields key colliding with a generated key wins, and nothing traps")
    func fieldsWinOnKeyCollision() {
        let notification = RenderedNotification(
            type: .mail, entryId: "from-entry-id", recipients: [],
            fields: ["subject": "S", "content": "C", "entry": "from-fields", "var.X": "from-fields"],
            variables: ["X": "from-variables"])
        #expect(notification.payloadEntries["mail.entry"] == "from-fields")
        #expect(notification.payloadEntries["mail.var.X"] == "from-fields")
    }

    @Test("PayloadKey.parse keeps the var. prefix on the field half")
    func parseKeepsVarPrefix() {
        let parsed = PayloadKey.parse("mail.var.AssignedDepartment")
        #expect(parsed?.type == .mail)
        #expect(parsed?.field == "var.AssignedDepartment")
    }
}
