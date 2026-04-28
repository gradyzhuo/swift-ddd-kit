//
//  KurrentClientFactory.swift
//  TestUtility
//
//  Shared factory for the `KurrentDBClient` used by integration tests so each
//  suite does not have to re-derive the cluster connection settings.
//

import KurrentDB

extension KurrentDBClient {
    /// Creates a `KurrentDBClient` configured for the standard local KurrentDB
    /// container/cluster used by integration tests.
    ///
    /// Connects to a 3-node TLS-secured cluster on ports 2111/2112/2113 with
    /// `tlsVerifyCert = false` and admin credentials `admin/changeit`.
    public static func makeIntegrationTestClient() -> KurrentDBClient {
        let settings = ClientSettings(
            clusterMode: .seeds([
                .init(host: "localhost", port: 2111),
                .init(host: "localhost", port: 2112),
                .init(host: "localhost", port: 2113),
            ]),
            secure: true,
            tlsVerifyCert: false
        ).authenticated(.credentials(username: "admin", password: "changeit"))
        return KurrentDBClient(settings: settings)
    }
}
