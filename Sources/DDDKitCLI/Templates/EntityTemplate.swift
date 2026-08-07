enum EntityTemplate {
    static func files(for ctx: ProjectContext) -> [ScaffoldFile] {
        let base = "Sources/\(ctx.aggregateTarget)/Entity"
        return [
            ScaffoldFile(path: "\(base)/\(ctx.aggregateName).swift", content: aggregateRoot(ctx)),
            ScaffoldFile(path: "\(base)/\(ctx.aggregateName)Error.swift", content: error(ctx)),
            ScaffoldFile(
                path: "\(base)/Commands/\(ctx.aggregateName)+Rename.swift",
                content: renameCommand(ctx)
            ),
            ScaffoldFile(
                path: "\(base)/Commands/\(ctx.aggregateName)+Delete.swift",
                content: deleteCommand(ctx)
            ),
        ]
    }

    private static func aggregateRoot(_ ctx: ProjectContext) -> String {
        """
        import DDDKit
        import Foundation

        /// The \(ctx.aggregateName) aggregate root — the write-side consistency boundary.
        ///
        /// `\(ctx.aggregateTarget)Protocol` is generated from event.yaml (see the plugins in
        /// Package.swift); it requires the `init?(first:other:)` replay initializer below
        /// plus one `when(event:)` per non-created / non-deleted event.
        public class \(ctx.aggregateName): \(ctx.aggregateTarget)Protocol {

            public var metadata: AggregateRootMetadata = .init()

            public let id: String
            public internal(set) var name: String

            public init(id: String, name: String) throws {
                self.id = id
                self.name = name

                let event = \(ctx.createdEvent)(\(ctx.idAlias): id, name: name)
                try apply(event: event)
            }

            public required convenience init?(
                first createdEvent: \(ctx.createdEvent),
                other events: [any DomainEvent]
            ) throws {
                try self.init(id: createdEvent.\(ctx.idAlias), name: createdEvent.name)
                try apply(events: events)
                try clearAllDomainEvents()
            }

            public func ensureInvariant() throws {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw \(ctx.aggregateName)Error.nameCannotBeEmpty
                }
            }
        }
        """
    }

    private static func error(_ ctx: ProjectContext) -> String {
        """
        public enum \(ctx.aggregateName)Error: Error {
            case nameCannotBeEmpty
        }
        """
    }

    private static func renameCommand(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        extension \(ctx.aggregateName) {
            public func rename(to newName: String) throws {
                let event = \(ctx.renamedEvent)(\(ctx.idAlias): id, name: newName)
                try apply(event: event)
            }

            public func when(event: \(ctx.renamedEvent)) throws {
                self.name = event.name
            }
        }
        """
    }

    private static func deleteCommand(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        extension \(ctx.aggregateName) {
            /// `markDelete()` (provided by `AggregateRoot`) emits `\(ctx.deletedEvent)` and
            /// routes here. Flipping `metadata.delete()` is what makes `deleted` — and the
            /// repository's default `find(byId:)` soft-delete filtering — take effect.
            public func when(event: \(ctx.deletedEvent)) throws {
                metadata.delete()
            }
        }
        """
    }
}
