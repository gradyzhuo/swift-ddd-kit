enum RepositoryTemplate {
    static func files(for ctx: ProjectContext) -> [ScaffoldFile] {
        [
            ScaffoldFile(
                path: "Sources/\(ctx.aggregateTarget)/Usecase/Port/Out/\(ctx.aggregateName)Repository.swift",
                content: repository(ctx)
            )
        ]
    }

    private static func repository(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        /// Write-side port. `EventSourcingRepository`'s default extension provides
        /// `find(byId:)` / `save(aggregateRoot:)` / `delete(byId:)` — this struct only
        /// needs to name the concrete store.
        public struct \(ctx.aggregateName)Repository: EventSourcingRepository {
            public typealias Store = KurrentStorageCoordinator<\(ctx.aggregateName), CustomMetadata>
            public typealias AggregateRootType = \(ctx.aggregateName)

            public let store: Store

            public init(store: Store) {
                self.store = store
            }
        }
        """
    }
}
