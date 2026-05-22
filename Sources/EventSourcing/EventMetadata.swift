/// Marker protocol for application-defined event metadata schemas.
///
/// Applications define concrete metadata structs by conforming to this protocol;
/// the framework imposes no schema fields. Together with `EventMetadataContext`,
/// this is the write-side channel that replaces the legacy `external: [String:String]?`
/// parameter on `EventSourcingRepository.save` / `EventStore.append`.
///
/// Example:
/// ```swift
/// struct AuditMetadata: EventMetadata {
///     let operatorId: String
///     let tenantId: String
/// }
/// ```
public protocol EventMetadata: Codable, Sendable {}
