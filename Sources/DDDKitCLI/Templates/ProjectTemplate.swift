/// Aggregates every template group into the full file set for `dddkit project create`.
enum ProjectTemplate {
    static func files(for ctx: ProjectContext) -> [ScaffoldFile] {
        RootTemplate.files(for: ctx)
            + AggregateYAMLTemplate.files(for: ctx)
            + EntityTemplate.files(for: ctx)
            + RepositoryTemplate.files(for: ctx)
            + UsecaseTemplate.files(for: ctx)
            + ProjectorTemplate.files(for: ctx)
            + AppTemplate.files(for: ctx)
            + TestsTemplate.files(for: ctx)
    }
}
