import KurrentDB
import Testing
@testable import ContextForwarder

@Suite("Missing subscription group detection")
struct MissingGroupDetectionTests {
    @Test("NotFound from KurrentDB means the group is missing")
    func resourceNotFoundIsMissingGroup() {
        #expect(ContextForwarder.isMissingGroup(
            .resourceNotFound(reason: "Subscription group oc-pl-forwarder-handover on stream $ce-OCHandover does not exist.")))
    }

    @Test("connection and drop errors are not a missing group")
    func otherErrorsAreNotMissingGroup() {
        #expect(!ContextForwarder.isMissingGroup(.connectionClosed))
        #expect(!ContextForwarder.isMissingGroup(.resourceAlreadyExists))
        #expect(!ContextForwarder.isMissingGroup(.accessDenied))
        #expect(!ContextForwarder.isMissingGroup(
            .subscriptionDropped(reason: "Stream unexpectedly closed.", lastRevision: nil, lastPosition: nil)))
    }
}
