
public protocol Projector: AnyObject {
    associatedtype ProjectableType: Projectable

    func find(byId id: ProjectableType.ID) async throws -> ProjectableType?
}