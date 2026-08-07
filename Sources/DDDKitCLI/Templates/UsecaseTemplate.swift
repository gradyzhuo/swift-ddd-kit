enum UsecaseTemplate {
    static func files(for ctx: ProjectContext) -> [ScaffoldFile] {
        createFiles(ctx) + renameFiles(ctx) + deleteFiles(ctx)
    }

    // MARK: - Create

    private static func createFiles(_ ctx: ProjectContext) -> [ScaffoldFile] {
        let portDir = "Sources/\(ctx.aggregateTarget)/Usecase/Port/In/Create\(ctx.aggregateName)"
        let serviceDir = "Sources/\(ctx.aggregateTarget)/Usecase/Service"
        return [
            ScaffoldFile(path: "\(portDir)/Create\(ctx.aggregateName)Input.swift", content: createInput(ctx)),
            ScaffoldFile(path: "\(portDir)/Create\(ctx.aggregateName)Output.swift", content: sharedOutput(ctx, name: "Create\(ctx.aggregateName)Output")),
            ScaffoldFile(path: "\(portDir)/Create\(ctx.aggregateName)Usecase.swift", content: createUsecase(ctx)),
            ScaffoldFile(path: "\(serviceDir)/Create\(ctx.aggregateName)Service.swift", content: service(ctx, name: "Create\(ctx.aggregateName)")),
        ]
    }

    private static func createInput(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        public struct Create\(ctx.aggregateName)Input: UseCaseInput {
            public let id: String
            public let name: String
            public let operatorId: String

            public init(id: String, name: String, operatorId: String) {
                self.id = id
                self.name = name
                self.operatorId = operatorId
            }
        }
        """
    }

    private static func createUsecase(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        public protocol Create\(ctx.aggregateName)Usecase: Usecase
        where Input == Create\(ctx.aggregateName)Input, Output == Create\(ctx.aggregateName)Output {
            var repository: \(ctx.aggregateName)Repository { get }
        }

        extension Create\(ctx.aggregateName)Usecase {
            public func execute(input: Input) async throws -> Output {
                do {
                    let \(ctx.varName) = try \(ctx.aggregateName)(id: input.id, name: input.name)
                    try await EventMetadataContext<CustomMetadata>.withValue(.init(operatorId: input.operatorId)) {
                        try await repository.save(aggregateRoot: \(ctx.varName))
                    }
                    return .init(id: \(ctx.varName).id)
                } catch let error as DDDError {
                    throw error
                } catch {
                    throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": "\\(error)"])
                }
            }
        }
        """
    }

    // MARK: - Rename

    private static func renameFiles(_ ctx: ProjectContext) -> [ScaffoldFile] {
        let portDir = "Sources/\(ctx.aggregateTarget)/Usecase/Port/In/Rename\(ctx.aggregateName)"
        let serviceDir = "Sources/\(ctx.aggregateTarget)/Usecase/Service"
        return [
            ScaffoldFile(path: "\(portDir)/Rename\(ctx.aggregateName)Input.swift", content: renameInput(ctx)),
            ScaffoldFile(path: "\(portDir)/Rename\(ctx.aggregateName)Output.swift", content: sharedOutput(ctx, name: "Rename\(ctx.aggregateName)Output")),
            ScaffoldFile(path: "\(portDir)/Rename\(ctx.aggregateName)Usecase.swift", content: renameUsecase(ctx)),
            ScaffoldFile(path: "\(serviceDir)/Rename\(ctx.aggregateName)Service.swift", content: service(ctx, name: "Rename\(ctx.aggregateName)")),
        ]
    }

    private static func renameInput(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        public struct Rename\(ctx.aggregateName)Input: UseCaseInput {
            public let id: String
            public let name: String
            public let operatorId: String

            public init(id: String, name: String, operatorId: String) {
                self.id = id
                self.name = name
                self.operatorId = operatorId
            }
        }
        """
    }

    private static func renameUsecase(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        public protocol Rename\(ctx.aggregateName)Usecase: Usecase
        where Input == Rename\(ctx.aggregateName)Input, Output == Rename\(ctx.aggregateName)Output {
            var repository: \(ctx.aggregateName)Repository { get }
        }

        extension Rename\(ctx.aggregateName)Usecase {
            public func execute(input: Input) async throws -> Output {
                do {
                    guard let \(ctx.varName) = try await repository.find(byId: input.id) else {
                        throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: \(ctx.aggregateName).self, aggregateRootId: input.id)
                    }
                    try \(ctx.varName).rename(to: input.name)
                    try await EventMetadataContext<CustomMetadata>.withValue(.init(operatorId: input.operatorId)) {
                        try await repository.save(aggregateRoot: \(ctx.varName))
                    }
                    return .init(id: \(ctx.varName).id)
                } catch let error as DDDError {
                    throw error
                } catch {
                    throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": "\\(error)"])
                }
            }
        }
        """
    }

    // MARK: - Delete

    private static func deleteFiles(_ ctx: ProjectContext) -> [ScaffoldFile] {
        let portDir = "Sources/\(ctx.aggregateTarget)/Usecase/Port/In/Delete\(ctx.aggregateName)"
        let serviceDir = "Sources/\(ctx.aggregateTarget)/Usecase/Service"
        return [
            ScaffoldFile(path: "\(portDir)/Delete\(ctx.aggregateName)Input.swift", content: deleteInput(ctx)),
            ScaffoldFile(path: "\(portDir)/Delete\(ctx.aggregateName)Output.swift", content: sharedOutput(ctx, name: "Delete\(ctx.aggregateName)Output")),
            ScaffoldFile(path: "\(portDir)/Delete\(ctx.aggregateName)Usecase.swift", content: deleteUsecase(ctx)),
            ScaffoldFile(path: "\(serviceDir)/Delete\(ctx.aggregateName)Service.swift", content: service(ctx, name: "Delete\(ctx.aggregateName)")),
        ]
    }

    private static func deleteInput(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        public struct Delete\(ctx.aggregateName)Input: UseCaseInput {
            public let id: String
            public let operatorId: String

            public init(id: String, operatorId: String) {
                self.id = id
                self.operatorId = operatorId
            }
        }
        """
    }

    private static func deleteUsecase(_ ctx: ProjectContext) -> String {
        """
        import DDDKit

        public protocol Delete\(ctx.aggregateName)Usecase: Usecase
        where Input == Delete\(ctx.aggregateName)Input, Output == Delete\(ctx.aggregateName)Output {
            var repository: \(ctx.aggregateName)Repository { get }
        }

        extension Delete\(ctx.aggregateName)Usecase {
            public func execute(input: Input) async throws -> Output {
                do {
                    try await EventMetadataContext<CustomMetadata>.withValue(.init(operatorId: input.operatorId)) {
                        try await repository.delete(byId: input.id)
                    }
                    return .init(id: input.id)
                } catch let error as DDDError {
                    throw error
                } catch {
                    throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": "\\(error)"])
                }
            }
        }
        """
    }

    // MARK: - Shared

    private static func sharedOutput(_ ctx: ProjectContext, name: String) -> String {
        """
        import DDDKit

        public struct \(name): UseCaseOutput {
            public let id: String?
            public let message: String?

            public init(id: String?, message: String? = nil) {
                self.id = id
                self.message = message
            }
        }
        """
    }

    private static func service(_ ctx: ProjectContext, name: String) -> String {
        """
        /// Concrete, dependency-injectable implementation of `\(name)Usecase`.
        public struct \(name)Service: \(name)Usecase {
            public let repository: \(ctx.aggregateName)Repository

            public init(repository: \(ctx.aggregateName)Repository) {
                self.repository = repository
            }
        }
        """
    }
}
