# `withUnitOfWork` — 跨 usecase、跨 aggregate 的原子寫入 — 設計

日期：2026-11-02（rev 8：依 dealwith-unitofwork session 在 KurrentDB 26.1 / 26.2 的實測更正 §9——tombstoned 在 `appendRecords` 本來就是 consistency violation（`actualState == -6`），交接裡的「第二個缺陷」不在本設計走的路徑；soft-delete 重建的 revision、record id 冪等、`$schema.*` 鍵都已確認，spike（實作計畫 Task 2）取消；tombstone 與衝突同時出現時 DDDKit 自訂 tombstone 優先；in-memory 模擬整批重送的冪等；floor 定為 swift-kurrentdb 2.6.1，2026-11-03 已出版；rev 7：依三份獨立審查修正——swift-kurrentdb 2.6.0 的兩個已知缺陷改為前置修正並提高 floor、作用域在 body 返回後關閉（逃逸的 `Task` 與 hook 內的 `save` 不再靜默）、commit 與 hook 在 TaskLocal 之外執行、revision 預測不符改為 log 不丟錯、自動毒化只包 store 呼叫、暫存 revision 由 expectedRevision 推、`StreamConflict` 手寫 `==`、相容性改標 SB；rev 6：禁止巢狀、repository 丟出的錯自動毒化作用域、區塊內不 catch 的規則；rev 5：`work` 物件定案為 `id`、`isFailed`、`fail(_:)`、`onCommitted(_:)`；rev 4：依 builder check 改 client identity 由 conformer 提供、巢狀失敗毒化作用域、讀取合併範圍；rev 3：整份改寫。rev 1–2 的「usecase 自己呼叫 `uow.stage()`」被使用者否決，改成作用域式、既有 usecase 原封不動參與；命名依使用者指定為 `withUnitOfWork { work in … }`）
前置：`2026-10-23-eventstore-contract-design.md`（A 份）已在 1.4.0 落地，本份沿用其 revision、`version: nil`、`commitConflict`、`streamPurged` 語意。
版本：1.5.0。`EventStoreClient` 多兩個需求（`identity` 無預設、`appendAtomically` 有 deprecated 預設）、`EventStoreClientError` 多兩個 case；自訂 conformer 與對 `EventStoreClientError` 做 exhaustive `switch` 的程式要改，migration 文件標 SB（§8）。其餘公開簽名不變。
前次討論：kcap session 924c54ac（2026-08）拍板「用 KurrentDB v2 AppendRecords、metadata 維持 ambient、revision 用 stream name 對回、錯誤包成 `DDDError`」；session 78d752e7 把兩個未決問題留成 loose end（1c8a0d3d、fe9ce498）。本份保留那些底層結論，但上層 API 整個換掉。

## 1. 問題

一個操作有時要同時動到兩個 aggregate（例如建一個 QuotingCase 再建它的 BillingAccount），兩條 stream 要一起成功或一起失敗。現在只有 `EventSourcingRepository.save`，一次寫一條 stream；先存 A 再存 B，B 失敗後 A 已經落地，沒有補償機制，也不想要補償機制。

使用者的真正需求（2026-11-01 釐清）：**既有的 usecase 要能直接拿來組合**。每個 usecase 都注入了 repository、在 `execute` 裡自己 `repository.save`。組合它們時，這些 `save` 不能各自立刻落地，而要被收起來、最後一起原子寫入；而且後一個 usecase 要看得到前一個 usecase 做的修改。下游的 composition root 把 repository 與 service 在啟動時建一次、handler 長期持有，這個結構不能被迫改成每個請求重建。

KurrentDB 26.1+ 的 v2 `AppendRecords`（swift-kurrentdb 2.1.0 起 `client.multiStreams.appendRecords(events:checks:)`，DDDKit 的 floor 2.6.0 已包含；但 2.6.0 的 `EventRecord(eventData:)` 會把 customMetadata 靜默清空，見 §9，floor 要提高到 2.6.1）提供跨 stream 原子 append，並在寫入前一次評估所有 stream 的 expected revision。

## 2. 目標 / 非目標 / 反目標

目標
- `withUnitOfWork { work in … }` 作用域：區塊內所有 `repository.save` 的事件被收集，區塊正常結束時一次原子寫入；區塊丟錯則什麼都不寫。
- 既有 usecase、repository、生成碼一行都不改就能參與。composition root 不改。
- 作用域內的 `repository.find` 看得到同一作用域內已 save 但未 commit 的事件（read-your-writes）。
- 作用域外的行為與今天完全相同。
- 不需要真 server 也能單元測試（`InMemoryEventStoreClient` 跟著支援）。
- 語意與 A 份契約一致：`version: nil` 要求 stream 不存在、衝突丟 `commitConflict`、purged stream 丟 `streamPurged`。

非目標
- 給 usecase 呼叫的 `stage()` / `commit()` API。使用者明確不要。
- `InMemoryEventStore`、`PersistentEventStore` 參與作用域（1.5 不做；它們在作用域內 `save` 會丟錯，見 §5.2）。
- Dynamic Consistency Boundary 的「只檢查不寫入」。seam 的形狀不排除以後加。
- 跨兩個 KurrentDB cluster 的原子寫入（做不到；作用域內出現第二個 client 直接丟錯）。
- 補償 / saga。
- 改動 `Usecase`、`EventStore`、`EventSourcingRepository` 的公開簽名。

反目標
- 逼下游把 service 改成每請求重建，或在 repository / service 上加泛型參數來「證明」它在作用域裡（曾評估過，被使用者以複雜化否決）。
- 在作用域裡對不能參與的 store 靜默直接寫入。要嘛收進去，要嘛丟錯。

## 3. 保留的底層結論（session 924c54ac）

1. 多 stream 用 KurrentDB v2 `AppendRecords` 一次寫入。
2. Metadata 維持 ambient（`EventMetadataContext`）。**本份改為**：每次 `save` 讀到的那份 metadata 跟著它自己的事件走，不再是「一次 commit 一份」。
3. Revision 用 stream name 對回。
4. 錯誤包成 `DDDError`：`commitConflict`（501）、`streamPurged`（502）；其他錯誤原樣拋出。
5. 單 stream 與多 stream 共用同一段「DomainEvent → EventData」編碼（既有 `KurrentStorageCoordinator.append` 的編碼抽成 package 函式）。

## 4. 未決問題的答案

### 4.1 多個 usecase service 共用一個 UnitOfWork（loose end 1c8a0d3d）

成立，而且這正是本設計的主用法：composition root 不變，handler 把要一起成功的 usecase 呼叫放進同一個 `withUnitOfWork` 區塊。service 不知道自己在作用域裡。

### 4.2 一個 UnitOfWork 只綁一種 Metadata（loose end fe9ce498）

問題消失。作用域不碰 metadata；metadata 由各 `KurrentStorageCoordinator<_, Metadata>` 在 `save` 時照舊編碼進該批事件。同一作用域裡可以有不同 Metadata 型別的 repository。

## 5. 使用方式（先看這節）

**5.1 既有單一 usecase 的 handler：不改**

```swift
func createQuotingCase(_ input: Operations.createQuotingCase.Input) async throws -> Output {
    let output = try await createQuotingCaseService.execute(input: .init(...))
    return .created(output)
}
```

沒有作用域，`repository.save` 跟今天一樣直接寫進 KurrentDB。

**5.2 組合兩個 usecase**

```swift
func createQuotingCaseWithContact(_ input: Input) async throws -> Output {
    let output = try await withUnitOfWork { _ in
        let quoting = try await createQuotingCaseService.execute(input: .init(operatorId: op, name: ...))
        try await addContactService.execute(input: .init(operatorId: op, quotingCaseId: quoting.id, contact: ...))
        return quoting
    }
    return .created(output)
}
```

兩個 service 是啟動時建好的同一個實例。`addContactService` 內部的 `repository.find(byId: quoting.id)` 找得到剛建立、還沒落地的 QuotingCase；它 save 的事件併進同一條 stream 的同一個 batch。

**5.3 跨兩個 aggregate**

```swift
try await withUnitOfWork { _ in
    let quoting = try await createQuotingCaseService.execute(input: a)          // QuotingCase-xxx
    try await openBillingAccountService.execute(input: .init(for: quoting.id)) // BillingAccount-yyy
}
```

兩條 stream、一次 `appendRecords`。任一條 expected revision 不符整批退回，丟 `commitConflict`，`error.commitConflicts` 列出每一條。

**5.4 測試**

```swift
let client = InMemoryEventStoreClient()
let repository = QuotingCaseRepository(coordinator: .init(client: client, eventMapper: ...))
let service = CreateQuotingCaseService(repository: repository)
try await withUnitOfWork { _ in try await service.execute(input: ...) }   // 不用 server
```

**5.5 Metadata**

每個 usecase 自己 `EventMetadataContext<M>.withValue` 設的那份，跟著它自己的事件走；`withUnitOfWork` 外不必再設一次。

**5.6 區塊參數 `work`**

```swift
try await withUnitOfWork { work in
    let quoting = try await createQuotingCaseService.execute(input: a)
    try await openBillingAccountService.execute(input: .init(for: quoting.id))
    try work.onCommitted { try await notifier.send(.quotingCreated(quoting.id)) }   // 落地後才做
    return quoting
}
```

第一版的 `UnitOfWork` 提供四個成員（使用者 2026-11-02 選定）：

| 成員 | 用途 |
|---|---|
| `id: UUID` | 作用域識別碼，給 log 串接；每個作用域不同。 |
| `isFailed: Bool` | 有人呼叫過 `fail(_:)`，包括框架自己（§6.2：參與的 repository 丟出的錯）。 |
| `fail(_ error: any Error)` | 不丟錯也能把作用域標成 failed；body 可以繼續執行、正常返回，最外層結束時不 commit、丟 `operationNotAllow`，`userInfos["cause"]` 是第一個原因。給「要回一個正常的失敗 Output，同時丟棄寫入」的 handler。作用域已結束（body 返回之後）再呼叫 → 丟 `operationNotAllow`（§6.2 的關閉規則），所以簽名是 `throws`。 |
| `onCommitted(_ action: @escaping @Sendable () async throws -> Void)` | 登記 commit 成功後才做的副作用（EventBus、通知、外部 API）。依登記順序、逐一 await、在 `withUnitOfWork` 返回前跑完。body 丟錯、作用域 failed、commit 失敗 → 一個都不跑。沒有 batch 的作用域視為 commit 成功，hook 照跑。hook 丟錯 → 後面的不跑、錯誤從 `withUnitOfWork` 丟出，**但 commit 已經落地**；文件要講，副作用自己在 hook 裡 catch。hook 在 TaskLocal 之外執行：hook 內 `UnitOfWork.current == nil`，hook 內的 `repository.save` 直接寫入 server、不在原子範圍內。作用域已結束再登記 → 丟 `operationNotAllow`，所以簽名是 `throws`。 |

usecase 要在作用域內外都能用的寫法：`if let work = UnitOfWork.current { try work.onCommitted { … } } else { … 立刻做 }`。名字與 `KurrentProjection.onCommitted` 一致，語意相同（成功後、依序、不重疊）。

**區塊內的規則（文件要用同樣的字寫）**：
- 不巢狀。`withUnitOfWork` 在已有作用域時丟錯（§6.2）。usecase 不呼叫 `withUnitOfWork`，它是 handler 層的東西；兩個 handler 要共用邏輯，抽成不包作用域的函式，各自包。
- 不在區塊內 `do/catch` usecase 的錯誤。要讓區塊回一個正常的失敗 Output，用 `work.fail(error)` 再 return。真正會出事的只有「usecase 先 save 再丟錯、然後被 catch」；框架能看到的錯（經過 repository 的）會自動 `fail`（§6.2），看不到的就靠這條規則。
- 不在區塊內用 `Task { … }` 把 `save` 丟到背景。非 detached 的 `Task` 會繼承作用域；它若在區塊結束後才跑到 `save`，會撞到已關閉的作用域而丟 `operationNotAllow`（§6.2），不會靜默寫入、也不會進一個已 commit 的批次。要在作用域內做的事都 await 完再返回。
- usecase 在 `save` 之後直接 `EventBus.publish` 的，在作用域內會在 commit 前就發佈。要在作用域內外都正確，改成 `if let work = UnitOfWork.current { try work.onCommitted { … } } else { … 立刻做 }`；migration 文件要列。
- 同一作用域內用 `async let` / `TaskGroup` 並行跑**不同** aggregate 的 usecase 可以；並行動同一個 aggregate 不支援：兩個 task 都在任一方 `save` 之前 `find` 到它時，第二個 `save` 丟 `commitConflict`（§6.3）；其他交錯下結果取決於排程（rev 8 實作補註，2026-11-04）。

不提供：提前 `commit()` / `rollback()`（與「區塊結束才決定」衝突）、跳出作用域直接寫的逃生口（混用問題會回來）、暫存內容的查詢（測試從 client 斷言）。`withUnitOfWork` 目前沒有其他參數；要加時放在 trailing closure 前面並給預設值。

## 6. 設計

### 6.1 分層

| 層 | 內容 |
|---|---|
| EventSourcing（核心） | `withUnitOfWork`、`UnitOfWork`（作用域物件，TaskLocal）、`UnitOfWorkParticipant`（store 的標記協定）、`UnitOfWorkBackend`（commit 的抽象）、`EventSourcingRepository.save/purge` 的守門 |
| KurrentSupport | `KurrentStorageCoordinator` 遵循 `UnitOfWorkParticipant`、`KurrentUnitOfWorkBackend`（package）、`EventStoreClient.appendAtomically` 與其 DTO、`LiveEventStoreClient` 實作 |
| KurrentSupportInMemory | `InMemoryEventStoreClient.appendAtomically` |
| DDDCore | `DDDError.commitConflict(conflicts:)` 與 `commitConflicts` |

核心層只知道「有一個作用域，裡面恰好有一個 backend，結束時 commit」。怎麼暫存、怎麼寫，全在 KurrentSupport。

### 6.2 核心層 API（EventSourcing）

```swift
/// 區塊內所有參與的 store 的寫入被收集，區塊正常返回時一次 commit；丟錯則丟棄並重拋。
/// 不可巢狀：已在作用域內時丟 `DDDError.operationNotAllow(operation: "withUnitOfWork", reason: "already inside unit of work <id>")`，
/// 外層作用域不受影響。
public func withUnitOfWork<R>(_ body: (UnitOfWork) async throws -> R) async throws -> R

public final class UnitOfWork: Sendable {
    /// 目前 task 所在的作用域；不在作用域裡是 nil。
    public static var current: UnitOfWork? { get }   // TaskLocal

    /// 作用域識別碼。
    public let id: UUID
    /// 呼叫過 `fail(_:)` 之後為 true（使用者或框架都可能呼叫）；結束時不 commit，改丟錯。
    public var isFailed: Bool { get }
    /// 不丟錯也能把作用域標成 failed；保留第一個原因。作用域已結束 → 丟 `operationNotAllow`。
    public func fail(_ error: any Error) throws
    /// commit 成功後依登記順序逐一執行；見 §5.6。作用域已結束 → 丟 `operationNotAllow`。
    public func onCommitted(_ action: @escaping @Sendable () async throws -> Void) throws

    /// 給 store 實作者：取得（或建立）這個作用域的 backend。
    /// 一個作用域只能有一個 backend：已有的 backend 型別或 identity 不同 → 丟 `DDDError.operationNotAllow`。
    /// 作用域已結束 → 丟 `operationNotAllow`。查、建（`make()`）、存在同一次 `withLock` 內完成。
    public func backend<B: UnitOfWorkBackend>(_ type: B.Type, identity: ObjectIdentifier, make: () -> B) throws -> B
}

/// 收集寫入、在作用域結束時一次送出的東西。由 store 實作提供。
public protocol UnitOfWorkBackend: AnyObject, Sendable {
    func commit() async throws
}

/// 標記：這個 `EventStore` 在作用域內會把寫入交給 backend，而不是直接寫。
public protocol UnitOfWorkParticipant {}
```

`body` 不是 `@Sendable`，與 `EventMetadataContext.withValue` 一致。`UnitOfWork` 的內部狀態（backend 參考、failed 旗標與原因、hook 佇列）用 `Mutex` 保護；hook 必須 `@Sendable`，因為它跨越 `Mutex` 存放。`withBackend(_:identity:make:_:)` 的「查、建、存」含 `make()` 在同一次 `withLock` 內完成，兩個 child task 同時第一次 `save` 只會建一個 backend。

`EventSourcingRepository` 的預設實作加兩件事：
- 守門：`save` 與 `purge` 在 `UnitOfWork.current != nil` 且 `Store` 不是 `UnitOfWorkParticipant` 時丟 `DDDError.operationNotAllow(operation: "save", reason: "<Store> cannot take part in a unit of work")`。`find` 不守門（讀沒有副作用）。這讓 `InMemoryEventStore`、`PersistentEventStore` 在作用域內不會靜默直接寫。
- 自動毒化：`find`、`save`、`delete`、`purge` 的預設實作在作用域內，把 **store 呼叫**（`store.fetchEvents`、`store.append`、`store.purge`）丟出的錯誤與守門的 `operationNotAllow` 先 `UnitOfWork.current?.fail(error)` 再重拋（含 store 丟上來的 `commitConflict`、`streamPurged`、coordinator 內 mapper 的解碼錯誤）。repository 自己丟的 `aggregateNotFound`（`delete` 找不到）與 aggregate 的 `markDelete` 錯誤不毒化：沒有任何寫入發生，usecase 把它們當冪等處理很常見。所以框架看得到的寫入失敗，就算呼叫端 catch 掉，結束時也不會 commit。覆寫了這些方法的自訂 repository 不在此列，文件要講。作用域已關閉時 `fail` 本身會丟錯，包裝函式忽略它、重拋原本的錯。

作用域結束（執行順序）：
- `$current.withValue` 只包 `body`。body 返回或丟錯後 TaskLocal 立刻解開，作用域進入**已關閉**狀態；之後的 failed 判定、commit、hook 都在 TaskLocal 之外執行，hook 內 `UnitOfWork.current == nil`。
- 已關閉的作用域：`withBackend(_:identity:make:_:)`、`fail(_:)`、`onCommitted(_:)` 一律丟 `DDDError.operationNotAllow(operation: "<該方法>", reason: "unit of work <id> already ended")`。這擋住區塊內用 `Task { }` 逃逸、在區塊結束後才 `save` 的情況：那個 task 的 `UnitOfWork.current` 仍指向這個已關閉的作用域，不會靜默直寫、也不會進一個已 commit 的 batch。`current` 不因關閉而變 nil，否則逃逸的 save 會直接落地。
- `body` 正常返回且 `isFailed == false` → 若有 backend 就 `commit()`。commit 丟 `commitConflict` / `streamPurged` → 重拋，backend 保證什麼都沒寫；commit 丟其他錯（transport、`atomicAppendUnsupported`、server 不支援 AppendRecords）→ 重拋，**不保證**沒寫（回應在 server commit 後遺失、client 內建的 node-failure 重送都可能已落地），文件寫明「重跑整個區塊前先讀取」。commit 成功（含沒有 backend）→ 依序執行 `onCommitted` 登記的 hook，再返回 body 的值。
- `body` 正常返回但 `isFailed == true` → 不 commit、不跑 hook，丟 `DDDError.operationNotAllow(operation: "commit", reason: "unit of work failed")`，附第一個原因在 `userInfos["cause"]`。
- `body` 丟錯（含 `CancellationError`）→ 不 commit、不跑 hook，重拋。

不巢狀：`withUnitOfWork` 在 `UnitOfWork.current != nil` 時直接丟 `operationNotAllow`，不進 body、不碰外層作用域。之後要開放是放寬，不破壞；先允許再禁止會破壞，所以第一版先禁。

### 6.3 `KurrentStorageCoordinator` 在作用域內的行為

作用域外（`UnitOfWork.current == nil`）：與今天完全相同。

作用域內：
- 第一次碰到作用域時向 `UnitOfWork.current.backend(KurrentUnitOfWorkBackend.self, identity: client.identity, make:)` 取得 backend。`identity` 是 `EventStoreClient` 的新需求（§6.5）：`LiveEventStoreClient` 回它包的 `KurrentDBClient` 的 `ObjectIdentifier`，所以下游用 `convenience init(client: KurrentDBClient, …)` 各自建的 coordinator（每個包一個新的 `LiveEventStoreClient`）只要底下是同一個 `KurrentDBClient` 就拿到同一個 backend，composition root 不用改。identity 不同（兩個 cluster）→ `operationNotAllow`。backend 用第一個登記的 client 送 commit；identity 相同代表它們連的是同一個 `KurrentDBClient`，用哪一個都一樣。identity 是實例不是 cluster：兩個各自 `KurrentDBPool.borrow()`、連同一個 cluster 的 `KurrentDBClient` 在作用域內也算不同 → `operationNotAllow`；設計上接受，migration 文件要寫。coordinator 每次呼叫都向 `UnitOfWork.current` 取 backend，不在 coordinator 上快取（作用域每個請求不同）。
- `append(events:byId:version:metadata:)`：
  1. 與今天一樣：空事件早退、`version > Int64.max` 讀 stream 後丟 `commitConflict`、metadata 編碼、事件編碼成 `[EventData]`（共用 package 函式）。
  2. 多一個檢查：每個 `EventData` 能轉成 v2 的 `EventRecord`（`try EventRecord(eventData:)` 不丟錯）。v2 wire 沒有 raw bytes 的 metadata 欄位，`customMetadata` 要走訪成 protobuf `properties`；swift-kurrentdb 2.6.1（§9）在 metadata 不是 JSON 物件時丟 `DecodingError`（2.6.0 是靜默回空，這就是原本「JSON 物件檢查」守錯層的原因）。NaN / ±infinity 到不了這個檢查：coordinator 編 metadata 的 `JSONEncoder` 先丟 `EncodingError`，作用域內外相同；超出 ±2^53 的整數，包括超出 64 位元的（例如 `Decimal`），**不會被拒絕**，會以最接近的 Double 送出（§9，rev 8, 2026-11-04 implementation finding）。所以這個檢查實際上只拒絕不是 JSON 物件的 metadata；payload 在檢查前先編碼一次，編不出來就原樣丟它的 `EncodingError`，不算 metadata 的錯。每一位都重要的大整數要以字串存，文件寫明。轉換丟錯 → `operationNotAllow(operation: "save", reason: "Metadata cannot be carried by AppendRecords: <error>")`，在 `save` 時就失敗，不等到 commit。metadata 為 nil 不檢查。作用域外不檢查（行為不變）。單 stream 的作用域最後走 v1 不需要這個轉換，但 `save` 時不知道最後有幾條 stream，所以一律檢查。
  3. `backend.stage(id:stream:category:expectedRevision:events:)` 回**預測的** tail revision：`.noStream` → `count - 1`；`.at(n)` → `n + count`。Repository 拿它 `update(version:)`、清事件，跟今天一樣。
  4. 同一條 stream 第二次 `stage`：expectedRevision 必須等於上一次預測的 tail，否則 backend 丟 `commitConflict(id:expected:actual: 預測 tail)`；相符就把事件接到同一個 batch 後面，batch 的 expectedRevision 維持第一次的值。
- `fetchEvents(byId:)` / `fetchEvents(byId:afterRevision:)`：先照今天從 client 讀；再向 backend 取這條 stream 已暫存的 `[EventData]`，包成 `RecordedEventLike`（revision 由該 batch 第一次的 `expectedRevision` 推：`.noStream` → 從 0 起，`.at(n)` → 從 n+1 起；不用 server 讀回的最後一筆推，因為 mapper 跳過的記錄與 `afterRevision` 的空視窗都會讓那個數字不是 tail；`streamName`、`customMetadata` 照填），跟 server 來的 records 一起過同一個 `eventMapper`。所以作用域內讀到的事件，metadata 填法與真實讀取相同。client 回 `streamNotFound` 但有暫存 → 只回暫存的。`afterRevision` 版本的過濾套用在合併後的全部記錄上；有暫存事件時 `latestRevision` 取暫存的最後一筆。
  - 合併發生在 `fetchEvents`，所以**所有**透過這個 coordinator 讀的人都看得到暫存事件，包括在作用域內同步呼叫的 `EventSourcingProjector`。read model 的 snapshot 寫入本來就不在 unit of work 裡（另一個 store，不原子）；作用域內同步跑 projector 會把未 commit 的事件折進 snapshot，commit 失敗時 snapshot 就超前了。文件要明講：projection 走 `KurrentProjection` 的訂閱 runner（它們在另一個 task、作用域外），不要在作用域內同步跑 projector。不為 projector 另開一條「不看暫存」的讀取路徑。
- 同一作用域內的並行：不同 stream 的 `save` 可並行（backend 的狀態在 `Mutex` 內）；同一 stream 並行 `find`+`save` 時，第二個 `stage` 的 expectedRevision 對不上預測 tail → `commitConflict`，確定性失敗、自動毒化。文件寫明。
- `purge(byId:)`：丟 `operationNotAllow(operation: "purge", reason: "not allowed inside a unit of work")`。

### 6.4 `KurrentUnitOfWorkBackend`（KurrentSupport，package）

持有 `client` 與依 stream name 索引的 batch（`id`、`stream`、`category`、第一次的 `expectedRevision`、`[EventData]`、預測 tail），用 `Mutex` 保護。`commit()`：

- 0 個 batch → 什麼都不做。
- **1 個 batch → 走既有的單 stream `client.append(events:toStream:category:expectedRevision:)`（v1）**。行為、錯誤對應、「重送同 id 回原 revision」的去重語意與今天的 `repository.save` 完全相同，單一 usecase 包在作用域裡不會換到另一條路。
- **2 個以上 → `client.appendAtomically(batches)`（v2）**。
- 成功後比對每條 stream 回傳的 revision 與預測 tail；不一致 → `logger.warning`，**不是錯誤**：server 回的才是真值，預測只是本地記帳（已實測：stream 曾被 v1 soft-delete（revision 0–2）再以 `.noStream` 重建時，server 回 revision 3，從舊尾端 +1 而不是 0，見 §9）；資料已落地、hook 照跑。repository 手上的 aggregate version 在這種情況會比 server 少，文件寫明「作用域結束後不要重用區塊內的 aggregate 實例」。（v1 的去重情況下回傳值也等於預測，因為去重只在事件已經正好在 expected 之後時發生。）
- 錯誤對應：`EventStoreClientError.wrongExpectedRevision(current:)` / `KurrentError.wrongExpectedVersion` → `commitConflict(id:expected:actual:)`；`EventStoreClientError.consistencyViolations(_:)` → `commitConflict(conflicts:)`（以 stream name 對回 `id`）；`KurrentError.resourceDeleted(resource:)` → `streamPurged(id:)`（以 resource 名對回 id）；`KurrentError.unsupportedFeature`（server 低於 26.1，client 在送出前就丟）→ `operationNotAllow(operation: "commit", reason: "server does not support AppendRecords (KurrentDB 26.1+)")`；`EventStoreClientError.atomicAppendUnsupported`（舊 conformer）與其他錯誤原樣拋出。
- commit 只會被呼叫一次（作用域結束）。`commit()` 一進入就標記 committed；之後 `stage` / `stagedEvents` 丟 `operationNotAllow(operation: "stage", reason: "unit of work already committed")`，是 §6.2 關閉規則之下的第二道防線。`stage` 收到空事件、或 `.any` / `.streamExists`（coordinator 永遠不會產生）也丟 `operationNotAllow`。

### 6.5 `EventStoreClient` seam 新增多 stream append

```swift
public protocol EventStoreClient: Sendable {
    // 既有方法不變 …

    /// 底層連線的身分。同一個作用域裡只有 identity 相同的 client 能一起 commit。
    /// `LiveEventStoreClient` 回它包的 `KurrentDBClient` 的 `ObjectIdentifier`；
    /// `InMemoryEventStoreClient` 是 actor，宣告 `nonisolated var identity` 回 `ObjectIdentifier(self)`。沒有預設實作：兩個不同 cluster 若被當成同一個，
    /// 事件會寫到錯的 cluster，這不能靠猜。
    var identity: ObjectIdentifier { get }

    /// 一次原子寫入多條 stream。所有 expectedRevision 在寫入前一起檢查；任一不符則整批不寫，
    /// 丟 `EventStoreClientError.consistencyViolations`，列出所有不符的 stream。
    /// `batches` 至少兩條、stream 不重複（呼叫端負責）。回傳每條 stream 的新 revision，順序不保證。
    func appendAtomically(_ batches: [StreamBatch]) async throws -> [StreamBatchResult]
}

extension EventStoreClient {
    @available(*, deprecated, message: "Implement or forward appendAtomically(_:); withUnitOfWork needs it for more than one stream.")
    public func appendAtomically(_ batches: [StreamBatch]) async throws -> [StreamBatchResult] {
        throw EventStoreClientError.atomicAppendUnsupported
    }
}

public struct StreamBatch: Sendable {
    public let stream: String
    public let category: String            // 與單 stream append 的 category 意義相同，兩個實作都不拿它做路由
    public let expectedRevision: StreamRevision
    public let events: [EventData]          // 非空
}

public struct StreamBatchResult: Sendable {
    public let stream: String
    public let revision: UInt64
}

public struct StreamConflict: Sendable, Equatable {
    public let stream: String
    public let expected: StreamRevision
    public let current: UInt64?             // nil = stream 不存在
    // `StreamRevision` 不是 Equatable（swift-kurrentdb），`==` 手寫、逐 case 比對 `.any/.noStream/.streamExists/.at(n)`；
    // 不對 `StreamRevision` 加 retroactive conformance（上游之後加了會撞）。
    // `EventStoreClientError` 必須維持 Equatable：既有測試用 `#expect(throws: EventStoreClientError.tombstoneUnsupported)`。
}

public enum EventStoreClientError {
    // 既有 case 不變 …
    case consistencyViolations([StreamConflict])
    case atomicAppendUnsupported
}
```

`LiveEventStoreClient.appendAtomically`：
- 每個 `StreamBatch` 轉成 `StreamEvent(stream:records:expectedRevision:)`，records 用 `EventRecord(eventData:)`：id、eventType（→ `schema.name`）、payload、customMetadata（→ `properties`）都帶過去。2.6.0 的 `EventRecord(eventData:)` 會把 customMetadata 靜默清空（§9），所以 floor 提高到 2.6.1 之後才能實作；DDDKit 的 live test（§7）再用混合型別的 metadata 證明 round-trip。
- 呼叫 `client.multiStreams.appendRecords(events:)`；不傳額外 `checks`，由 swift-kurrentdb 的 `resolvedChecks` 從每個非 `.any` 的 expectedRevision 推出檢查。
- `KurrentError.consistencyViolation(violations:)` → `consistencyViolations`：`violation.stream` 對回 batch 取 `expected`；`actualState` 為 -1 時 `current = nil`，≥ 0 時轉 `UInt64`。tombstoned / soft-deleted 的 stream 也是以 violation 形式回來（實測 26.1、26.2，§9）：`actualState == -6` 是 tombstoned、`-5` 是 soft-deleted、`-1` 是不存在；server 把同一個 request 裡的 tombstoned 與純 revision 衝突一起列出、沒有優先序。DDDKit 自訂優先序：violations 中任一筆 `actualState == -6` → 丟 `KurrentError.resourceDeleted(resource: 該 stream)`（取 batch 順序第一條），不丟 `consistencyViolations`，backend 再轉 `streamPurged`；否則全部轉成 `StreamConflict`，`actualState < 0` 一律 `current = nil`（-5 的 soft-deleted stream 在 DDDKit 裡只會因為外部的 v1 delete 出現，對呼叫端就是「不在預期的 revision」）。in-memory 用同樣的規則。其他 `KurrentError` 原樣拋出。
- 回傳 `response.revisions` 轉成 `[StreamBatchResult]`（順序不保證，以 stream name 對回）。

`InMemoryEventStoreClient.appendAtomically`：
- 先全部檢查再全部寫：任一 stream 在 `tombstoned` → 丟 `KurrentError.resourceDeleted`（tombstone 先於衝突，與 live seam 的優先序一致）；收集所有 expectedRevision 不符的 batch，非空就丟 `consistencyViolations`，什麼都不寫。
- 全部通過後依 batch 順序寫入，每條 stream 的 revision 接續其尾端，`globalSequenceCounter` 連號，寫完再對每條 stream `deliverToSubscriptions`。
- 冪等重送：server 對同一組 record id 重送同一個 `appendRecords`（即使帶 `.noStream`）回同樣的 revision 與 position、不重複寫入（§9）。in-memory 只模擬「每條 batch 都是重送」的情況：先用既有的 `idempotentRevision(of:in:expected:)` 對每條 batch 判定，全部命中 → 回原 revision、什麼都不寫；部分命中不模擬（走一般檢查，會以 `consistencyViolations` 失敗）——server 在這種混合情況的行為沒有驗證過，in-memory 不替它發明語意。

### 6.6 `DDDError.commitConflict` 多筆衝突

既有 `commitConflict(id:expected:actual:)` 與 `error.commitConflict: CommitConflict?` 不動。新增 `commitConflict(conflicts: [CommitConflict])`（非空）與 `error.commitConflicts: [CommitConflict]`（單筆版本回 `[commitConflict]`，非 501 回 `[]`）。`code` 仍是 501。

## 7. 測試

- `EventSourcingTests`（核心，無 server）：
  - `withUnitOfWork` 巢狀 → 內層丟 `operationNotAllow`，外層照常 commit；`UnitOfWork.current` 在區塊內非 nil、區塊外 nil；body 丟錯時 backend 的 `commit` 沒被呼叫；body 正常返回時被呼叫一次。用一個測試用的 `UnitOfWorkBackend` 替身。
  - 第二個不同 identity 的 backend → `operationNotAllow`。
  - `work.fail(e)` 後正常返回 → 不 commit、丟 `operationNotAllow`，`cause == e`；第二次 `fail` 不覆蓋原因。
  - 自動毒化：作用域內 repository 的 `save` 丟錯（守門、或 store 的 `commitConflict`）被呼叫端 catch 後正常返回 → 不 commit，`cause` 是那個錯。
  - `onCommitted`：正常結束時依登記順序執行、在 `withUnitOfWork` 返回前跑完；body 丟錯 / failed / commit 丟錯時一個都不跑；某個 hook 丟錯 → 後面的不跑、錯誤丟出、backend 的 `commit` 已被呼叫過。
  - 兩個獨立的 `withUnitOfWork` 的 `id` 不同。`isFailed` 在 `fail` 前 false、後 true。backend 型別不同 → `operationNotAllow`。
  - 作用域關閉：區塊內逃逸的 `Task` 在 body 返回後再呼叫 `backend` / `fail` / `onCommitted` → `operationNotAllow`；hook 內 `UnitOfWork.current == nil`。
  - 取消：body 等一個測試持有的訊號時被 cancel → `CancellationError`、不 commit、不跑 hook（測試先 cancel 再放行訊號，避免 race）。
  - `InMemoryEventStore` 與 `PersistentEventStore` 為 store 的 repository 在作用域內 `save` / `purge` → `operationNotAllow`；`find` 正常。`delete` 找不到 aggregate 丟 `aggregateNotFound` 不毒化作用域。
- `KurrentSupportInMemoryTests`（`KurrentStorageCoordinator` + `InMemoryEventStoreClient`）：
  - 兩個不同 aggregate 型別、兩個 repository、同一個 client：作用域內各 save 一次 → 區塊結束後兩條 stream 各 revision 0 起；區塊內 client 沒收到任何 append。
  - 同一個 aggregate 在作用域內 save 兩次（第二次先 `find`）→ `find` 回含暫存事件的狀態、version 等於預測 tail；commit 後 stream 只有一個 batch、事件順序正確。stream 在 server 已有事件（作用域外先存）的版本也一次：`find` 的 version 等於 server tail + 暫存數。`fetchEvents(byId:afterRevision:)` 只回 revision 之後的，含暫存。
  - 單一 stream 的作用域 → client 收到的是單 stream `append`，不是 `appendAtomically`。
  - 其中一條 stream 已被別人寫 → `commitConflict`、`commitConflicts` 列出該 stream，另一條沒被寫。兩條都衝突 → 兩筆。
  - purged stream → `streamPurged`。
  - 作用域內 `purge` → `operationNotAllow`。
  - 區塊內逃逸的 `Task` 在區塊結束後 `save` → `operationNotAllow`，client 沒收到 append。hook 內的 `save` 直接寫入 client（不在原子批次）。
  - commit 回傳 revision 與預測不符（替身 client 加 offset）→ 不丟錯、只 log、hook 照跑。client 丟 `KurrentError.unsupportedFeature` → `operationNotAllow`。只有 deprecated 預設的舊 conformer 在作用域內寫兩條 stream → commit 丟 `atomicAppendUnsupported`。
  - 兩個 coordinator 用 `convenience init(client: KurrentDBClient)` 各自建、底下同一個 `KurrentDBClient`（live test）或同一個 `InMemoryEventStoreClient` 實例 → 同一個 backend；兩個不同的 `InMemoryEventStoreClient` 實例 → 第二個 save 丟 `operationNotAllow`。
  - metadata：兩個 usecase 各自 `withValue` 不同值 → 各自 stream 的事件帶各自的 `customMetadata`；作用域內 `find` 讀回的 `event.metadata` 有填。
  - `EventRecord(eventData:)` 轉不了的 Metadata（例如 RawRepresentable String enum，編成 JSON 純量）在作用域內 save → `operationNotAllow`；作用域外照寫。
  - `version > Int64.max` → `commitConflict`，client 沒收到 append。
  - body 丟錯 → client 沒收到任何 append，aggregate 的 version 與事件維持 save 之後的狀態（文件明寫：作用域丟錯後不要重用區塊內的 aggregate 實例）。
- `InMemoryEventStoreClient.appendAtomically` 自身：全檢查再全寫、`globalSequenceCounter` 連號、訂閱有收到。
- `KurrentLiveContractTests`（真 KurrentDB，CI `kurrent-live-contract` job）：
  - 兩個 repository 在作用域內各 save → 兩條 stream 都在；衝突列出所有不符 stream；tombstone 的 stream → `streamPurged`，tombstone 與純衝突同在一個 request 時也是 `streamPurged`（DDDKit 的優先序）；另外直接對 `LiveEventStoreClient.appendAtomically` 斷言 `actualState` 的編碼：不存在 → `current == nil`（-1）、tombstoned → `resourceDeleted`（-6）。
  - 讀回：作用域寫入的事件，經 `KurrentStorageCoordinator.fetchEvents` 與生成的 mapper 讀回後，`event.metadata`（混合型別：String、Int、Bool、Date、Optional nil、巢狀 struct）、eventType、payload 與寫入時一致（證明 v2 寫 v1 讀的 round-trip）。只比對解出來的 struct，不比原始 bytes：server 會在 custom metadata 多塞 `$schema.name`、`$schema.format` 兩個鍵（§9）。
  - 曾 v1 soft-delete 的 stream（先寫 revision 0–2 再 delete）在作用域內以 `.noStream` 重建 → commit 成功、hook 照跑、重新 `find` 回來的 version 是 3（舊尾端 +1，§9），commit 的 warning log 出現但不是錯誤。
  - 訂閱：`$ce-<Category>` persistent subscription 收得到作用域寫入的事件。
- 既有 `EventStoreContractTests` 不動（`EventStore` 協定沒變）。

## 8. 相容性

Source-breaking（migration 文件各給一個 SB 編號，格式同 1.3→1.4）：
- `EventStoreClient` 加 `identity` 需求，沒有預設實作：自訂 conformer 要補一行。repo 內受影響的有 `LiveEventStoreClient`、`InMemoryEventStoreClient` 與兩個測試替身（`ThrowingClient`、`LegacyClient`）。`LiveEventStoreClient` 維持 struct。
- `EventStoreClientError` 加 `consistencyViolations`、`atomicAppendUnsupported` 兩個 case：沒有 `default` 的 exhaustive `switch` 要補。
- swift-kurrentdb floor 提高到修正 §9 兩個缺陷的版本。

不破壞：
- `EventStoreClient.appendAtomically` 有 deprecated 預設實作，舊 conformer 繼續編譯；透過它們在作用域內寫兩條以上 stream 會在 commit 時丟 `atomicAppendUnsupported`。
- `KurrentStorageCoordinator`、`EventSourcingRepository`、`EventStore`、`Usecase` 的公開簽名不變。
- 作用域外的行為零改變。

行為差異要寫進 migration 文件：usecase 在 `save` 後直接 `EventBus.publish` 的（§5.6 規則）；兩個連同一 cluster 的 `KurrentDBClient` 實例在作用域內算不同 identity（§6.3）；守門只在 `EventSourcingRepository` 預設實作，直接呼叫 `store.append` 的程式在作用域內對非參與 store 仍會直寫；作用域結束後不要重用區塊內的 aggregate 實例（§6.4）。

## 9. 已知缺陷與實測事實

三份獨立審查（2026-11-02）在 swift-kurrentdb 2.6.0 提出兩個缺陷，交接給 dealwith-unitofwork session 處理；該 session 在 KurrentDB 26.1 與 26.2 上實測後，確認其中一個、推翻另一個，並回答了原本要 spike 的四個問題。修正在 swift-kurrentdb PR #197（metadata）與 #198（v2 錯誤解碼、`AppendSession` expected revision），版本 2.6.1 已於 2026-11-03 出版（tag `2.6.1` = commit 11fb8b42，release notes：https://github.com/gradyzhuo/swift-kurrentdb/releases/tag/2.6.1）；DDDKit 的 floor 在實作計畫 Task 1 提高。

已確認並修正（2.6.1，PR #197）：
- `EventRecord(eventData:)` 用 `JSONSerialization.jsonObject(with:) as? [String: Codable & Sendable]` 解 customMetadata，cast 失敗回 `[:]`。macOS 上任何非空 JSON 物件都失敗；Linux 上純字串物件可過、含 Int / Bool / null / 巢狀 / 陣列就失敗。結果：v2 寫入的事件讀回 `event.metadata == nil`，無錯誤。2.6.1：改用 `JSONDecoder` 解成 JSON value 再走訪成 protobuf Value；非物件 → `DecodingError`；空 `Data` = 沒有 metadata；NaN / ±infinity / 超出 64 位元的整數 → `encodingError`；任何 Codable 屬性都會被編碼，不再變成 null。**最終版與中途回報不同**：v2 路徑（append / appendRecords）對 ±2^53 以上的整數不拒絕，以最接近的 Double 送出，因為 protobuf Value 的數字就是 Double、`JSONDecoder` 無法可靠分辨 `9.223372036854776e+18` 是不是整數；每一位都重要的值要存成字串（batchAppend 的 v1 路徑則精確到 64 位元）。

**rev 8, 2026-11-04 implementation finding**（實作計畫 Task 10 的 probe；`KurrentStorageCoordinatorUnitOfWorkTests` 的 `nonFiniteMetadataThrowsEncodingErrorInAndOutOfScope`、`integerBeyond64BitsInMetadataIsAcceptedAndRounded` 釘住）：上一條「NaN / ±infinity / 超出 64 位元的整數 → `encodingError`」在 DDDKit 的路徑上不成立。NaN / ±infinity 到不了 `EventRecord(eventData:)`：coordinator 用預設 `JSONEncoder` 編 metadata，它先丟 `EncodingError`，作用域內外都一樣。以 JSON 數字寫出的超出 64 位元整數（例如 `Decimal` 的 123456789012345678901234567890）被接受，`EventRecord(eventData:)` 把它轉成最接近的 Double，不丟錯。所以 §6.3 作用域內的轉換檢查只會拒絕不是 JSON 物件的 metadata。

推翻（本設計的路徑不受影響）：
- 「tombstoned stream 在 `appendRecords` 落成 `grpcError` 並被重試」不成立：26.1 / 26.2 對 tombstoned stream 回的是 `consistencyViolation`（`actualState == -6`；soft-deleted 是 `-5`），2.6.0 本來就解得到、不會重試。真正會落成 `grpcError` 而被重試的是 `multiStreams.append`（`AppendSession`），PR #198 一併修了：v2 Streams 錯誤 details 全部解碼，StreamTombstoned / StreamDeleted → `resourceDeleted`、StreamRevisionConflict → `wrongExpectedVersion`、StreamNotFound → `resourceNotFound`、StreamAlreadyExists → `resourceAlreadyExists`、其他 streams-domain → `illegalStateError`，都不重試（backend 對這些一律原樣拋出，§6.4）；而且 2.6.0 的 `AppendSession` 從沒送 expected revision（`.at` / `.noStream` / `.streamExists` 全被忽略，25.1–26.2 都重現）。DDDKit 沒有用 `multiStreams.append`，只用 `appendRecords`，所以本設計只依賴 #197。

實測事實（26.1 與 26.2 一致；swift-kurrentdb 2.6.1 的 live 測試釘住）：
1. 同一個 `appendRecords` 內 tombstoned + revision 衝突：一個 `consistencyViolation` 同時列出兩筆，沒有優先序；分辨靠各 violation 的 `actualState`（-6 = tombstoned、-5 = soft-deleted、-1 = 不存在）。DDDKit 的優先序是自己定的，見 §6.5。
2. v1 soft delete（revision 0–2）後以 `.noStream` 透過 v2 重建：成功，revision = 3（舊尾端 +1，不是 0）。所以 §6.4 的「預測不符只 log」在這個正常情況下會觸發。
3. 同一組 record id 重送同一個 `appendRecords`（即使帶 `.noStream`）：冪等，回同樣的 revision 與 position，資料不重複。
4. metadata round-trip（v2 寫、v1 讀）：整數讀回是 `3` 不是 `3.0`（`JSONDecoder` 解 `Int` 沒問題）；`Date`（`JSONEncoder` 預設 double）數字完全一致。server 會另外塞 `"$schema.name"`、`"$schema.format"` 兩個鍵進 custom metadata：解成 Decodable struct 不受影響，但比對原始 bytes 或字典時要排除它們。（2026-11-04 補，最終審查實測於 26.1.1：metadata 為 `nil`（沒有 properties）的事件 server 一樣塞這兩個鍵，讀回不是空 bytes，而是 `{ "$schema.name": "<eventType>", "$schema.format": "Json" }`；live test `nilMetadataCommitReadsBackSchemaKeysOnly` 釘住。生成的 mapper 用 `try?` 不受影響；`ContextForwarder` 的 `ForwardedRecord.normalizedMetadata` 把只含 `$schema.*` 鍵的物件視為沒有 metadata，否則 `decodeMetadata` 會丟 `permanent` 讓事件 park；自己讀 `customMetadata` 的程式要寬鬆解碼，文件已寫明。）

DDDKit 不再需要自己的 spike（實作計畫 Task 2 取消）；§7 的 live test 以上述事實為斷言。另 2.6.1（#186）：對被 tombstone 的 stream 的 catch-up subscription 以 `resourceDeleted` 結束，不再先送 `$streamDeleted` 再丟 raw RPCError；與本設計無關，記在這裡供 projection runner 參考。

更正（2026-11-14）：使用者決定 unit of work 隨 swift-kurrentdb 3.0 出版，floor 由 2.6.1 改為 3.0.0（2026-11-14 出版）。本設計用到的 `multiStreams.appendRecords`、`EventRecord(eventData:)` 與 v1 單串流 append 在 3.0 行為不變；`EventRecord(eventData:)` 的錯誤改為 `KurrentError.underlyingError`，但 save 時的檢查把任何錯誤都轉成 `operationNotAllow`，payload 則在檢查前先自行編碼，仍丟 `EncodingError`。DDDKit 這邊的調整：`encodeForKurrent` 改把 metadata 位元組包成 `CustomMetadata(data:format: .bytes)`，寫進伺服器的位元組不變；讀取改成延遲讀取，任務被取消時改丟 `CancellationError`（MIGRATION BC7）；3.0 自己的 `CustomMetadata` 讓同時 import `KurrentDB` 的檔案要寫 `EventSourcing.CustomMetadata`（MIGRATION SB4）。

更正（2026-11-14，對抗式審查第 1 輪）：(1) 從作用域內啟動的 `Task` 呼叫 `withUnitOfWork` 一律拒絕，作用域結束前後都一樣，結束後的 reason 改成 `unit of work <id> already ended; …`，行為不隨時序改變。(2) `LiveEventStoreClient` 在 `readStream` 與 persistent subscription 的 delivery 把只含 `$schema.*` 的 custom metadata 讀成空 bytes，nil metadata 經任何路徑讀回都是空的（原本多串流 commit 後讀回只有 `$schema.*` 的物件，全 optional 的 metadata 型別會解出非 nil 的空 struct）。(3) live 實測：使用者以 `$` 開頭的 metadata key（含 `$schema.` 前綴）在多串流 commit 後原樣保留，不需在 save 時拒絕；超過 2^53 的整數四捨五入成最近的 Double。

更正（2026-11-14，對抗式審查第 2 輪）：(1) `withBackend(_:identity:make:_:)` 改為 `withBackend(_:identity:make:_:)`：staging 在 `body` 裡、在作用域的鎖內執行，和 `close()` 共用同一把鎖。原本取得 backend 與 `stage` 之間沒有共同的鎖，逃逸的 Task 可能在作用域關閉後把事件 stage 進已被丟棄的 backend（save 回傳成功卻永不寫入），或擠進已開始的 commit。(2) 只有 key 剛好是 `$schema.name` 與 `$schema.format` 的 metadata 才讀成空的，判斷前先在位元組中找 `$schema.name`，沒有就不解析 JSON。(3) 編碼為 `{}` 的 metadata 在多串流 commit 後讀回 nil，其他路徑讀回欄位全為 nil 的值。`MigrationUtility` 直接讀 `RecordedEvent`，仍看得到伺服器的兩個 key。

## 10. 留給實作者

- `UnitOfWork` 內部狀態與 TaskLocal 的放法（`EventMetadataContext` 已有同樣的 TaskLocal 作法可參考）。
- `KurrentUnitOfWorkBackend` 的 batch 資料結構、暫存事件包成 `RecordedEventLike` 的型別。
- `StreamBatch` / `StreamBatchResult` / `StreamConflict` 的檔案位置與 init 參數標籤。
- 共用編碼函式的名字。
- 文件：`EventSourcing` 與 `KurrentSupport` 的 DocC 各加一頁；README 的 Event Sourcing Flow 加「組合 usecase 用 `withUnitOfWork`」；CLAUDE.md 的 Key Protocols 加條目；migration 文件標 1.5.0 的 `EventStoreClient` 變更。

## 11. 本份作者自己的決定（請在讀的時候特別看）

1. 作用域是 TaskLocal（ambient），與 `EventMetadataContext` 同機制。使用者在 2026-11-01 看過用法後接受。
2. 核心層只放「作用域 + 一個 backend + 標記協定 + repository 守門」；暫存與 commit 全在 KurrentSupport（§6.1）。
3. 不能參與的 store 在作用域內 `save`/`purge` 丟錯，不靜默直寫（§6.2）。
4. 單一 stream 的 commit 走 v1 單 stream append，兩條以上才走 v2（§6.4）。
5. 預測 revision：`save` 立刻回 `expected + count`，commit 後比對；不符只 `logger.warning`，資料以 server 為準、hook 照跑（§6.4；rev 7 改，原本丟 `storeCorrupted` 會把已落地的寫入報成失敗）。
6. 同一 stream 在作用域內第二次 save 必須接在預測 tail 之後，否則 `commitConflict`（§6.3）。
7. 作用域內 `purge` 丟錯（§6.3）。
8. 作用域內多檢查每個 `EventData` 能轉成 v2 `EventRecord`，作用域外不檢查（§6.3；rev 7 改，原本只檢查 JSON 物件，守錯層）。
9. 「同一個 client」由 conformer 自己報 `identity`（live 回底層 `KurrentDBClient`），不加 `AnyObject`、不改 `LiveEventStoreClient`（§6.3、§6.5）。
10. seam 錯誤 `consistencyViolations([StreamConflict])` 列出全部；`commitConflict` 加多筆版本但 code 不變（§6.5、§6.6）。
11. `work` 參數提供 `id`、`isFailed`、`fail(_:)`、`onCommitted(_:)`；hook 在返回前依序跑完，hook 丟錯時 commit 仍成立（§5.6）。
12. v2 record id 去重、tombstone 形式、metadata round-trip、soft-delete 重建的 revision 由 dealwith-unitofwork session 在 26.1 / 26.2 實測回答，DDDKit 不再 spike（§9；rev 8）。
13. 不巢狀，第一版直接丟錯；放寬不破壞、收緊會破壞（§6.2）。
15. 作用域內經 repository 預設實作丟出的任何錯誤自動 `fail`；使用者自己 `do/catch` usecase 的情況靠文件規則「區塊內不 catch，要就 `work.fail`」（§5.6、§6.2）。
14. 作用域內所有經 coordinator 的讀取都看得到暫存事件，不為 projector 另開路徑；文件要求 projection 走訂閱 runner（§6.3）。
16. 作用域在 body 返回後關閉；關閉後 `backend` / `fail` / `onCommitted` 丟錯（所以後兩者是 `throws`），`current` 不變 nil（§6.2；rev 7）。
17. commit 與 hook 在 TaskLocal 之外執行；hook 內的 save 直接落地（§6.2、§5.6；rev 7）。
18. 自動毒化只包 store 呼叫與守門錯誤，`aggregateNotFound` 與 `markDelete` 錯誤不毒化（§6.2；rev 7）。
19. `identity` 無預設與 `EventStoreClientError` 新 case 是 source-breaking，標 SB 而不是硬守「不破壞」（§8；rev 7）。
20. swift-kurrentdb 的 metadata 缺陷先修（2.6.1）、提高 floor，再實作（§9；rev 7；rev 8 更正：交接裡的第二個缺陷不在 `appendRecords` 路徑）。
21. tombstone 與純衝突同在一個 request 時 server 兩筆一起列、沒有優先序；DDDKit 自訂 tombstone 先（`streamPurged`），因為 tombstone 不可重試、衝突可重試，呼叫端先知道不可重試的那個才不會白重跑（§6.5；rev 8）。
22. in-memory 只模擬「每條 batch 都是重送」的冪等，部分重送不模擬（§6.5；rev 8）。
