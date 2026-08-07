enum AggregateYAMLTemplate {
    static func files(for ctx: ProjectContext) -> [ScaffoldFile] {
        let base = "Sources/\(ctx.aggregateTarget)"
        return [
            ScaffoldFile(path: "\(base)/event.yaml", content: eventYAML(ctx)),
            ScaffoldFile(path: "\(base)/event-generator-config.yaml", content: eventGeneratorConfigYAML),
            ScaffoldFile(path: "\(base)/projection-model.yaml", content: projectionModelYAML(ctx)),
        ]
    }

    private static func eventYAML(_ ctx: ProjectContext) -> String {
        """
        # Domain event schema for \(ctx.aggregateTarget).
        #
        # DomainEventGeneratorPlugin turns this into `\(ctx.createdEvent)` / `\(ctx.renamedEvent)` /
        # `\(ctx.deletedEvent)` structs, and ModelGeneratorPlugin uses `kind` here to derive
        # `\(ctx.aggregateTarget)Protocol` (see projection-model.yaml for the read side).

        \(ctx.createdEvent):
          kind: createdEvent
          aggregateRootId:
            alias: \(ctx.idAlias)
          properties:
            name: String

        \(ctx.renamedEvent):
          aggregateRootId:
            alias: \(ctx.idAlias)
          properties:
            name: String

        \(ctx.deletedEvent):
          kind: deletedEvent
        """
    }

    private static let eventGeneratorConfigYAML = """
        accessModifier: public
        """

    private static func projectionModelYAML(_ ctx: ProjectContext) -> String {
        """
        # Read models for \(ctx.aggregateTarget). ModelGeneratorPlugin turns each entry
        # below into a `<Name>ProjectorProtocol` — the concrete ReadModel struct and the
        # projector conforming to it are hand-written under Usecase/Projector/.

        \(ctx.aggregateName)Summary:
          model: readModel
          events:
            - \(ctx.createdEvent)
            - \(ctx.renamedEvent)
        """
    }
}
