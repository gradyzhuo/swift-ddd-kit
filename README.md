# DDDKit

#### Swift Package Manager

The Swift Package Manager is the preferred way to get EventStoreDB. Simply add the package dependency to your Package.swift:

```swift
dependencies: [
  .package(url: "git@github.com:Mendesky/DDDKit.git", from: "0.2.0")
]
```
...and depend on "EventStoreDB" in the necessary targets:

```swift
.target(
  name: ...,
  dependencies: [.product(name: "DDDKit", package: "DDDKit")]
]
```

### import 
```
import DDDCore
import EventSourcing
import KurrentSupport
```


### event
```
struct TestAggregateRootCreated: DomainEvent {
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
}

struct TestAggregateRootDeleted: DeletedEvent {
    var id: UUID = .init()

    var occurred: Date = .now

    let aggregateRootId: String
    let aggregateRoot2Id: String

    init(aggregateRootId: String, aggregateRoot2Id: String) {
        self.aggregateRootId = aggregateRootId
        self.aggregateRoot2Id = aggregateRoot2Id
    }

}

```

### AggregateRoot
```
class TestAggregateRoot: AggregateRoot {
    typealias CreatedEventType = TestAggregateRootCreated

    typealias DeletedEventType = TestAggregateRootDeleted

    typealias ID = String
    var id: String
    
    var metadata: DDDCore.AggregateRootMetadata = .init()

    init(id: String){
        self.id = id
        
        let event = TestAggregateRootCreated(aggregateRootId: id)
        try? self.apply(event: event)
    }

    required convenience init?(first firstEvent: TestAggregateRootCreated, other events: [any DDDCore.DomainEvent]) throws {
        self.init(id: firstEvent.aggregateRootId)
        try self.apply(events: events)
    }

    func when(happened event: some DDDCore.DomainEvent) throws {
        
    }

    func markAsDelete() throws {
        let deletedEvent = DeletedEventType(aggregateRootId: self.id, aggregateRoot2Id: "aggregate2Id")
        try apply(event: deletedEvent)
    }
}
```

### Event Mapper
```
struct Mapper: EventTypeMapper {
    func mapping(eventData: EventStoreDB.RecordedEvent) throws -> (any DDDCore.DomainEvent)? {
        return switch eventData.eventType {
        case "TestAggregateRootCreated":
            try eventData.decode(to: TestAggregateRootCreated.self)
        case "TestAggregateRootDeleted":
            try eventData.decode(to: TestAggregateRootDeleted.self)
        default:
            nil
        }
    }
    
}
```

### Repository
```
class TestRepository: EventSourcingRepository {
    typealias AggregateRootType = TestAggregateRoot
    typealias StorageCoordinator = KurrentStorageCoordinator<TestAggregateRoot>

    var coordinator: StorageCoordinator

    init(client: EventStoreDBClient) {
        self.coordinator = .init(client: client, eventMapper: Mapper())
    }
}

```

### save aggregateRoot and find
```
let testId = "idForTesting"
let aggregateRoot = TestAggregateRoot(id: testId)
let repository = try TestRepository()

try await repository.save(aggregateRoot: aggregateRoot)

let finded = try await repository.find(byId: testId)
XCTAssertNotNil(finded)
```

### save aggregateRoot and deleted, should find a nil result
```
let testId = "idForTesting"
let aggregateRoot = TestAggregateRoot(id: testId)
let repository = try TestRepository()

try await repository.save(aggregateRoot: aggregateRoot)

try await repository.delete(byId: testId)

let finded = try await repository.find(byId: testId)
XCTAssertNil(finded)
```

### save aggregateRoot and deleted, should find a nil result with a `forcly` argument. 
```
let testId = "idForTesting"
let aggregateRoot = TestAggregateRoot(id: testId)
let repository = try TestRepository()

try await repository.save(aggregateRoot: aggregateRoot)

try await repository.delete(byId: testId)

let finded = try await repository.find(byId: testId, forcly: true)
XCTAssertNotNil(finded)
```

### Delete Stream from AggregateRootType and id
```swift
//remeber import 
import TestUtilities

var client: EventStoreDBClient = .init(settings: .localhost())
await client.clearStreams(aggregateRootType: TestAggregateRoot.self, id: "idForTesting") { error in
    print(error)
}

//or
await client.clearStreams(aggregateRootType: TestAggregateRoot.self, id: "idForTesting")
```

## Plugin

Prepare `event-generator-config.yaml` in target folder.
```yaml
accessModifier: { internal, package, public }
dependencies: [optional]
```

e.g.
```yaml
accessModifier: package
dependencies: 
  - General
  - Utility
```


### DomainEventGeneratorPlugin

The `DomainEventGeneratorPlugin` help generate swift file of domain events by `event.yaml` in target.


Add `DomainEventGeneratorPlugin` to target configuration in `Package.swift`.
```swift
.target(
    name: "MyExecutable",
    dependencies: [
        .product(name: "DDDKit", package: "DDDKit"),
        ... //other dependencies
	],
    plugins: [
        .plugin(name: "DomainEventGeneratorPlugin", package: "DDDKit"),
        ... //other plugin
    ]
),

```

Prepare `event.yaml` in target folder.
```yaml
{event_name}:
  kind: [optional][default: domainEvent] { createdEvent, deletedEvent, domainEvent} 
  migration: [Optional]
    eventType: { event_name_ migration_to }
  aggregateRootId:
    alias: { concrete_name }
  properties:
    - name: { property_name }
      type: { String, Int, Float, Double, Date, UUID, Bool, or custom class }
```
e.g.
```yaml
NewLetterContentEdited:
  migration:
    eventType: LetterContentEdited
  aggregateRootId:
    alias: quotationId
  properties:
    - name: letterId
      type: String
    - name: content
      type: String
    - name: userId
      type: String

QuotationDeleted:
  kind: deletedEvent
  migration:
    eventType: LetterContentEdited
  aggregateRootId:
    alias: quotationId
  properties:
    - name: letterId
      type: String
    - name: content
      type: String
    - name: userId
      type: String
```

### ProjectionModelGeneratorPlugin

The `ProjectionModelGeneratorPlugin` help generate swift file of projection model and event mapper by `projection-model.yaml` in target.

Add `ProjectionModelGeneratorPlugin ` to target configuration in `Package.swift`.

```swift
.target(
    name: "MyExecutable",
    dependencies: [
        .product(name: "DDDKit", package: "DDDKit"),
        ... //other dependencies
	],
    plugins: [
        .plugin(name: "ProjectionModelGeneratorPlugin", package: "DDDKit"),
        ... //other plugin
    ]
),

```

Prepare `projection-model.yaml` in target folder.

```yaml
{model_name}:
 model: {aggregateRoot, readModel}
 createdEvent: { event_name implemented by DomainEvent }
 deletedEvent: { event_name implemented  by DeletedEvent }
 events: [readModel is required ]
  - { event_name implemented by DomainEvent }
```

e.g. 
```yaml
Quotation:
 model: aggregateRoot
 createdEvent: QuotationCreated
 deletedEvent: QuotationDeleted
  
GetQuotationReadModel:
 model: readModel
 createdEvent: QuotationCreated
 events:
  - xxxEdited
  - xxxEdited
```
