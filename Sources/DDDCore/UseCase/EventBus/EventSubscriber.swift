//
//  EventSubscriber.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/5/8.
//

public protocol EventSubscriber{
    associatedtype Event: DomainEvent
    var eventName: String { get }
    var handle: (Event) async throws -> Void { get }
}
