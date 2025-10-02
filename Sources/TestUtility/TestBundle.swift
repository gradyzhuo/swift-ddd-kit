//
//  IdGenerator.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/8/7.
//

import Foundation
import KurrentDB
import DDDCore


public actor TestBundle {
    public let client: KurrentDBClient
    public private(set) var streamIdentifiers: [StreamIdentifier] = []
    public private(set) var commonIdentifiers: [String] = []
    public let cleanPhase: CleanPhase
    
    fileprivate init(client: KurrentDBClient, cleanPhase: TestBundle.CleanPhase) {
        self.client = client
        self.streamIdentifiers = []
        self.cleanPhase = cleanPhase
    }
    
    public func generateAggregateRootId(for category: String, prefix: String = "testing") async -> String {
        let id = "\(prefix)\(UUID().uuidString)"
        let streamIdentifier = StreamIdentifier(name: "\(category)-\(id)")
        self.streamIdentifiers.append(streamIdentifier)
        
        if cleanPhase.contains(.begin) {
            await self.clearStream(streamIdentifier: streamIdentifier)
        }
        return id
    }
    
    public func generateId(for category: String, prefix: String = "testing") async -> String {
        let id = "\(prefix)\(UUID().uuidString)"
        self.commonIdentifiers.append("\(category)-\(id)")
        return id
    }
    
    public func alsoClean<T: Projectable>(projectableType: T, id: T.ID) async {
        let streamIdentifier = StreamIdentifier(name: T.getStreamName(id: id))
        self.streamIdentifiers.append(streamIdentifier)
        
        if cleanPhase.contains(.begin) {
            await self.clearStream(streamIdentifier: streamIdentifier)
        }
    }
    
    fileprivate func clearStream(streamIdentifier: StreamIdentifier) async {
        _ = try? await self.client.deleteStream(streamIdentifier){ options in
            options.revision(expected: .any)
        }
    }
    
    public func clearStreams() async {
        await withTaskGroup(of: Void.self) { group in
            for streamIdentifier in self.streamIdentifiers {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.clearStream(streamIdentifier: streamIdentifier)
                }
            }
        }
        
    }
    
}

extension TestBundle {
    public struct CleanPhase: OptionSet{
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
        
        public var rawValue: UInt8
        
        public typealias RawValue = UInt8
        
        public static let begin: CleanPhase = .init(rawValue: 1 << 0)
        public static let end: CleanPhase   = .init(rawValue: 1 << 1)
        
        
        public static let none: CleanPhase  = []
        public static let both: CleanPhase  = [.begin, .end]

    }
}


public func withTestBundle(client: KurrentDBClient, cleanPhase: TestBundle.CleanPhase = .both, action: (_ bundle: TestBundle) async throws -> Void ) async throws {
    let bundle = TestBundle(client: client, cleanPhase: cleanPhase)
    do{
        try await action(bundle)
    }catch{
        print("Test failed with error: \(error)")
    }
    
    if cleanPhase.contains(.end) {
        await bundle.clearStreams()
    }
}


