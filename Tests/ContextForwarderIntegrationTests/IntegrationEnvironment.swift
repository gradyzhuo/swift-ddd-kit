import Foundation

enum IntegrationEnvironment {
    static var pulsarURL: String? { ProcessInfo.processInfo.environment["PULSAR_HTTP_URL"] }
    static var kurrentURL: String? { ProcessInfo.processInfo.environment["KURRENT_DB_URL"] }
    static var pulsarEnabled: Bool { pulsarURL != nil }
    static var fullEnabled: Bool { pulsarURL != nil && kurrentURL != nil }
}
