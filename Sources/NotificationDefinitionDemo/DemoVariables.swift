//
//  DemoVariables.swift
//  NotificationDefinitionDemo
//
//  Hand-written stub conforming to the GENERATED `DemoNotificationVariables`
//  protocol (from variables.yaml via VariablesGeneratorPlugin). Canned values
//  only — this target exists to prove the codegen chain compiles and renders,
//  not to model a real read model.
//

public struct DemoVariables: DemoNotificationVariables {

    public init() {}

    public func quotingCaseGroupName(quotingCaseGroupingId: String) async throws -> String {
        "6666"
    }

    public func collaboratorDescription(quotingCaseGroupingId: String, collaboratorId: String) async throws -> String {
        "歡迎加入團隊"
    }

    public func quotingCaseGroupCollaboratorRole(quotingCaseGroupingId: String, collaboratorId: String) async throws -> String {
        "編輯者"
    }
}
