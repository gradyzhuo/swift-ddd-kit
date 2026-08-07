enum ProjectorTemplate {
    static func files(for ctx: ProjectContext) -> [ScaffoldFile] {
        [
            ScaffoldFile(
                path: "Sources/\(ctx.aggregateTarget)/Usecase/Projector/\(ctx.aggregateName)SummaryProjector.swift",
                content: projector(ctx)
            )
        ]
    }

    private static func projector(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        /// Read model for \(ctx.aggregateName) — kept in `projection-model.yaml` under
        /// `\(ctx.aggregateName)Summary`, which generates `\(ctx.aggregateName)SummaryProjectorProtocol`
        /// (one `when(readModel:event:)` requirement per listed event).
        public struct \(ctx.aggregateName)Summary: ReadModel, Codable, Sendable {
            public let id: String
            public var name: String

            public init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        public struct \(ctx.aggregateName)SummaryProjectorInput: CQRSProjectorInput {
            public let id: String

            public init(id: String) {
                self.id = id
            }
        }

        /// Read-side: replays events straight from the same KurrentDB stream the write
        /// side appends to. Write and read never share in-process state — see the
        /// architecture diagram in the swift-ddd-kit README.
        public struct \(ctx.aggregateName)SummaryProjector: EventSourcingProjector, \(ctx.aggregateName)SummaryProjectorProtocol {
            public typealias ReadModelType = \(ctx.aggregateName)Summary
            public typealias Input = \(ctx.aggregateName)SummaryProjectorInput
            public typealias Store = KurrentStorageCoordinator<\(ctx.aggregateName), CustomMetadata>

            public let store: Store

            public init(store: Store) {
                self.store = store
            }

            public func buildReadModel(input: Input) throws -> \(ctx.aggregateName)Summary? {
                \(ctx.aggregateName)Summary(id: input.id, name: "")
            }

            public func when(readModel: inout \(ctx.aggregateName)Summary, event: \(ctx.createdEvent)) throws {
                readModel.name = event.name
            }

            public func when(readModel: inout \(ctx.aggregateName)Summary, event: \(ctx.renamedEvent)) throws {
                readModel.name = event.name
            }
        }
        """
    }
}
