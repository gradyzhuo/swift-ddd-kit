/// All names derived once per `dddkit project create` invocation and threaded
/// through the templates, so every generated file agrees on the same casing.
struct ProjectContext {
    /// PascalCase project/package name, e.g. "OrderContext".
    let projectName: String
    /// PascalCase, singular aggregate root name, e.g. "Order".
    let aggregateName: String
    /// A ready-to-splice `.package(...)` line for the generated Package.swift.
    let kitDependencyLine: String

    var aggregateTarget: String { "\(aggregateName)Aggregate" }
    var appTarget: String { "\(projectName)App" }
    var testsTarget: String { "\(projectName)Tests" }

    /// e.g. "orderId" — the aggregateRootId alias used in event.yaml.
    var idAlias: String { "\(NameConvention.camelCase(from: aggregateName))Id" }
    /// e.g. "order" — a local variable name for an instance of the aggregate.
    var varName: String { NameConvention.camelCase(from: aggregateName) }

    var createdEvent: String { "\(aggregateName)Created" }
    var renamedEvent: String { "\(aggregateName)Renamed" }
    var deletedEvent: String { "\(aggregateName)Deleted" }
}
