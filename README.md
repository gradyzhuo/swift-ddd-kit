# DDDKit


```
struct TestCreated: DomainEvent {
    var aggregateId: String
    var eventType: String
    var occurred: Date
    var id: String
}


final class Test: AggregateRoot {
    typealias FirstEvent = TestCreated
    var id: String
    
    var metadata: AggregateRootMetadata<Test> = .init()
    
    init(id: String){
        self.id = id
    }

    required convenience init?(first firstEvent: TestCreated, other events: [any DomainEvent]) throws {
        self.init(id: firstEvent.aggregateId)
        
        for event in events{
            self.apply(event: event)
        }
        try self.clearAllDomainEvents()
    }
    
    func add(domainEvent: some DomainEvent) throws {
        
    }
    
    func when(happened event: some DomainEvent) throws {
        
    }
}
```
