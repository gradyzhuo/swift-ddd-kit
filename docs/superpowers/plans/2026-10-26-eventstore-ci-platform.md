# EventStore CI, Platform and Packaging (1.5, part C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Check the `EventStore` contract against a real KurrentDB in CI, run the new offline test targets in CI, ship `DDDCore`/`EventSourcing`/`LocalEventStore` as iOS-buildable products, and document 1.5.

**Architecture:**
- A new test target, `KurrentLiveContractTests`, runs `EventStoreContract` on a `KurrentStorageCoordinator` backed by a pooled `KurrentDBClient`. A new CI job runs it against a KurrentDB container. `KurrentStorageCoordinator` gains one guard, because the live run showed that a real server fails on huge revisions.
- `Package.swift` gains `.iOS(.v18)` and three library products. A new CI job builds those products for the iOS Simulator.
- CI runners are pinned to `ubuntu-24.04`, because `ubuntu-latest` (now 26.04) breaks the existing jobs.
- The rest is documentation:
  - `README.md`
  - `CLAUDE.md`
  - `docs/index.html`
  - `MIGRATION.md`
  - a 1.3 → 1.5 HTML migration guide

**Tech Stack:** Swift 6.1+ (tools-version 6.1), Swift Testing, GitHub Actions, KurrentDB 26.1.3, swift-kurrentdb `KurrentDBPool`, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-10-23-eventstore-ci-platform-design.md` (rev 4). It depends on spec A (`2026-10-23-eventstore-contract-design.md`) and spec B (`2026-10-23-persistent-event-store-design.md`). Both are merged (#31, #33).

## Global Constraints

- **Branching.** Branch from `origin/main` (7791238 or later) with `--no-track`. Open the PR to `main`. Never merge it.
- **Running tests.** Never run bare `swift test`. Offline runs use `--filter`. `KurrentLiveContractTests` needs a KurrentDB.
- **Offline target list.** Use this verbatim in **both** existing CI jobs:
  `(DDDKitUnitTests|EventSourcingTests|ContextForwarderTests|ContextReceiverTests|ContextReceiverWebSocketTests|TemplateVariablesTests|TemplateVariablesDefinitionTests|TemplateVariablesDemoTests|KurrentSupportInMemoryTests|ReadModelPersistenceTests|DomainEventGeneratorTests|ProjectorGeneratorFixtureTests|EventStoreContractTests|LocalEventStoreTests)`
- **Live test names.** No type, function, `@Suite` name or `@Test` name in `KurrentLiveContractTests` may contain any name from that list. On Swift 6.4 the filter matches identifiers only; the rule also covers display names to be safe.
- **CI image.** KurrentDB image `kurrentplatform/kurrentdb:26.1.3` (Ruling R1), with env `KURRENTDB_CLUSTER_SIZE=1` and `KURRENTDB_INSECURE=true`, published as `-p 2113:2113`. Set `KURRENTDB_POOL_URLS: '["esdb://admin:changeit@localhost:2113?tls=false"]'` in the job-level `env:`, never with a shell `export`.
- **Local live run** (the maintainer machine already uses 2111–2113 for a 3-node TLS cluster):
  - `docker run -d --platform linux/amd64 --name kurrentdb-plan-c -p 2213:2113 -e KURRENTDB_CLUSTER_SIZE=1 -e KURRENTDB_INSECURE=true -e KURRENTDB_NODE_PORT_ADVERTISE_AS=2213 kurrentplatform/kurrentdb:26.1.3`
  - Then use `KURRENTDB_POOL_URLS='["esdb://admin:changeit@localhost:2213?tls=false"]'`.
  - The `ADVERTISE_AS` setting is required. Without it, gossip reports `:2113` and the client follows it into the other cluster.
  - Wait with a bounded loop: up to 120 tries, 1 second apart, on `curl -fsS http://localhost:2213/health/live`.
  - Afterwards, `docker rm -f kurrentdb-plan-c`.
- **Live job.**
  - `runs-on: ubuntu-24.04`, Swift `6.4` only.
  - Poll `http://localhost:2113/health/live` for at most 60 seconds, then run `swift test --filter KurrentLiveContractTests`.
  - It is not a required check. That is the maintainer's decision, so there is nothing to configure.
- **Runners.** Every `ubuntu-latest` in `.github/workflows/swift-build-testing.yml` becomes `ubuntu-24.04` (Ruling R7).
- **Platforms and products.**
  - `platforms` becomes `.macOS(.v15), .iOS(.v18)`.
  - New products: `.library(name: "DDDCore", targets: ["DDDCore"])`, `.library(name: "EventSourcing", targets: ["EventSourcing"])` and `.library(name: "LocalEventStore", targets: ["LocalEventStore"])`.
  - These three targets keep depending only on each other, Foundation and swift-log.
- **iOS job.**
  - `runs-on: macos-15`, with job `env: DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer`.
  - Run `xcodebuild -version` first, then `xcodebuild -resolvePackageDependencies` once.
  - Then, per product: `xcodebuild build -scheme <product> -destination 'generic/platform=iOS Simulator'`.
- **Symbol graphs.** `EventStoreContract` stays out of the products and stays in `EXCLUDED` in `scripts/emit-symbol-graphs.sh`. Both are already true on main; do not touch the script.
- **Commit trailers.**
  - `Co-Authored-By: <the model writing the commit> <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1`
- **Languages.**
  - `docs/index.html` is bilingual: use `<span lang="en">` + `<span lang="zh-Hant">` pairs, or `data-en`/`data-zh` on `<option>`.
  - `README.md` and `CLAUDE.md` are English.
  - `MIGRATION.md`'s 1.5.0 section and the HTML migration guides are Traditional Chinese, matching what is already there.

## Rulings made while writing the plan

- **R1 — image name.**
  - Spec §3 names `docker.kurrent.io/kurrent-latest/kurrentdb:<26.1 full patch>`, but that registry only publishes `26.1` and `latest`. `26.1.3` gives "no such manifest" (checked 2026-10-26).
  - Docker Hub's `kurrentplatform/kurrentdb:26.1.3` is Kurrent's own image with the full patch version. It is linux/amd64 only, so local Apple Silicon runs need `--platform linux/amd64`.
  - *Cost if wrong:* one line in the workflow and one line in the changelog.
- **R2 — 1.4.0 is not released.**
  - The latest stable tag is `1.3.0`. The pre-releases on the main line are `1.4.0-beta.9` to `beta.14`; betas 0–8 are a retired line and are not ancestors of main.
  - Per spec §6 the guide is **1.3 → 1.5**. If 1.4.0 ships first, retitle it then.
  - *Cost if wrong:* a rename.
- **R3 — `LocalEventStore` usage notes go in a README section**, not a new DocC catalog. The type's doc comment already carries the limits for DocC readers.
- **R4 — fix the huge-revision path; don't hide it.**
  - A review ran the contract on real KurrentDB 26.1.3. `checkAll` passes. `checkHugeVersionConflicts` fails with "Unmapped gRPC error. Exception was thrown by handler": the server cannot take an expected revision above `Int64.max`.
  - Spec A §3.4 requires `commitConflict`, so `KurrentStorageCoordinator.append` gets a guard (Task 3 Step 2). No KurrentDB stream can reach such a revision, so the guard is exact rather than a workaround.
  - *Cost if wrong:* one guard and one extra read on an input that cannot succeed anyway.
- **R5 — `KurrentSupportUnitTests` is not in the CI filter today.** Spec C does not ask to add it, so it is left out (subtraction). The PR description mentions it.
- **R6 — MIGRATION.md is the source of truth for 1.5's compatibility notes.**
  - Its `## 1.5.0 — EventStore contract` section already exists on main and is more recent than spec A §8. For example, it lists the generator import change as **source-breaking**, with two remedies.
  - Task 5 extends that section with B and C. The HTML guide is written from the extended section.
- **R7 — pin `ubuntu-24.04`.**
  - On run 40273834115 (main at 7791238), the Swift 6.1 job failed: `swift-build: error while loading shared libraries: libxml2.so.2`. `ubuntu-latest` moved to 26.04. The 6.2–6.4 jobs were cancelled by fail-fast.
  - The PR cannot go green without the pin, so it goes in as the branch's first commit. The maintainer may split it out as a hotfix PR.

## Review Focus

1. **KurrentDB never becomes healthy.** The 60-second poll must fail the job with a clear message and `docker logs`, not fall through to `swift test`. `/health/live` returns 204 before the node is Leader. In CI this is harmless because `swift test` builds for minutes before it connects. Do not add `--skip-build` to that step. Task 3 Step 6 checks this by reading the step.
2. **The offline regex picks up the live suite.** If it does, the offline jobs try to reach KurrentDB. Task 3 Step 5 lists what the offline filter selects.
3. **An app built with default `MainActor` isolation** that overrides `categoryRule` or `category` hits a compile error at `PersistentEventStore.open`. The defaults inherited from `AggregateRoot` are fine. The README must show the fix that compiles. Task 4 Step 3 compiles both cases.
4. **An iOS consumer adds the `DDDKit` umbrella**, which pulls in KurrentDB, gRPC and Postgres. The docs must say that only the three products are meant for iOS. Task 4 Step 1 owns that sentence.
5. **Doc facts drifting from code.** Task 4 Step 6 and Task 5 Step 4 grep the source for each of these:
   - the 120-byte limit on the whole stream name
   - error codes 501–504
   - the `StoreUnavailableReason` cases
   - the swift-kurrentdb floor 2.6.0
   - the deprecated `tombstoneStream` default

---

### Task 0: Worktree (controller)

- [ ] **Step 1: Create the worktree.** Run `git fetch origin --tags && git worktree add --no-track -b feat/eventstore-ci-platform .claude/worktrees/eventstore-ci-platform origin/main`, then enter it with `EnterWorktree(path)`.
- [ ] **Step 2: Commit this plan.** Copy this plan into the worktree and commit it as `docs(plans): EventStore CI, platform and packaging implementation plan`.

### Task 1: Pin the Linux runners

**Files:**
- Modify: `.github/workflows/swift-build-testing.yml`

- [ ] **Step 1: Replace every `ubuntu-latest`** with `ubuntu-24.04`. This covers the `matrix.os` value and `build-linux-distros`' `runs-on`. Nothing else changes.
- [ ] **Step 2: Check it.**
  1. `grep -n ubuntu .github/workflows/swift-build-testing.yml` shows no `latest`.
  2. `python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" .github/workflows/swift-build-testing.yml` exits 0.
- [ ] **Step 3: Commit** with the message `ci: pin Linux runners to ubuntu-24.04 (ubuntu-latest 26.04 lacks libxml2.so.2 for Swift 6.1)`.

### Task 2: iOS platform, three products, iOS build job

**Files:**
- Modify: `Package.swift`: change `platforms`, and insert the three libraries right after the `DDDKit` product.
- Modify: `.github/workflows/swift-build-testing.yml`: add a new job, `build-ios`.

**Interfaces:**
- Produces: the products `DDDCore`, `EventSourcing` and `LocalEventStore`. Tasks 4 and 5 document them.

- [ ] **Step 1: Confirm the schemes are missing.** Run `xcodebuild -list`. The `Schemes:` list has no `LocalEventStore`, because targets that are not products get no scheme.
- [ ] **Step 2: Edit `Package.swift`** as described in Global Constraints. Leave the dependencies unchanged.
- [ ] **Step 3: Build each product for the iOS Simulator locally.**
  - Run `xcodebuild build -scheme <product> -destination 'generic/platform=iOS Simulator' -quiet` for `DDDCore`, `EventSourcing` and `LocalEventStore`.
  - Expect exit 0 for all three.
  - Two things are expected and need no action:
    - The local toolchain is newer than CI's (Xcode 16.4, Swift 6.1). Only the CI job proves the 16.4 build.
    - Swift 6.2+ toolchains print one `#IsolatedConformances` warning at `PersistentEventStore.swift:73`. It is documented there.
  - If a source file fails only on iOS:
    - Fix it in that file with the narrowest change and report it.
    - Do not add `#if os(...)` around whole files.
- [ ] **Step 4: Add the `build-ios` job.**
  - Use `runs-on: macos-15` and the job-level `DEVELOPER_DIR` from Global Constraints.
  - Steps:
    1. `actions/checkout@v4`
    2. `xcodebuild -version`
    3. `xcodebuild -resolvePackageDependencies`
    4. A loop over the three products that runs the Step 3 command without `-quiet`.
  - Each `run:` uses bash with `-e`, so the first failure fails the job.
- [ ] **Step 5: Run the host build and the offline suite.**
  1. Run `swift build --build-tests`.
  2. Run `swift test --no-parallel --filter '<offline list>'`.
  - Everything selected passes.
- [ ] **Step 6: Commit** with the message `feat(package): ship DDDCore, EventSourcing and LocalEventStore as products and build them for iOS`.

### Task 3: Live KurrentDB contract test, huge-revision guard, live job, offline filters

**Files:**
- Create: `Tests/KurrentLiveContractTests/KurrentLiveContractTests.swift`
- Modify: `Package.swift`: add a new `.testTarget` right after `EventStoreContractTests`.
- Modify: `Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift`: change `append`.
- Modify: `.github/workflows/swift-build-testing.yml`: update both filters and add a new job, `kurrent-live-contract`.

**Interfaces:**
- Consumes:
  - `EventStoreContract.checkAll(serialized:_:)` and `EventStoreContract.checkHugeVersionConflicts(_:)`.
  - The public fixtures `ContractStream`, `ContractMetadata` and `ContractEventMapper` (`Sources/EventStoreContract`).
  - `KurrentDBClient.withPooledIntegrationTestClient(_:)` (`Sources/TestUtility/PooledKurrentClientFactory.swift`).
  - `KurrentStorageCoordinator<ContractStream, ContractMetadata>(client: KurrentDBClient, eventMapper:)`.
  - `EventStoreClient.readStream(name:from:resolveLinks:)`.
- Produces: the test target name `KurrentLiveContractTests`, which Task 4 documents.

- [ ] **Step 1: Add the target and the tests.**
  - The target depends on `EventStoreContract`, `EventSourcing`, `KurrentSupport`, `TestUtility` and `.product(name: "KurrentDB", package: "swift-kurrentdb")`.
  - Add `"ReadModelPersistence"` to the **`KurrentSupport` target's** dependencies in `Package.swift`.
    - `KurrentSupport` already imports it (`KurrentProjection.swift:14`, `KurrentProjection+Rebuild.swift:4`) but never declares it.
    - Without the declaration, a test target that does not list `ReadModelPersistence` itself fails to link with `Undefined symbols … StoredReadModel`.
    - Fix the root cause there; do not paper over it in the test target.
  - The suite is `@Suite("Live KurrentDB") struct LiveKurrentContract` and holds two `@Test`s.
  - Each test runs inside `try await KurrentDBClient.withPooledIntegrationTestClient { client in … }`. Its `make` closure builds a fresh `KurrentStorageCoordinator<ContractStream, ContractMetadata>(client: client, eventMapper: ContractEventMapper())`.
  - The two tests:
    - `@Test("Kurrent coordinator follows the contract") func followsContract()` calls `checkAll(serialized: true)`. That includes `checkPurge`, which is the spec's "read after purge gives nil".
    - `@Test("Kurrent coordinator: huge versions conflict") func hugeVersions()` calls `checkHugeVersionConflicts`.
- [ ] **Step 2: Run the tests against a local KurrentDB, then fix the huge-revision path.**
  - Use the local live-run recipe from Global Constraints and run `swift test --filter KurrentLiveContractTests`.
  - Expected: `followsContract` passes, and `hugeVersions` fails with `got Unmapped gRPC error`. That is R4. This run is an optional confirmation, not a gate: the review already reproduced it. The server accepts `Int64.max` itself, so the threshold is `>`, not `>=`.
  - In `append`, after the empty-events guard: when `version` is greater than `UInt64(Int64.max)`, do not call `client.append`. Instead:
    1. Read the stream with `client.readStream(name:from: .start, resolveLinks: false)`.
    2. If the stream is missing, `EventStoreClientError.streamNotFound` gives `actual: nil`.
    3. If the stream is tombstoned, `KurrentError.resourceDeleted` throws `DDDError.streamPurged(id:)`, the same precedence as a normal append.
    4. Otherwise `actual` is the last record's `revision`. Count every record, mapped or not.
    5. Throw `DDDError.commitConflict(id:expected: version, actual:)`.
  - Comment the guard in no more than two lines:
    - KurrentDB revisions are `Int64`, so such an expected revision can never match, and the server rejects it with an internal error.
    - `actual` is the last *readable* revision. A truncated or soft-deleted stream reports `nil`.
  - Rerun the live tests: both pass.
  - Then run `swift test --filter 'EventStoreContractTests|KurrentSupportInMemoryTests'`. The in-memory huge-version test now takes the guard path, and it passes.
- [ ] **Step 3: Update the comments that said "unverified until the live run".**
  - The comment above `kurrentOverInMemoryClientHugeVersions` in `Tests/EventStoreContractTests/EventStoreContractTests.swift`.
  - The doc comment of `checkHugeVersionConflicts`.
  - Both should now say the check is verified against real KurrentDB in `KurrentLiveContractTests`. Leave the check outside `checkAll`; that is a separate decision.
- [ ] **Step 4: Update both offline filters** to the list in Global Constraints.
- [ ] **Step 5: Confirm the filter separation.** `swift test list` has no `--filter`, so apply the regex to its output:
  - `swift test list | grep -E '<offline list>' | grep KurrentLive | wc -l` prints `0`.
  - `swift test list | grep KurrentLiveContractTests` shows exactly the 2 live tests.
- [ ] **Step 6: Add the `kurrent-live-contract` job.**
  - Job settings:
    - `name: Kurrent live contract`
    - `runs-on: ubuntu-24.04`
    - the job-level `env:` from Global Constraints
  - Steps:
    1. checkout
    2. `SwiftyLab/setup-swift@latest` with `swift-version: "6.4"`
    3. The `docker run -d --name kurrentdb -p 2113:2113 …` line from Global Constraints, preceded by the YAML comment `# Reference server for the EventStore contract; when bumping it, rerun this job and review (spec C §3, 1.5 changelog).`
    4. The wait loop: `for i in $(seq 1 60); do curl -fsS http://localhost:2113/health/live && exit 0; sleep 1; done; echo "KurrentDB not live after 60s"; docker logs kurrentdb; exit 1`
    5. `swift test --filter KurrentLiveContractTests`, without `--skip-build` (Review Focus 1).
  - Read the wait step and confirm that the only `exit 0` follows a successful curl.
- [ ] **Step 7: Commit** with the message `ci: run the EventStore contract against a live KurrentDB; conflict on revisions KurrentDB cannot hold`.

### Task 4: README, CLAUDE.md and the docs site

**Files:**
- Modify `README.md`:
  - `## Requirements` (~:133)
  - "5. Save and Find" purge lines (~:268–272)
  - the Event Mapper section
  - the `## Modules` table (~:951)
  - a new `## Local Event Store (iOS and macOS apps)` section before `## Event Migration`
- Modify `CLAUDE.md`:
  - the Build & Test paragraph
  - the platform sentence in the Architecture Overview
  - the layer-tree line that still credits KurrentSupport with `EventTypeMapper`
  - the `**EventTypeMapper** (KurrentSupport)` heading
  - the contract paragraph's sentence about `checkHugeVersionConflicts`
- Modify `docs/index.html`:
  - the `#release-select` options
  - a new `<article class="release" id="v1.5">` above `id="v1.4"`
  - the modules table (~:540)
  - the hard-delete comment (~:507)

**Interfaces:**
- Consumes:
  - the products from Task 2
  - `KurrentLiveContractTests` and the R4 guard from Task 3
  - the guide path `docs/migration/swift-ddd-kit-1.3-to-1.5.html`, which Task 5 creates

- [ ] **Step 1: Modules and requirements.**
  - README `## Modules`:
    - add a `LocalEventStore` row: "`PersistentEventStore`: a file-backed `EventStore` for apps, one JSON file per stream".
    - In the `EventSourcing` row, list `InMemoryEventStore`, `RecordedEventLike`, `EventTypeMapper` and `CustomMetadata`.
    - The `KurrentSupport` row stops claiming `EventTypeMapper`.
  - `docs/index.html` modules table:
    - edit the `DDDKit` umbrella row the same way. `EventSourcing` lists the moved types; `KurrentSupport` drops `EventTypeMapper`.
    - Add a `LocalEventStore` row under the Core group.
  - Under both tables, and in README `## Requirements`, add one sentence: iOS 18+ is supported for `DDDCore`, `EventSourcing` and `LocalEventStore`; `DDDKit` and every KurrentDB, Postgres or Pulsar module are server-side.
- [ ] **Step 2: Purge and unmapped events.**
  - README "5. Save and Find" and the `docs/index.html` snippet comment say:
    - `purge` makes the id permanently unwritable. `append` then throws `streamPurged` (502), so never purge an id that will be reused.
    - KurrentDB keeps the data until a scavenge.
    - `PersistentEventStore` removes the payload from the stream file.
  - The README Event Mapper section gains spec A's note for every serialized store: when events the mapper does not know sit at a stream's tail, `find` returns a lower version and `save` keeps conflicting. Keep the mapping when retiring an event type.
- [ ] **Step 3: Write the README section "Local Event Store (iOS and macOS apps)".** Cover, in order:
  1. A minimal example where `open`, a repository and a projector share one instance. The projector declares `typealias Store = PersistentEventStore<Order, M>`.
  2. One open instance per directory. Give each aggregate type (each `StreamNaming`/`Metadata` pair) its own directory. A second `open` of a directory throws `storeUnavailable(.occupied)`, even with other generic arguments.
  3. Share the instance between the repository and the projectors. On the Kurrent path, by contrast, each projector builds its own coordinator.
  4. Put the directory under the app's own Application Support, not in:
     - an App Group or other shared container, because iOS terminates a suspended app that holds a lock there
     - a cloud-synced folder
     - a network file system
  5. There is no fsync. After an OS crash or power loss the latest writes can be lost, and a stream file can come back empty or damaged. That stream alone throws `storeCorrupted` (504). `purge` clears it, but it discards that stream's events and leaves the id unwritable. It does not repair anything.
  6. The whole stream name (`<category>-<id>`) is at most 120 UTF-8 bytes, so ids get less than that. A longer name throws `storeUnavailable(.streamNameTooLong)`.
  7. Call `close()` before deleting the directory.
  8. Unmapped events at the tail: point to the Step 2 note.
  9. Files carry `formatVersion` 1. An app downgraded after a future format bump reads those streams as `storeCorrupted`.
  10. Apps that use default `MainActor` isolation (Swift 6.2+) and override `categoryRule` or `category` must mark those overrides `nonisolated`, as in `nonisolated static var categoryRule: StreamCategoryRule { .custom("orders") }`. Marking the whole type `nonisolated` also works. Otherwise `PersistentEventStore.open` fails to compile: "main actor-isolated conformance … cannot be used in actor-isolated context". The inherited defaults need nothing. `final class Order: nonisolated AggregateRoot` does **not** compile.
  - **Verify item 10.**
    - Set up the package:
      - Create a scratch package with `swift-tools-version: 6.2` and `swiftSettings: [.defaultIsolation(MainActor.self)]`.
      - Make it depend on this checkout by path.
      - Use the README's full `Order` type, which overrides `categoryRule`.
    - Build four variants and check each result:
      - With `nonisolated` on the override, it builds.
      - Without `nonisolated`, it errors.
      - With the type marked `nonisolated` instead, it builds.
      - With `final class Order: nonisolated AggregateRoot`, it errors.
    - Record the `swift --version` used. Item 10 names the Swift versions actually checked, and adds "Swift 6.2+" only if 6.2 itself was checked.
    - If any result differs, rewrite item 10 to match what the compiler actually does.
    - Paste the type that compiled into the README.
- [ ] **Step 4: CLAUDE.md.**
  - Build & Test: add `KurrentLiveContractTests` (it needs a single-node insecure KurrentDB and `KURRENTDB_POOL_URLS`, and runs in CI's `kurrent-live-contract` job). `EventStoreContractTests` and `LocalEventStoreTests` need no server and run in CI's offline filter.
  - Platforms: change the sentence to "targeting Ubuntu (Linux) and macOS 15+; `DDDCore`, `EventSourcing` and `LocalEventStore` also build for iOS 18+".
  - EventTypeMapper: move it to EventSourcing in the layer tree and in the Key Protocols heading. KurrentSupport keeps a typealias.
  - Contract paragraph:
    - say that `checkHugeVersionConflicts` passes on real KurrentDB in `KurrentLiveContractTests`
    - say that `KurrentStorageCoordinator` turns expected revisions above `Int64.max` into `commitConflict` without calling the server.
- [ ] **Step 5: The `docs/index.html` 1.5 article.**
  - **Release picker.** Add `<option value="v1.5" data-en="1.5 (unreleased)" data-zh="1.5（未發行）">1.5 (unreleased)</option>` as the first option. `site.js` keys on the article id.
  - **Article.**
    - Use the `whats-new-tag beta` badge with the text "Unreleased · 1.5.0" / "未發行 · 1.5.0".
    - Use the `release-title` and bilingual `lead` paragraphs: the `EventStore` contract, `PersistentEventStore`, and iOS for three products.
  - **Table.** Use the existing `table.compat` with Tag | Change columns. Add three rows, each tagged "Unreleased": A (contract, tombstone purge, `commitConflict`), B (`PersistentEventStore`) and C (products and iOS, live contract CI).
  - **Notes.**
    - Name the reference server `kurrentplatform/kurrentdb:26.1.3` in two notes, `<p class="note" lang="en">` and `<p class="note" lang="zh-Hant">`, the same shape as the existing notes at ~:134.
    - Add a `cta-row` with a `btn primary` link to the Task 5 guide, matching the v1.0 article.
  - **Fix the stale v1.4 article** so it does not contradict the new one:
    - Its badge becomes "Pre-release · 1.4.0-beta.14" / "預覽版 · 1.4.0-beta.14".
    - Its "Unreleased" row (Postgres read-model hardening, #27) is retagged `1.4.0-beta.12`, the release that shipped it, with a link to that tag.
- [ ] **Step 6: Grep check.** Grep the source for every fact this task writes and make the text match:
  - `maxStreamNameBytes` in `Sources/LocalEventStore/StreamFile.swift`
  - the codes and `StoreUnavailableReason` cases in `Sources/DDDCore/Adapter/DDDError.swift`
  - `from: "2.6.0"` in `Package.swift`
- [ ] **Step 7: Commit** with the message `docs: document LocalEventStore, iOS products, purge semantics and the live contract test`.

### Task 5: MIGRATION.md 1.5.0 and the 1.3 → 1.5 guide

**Files:**
- Modify: `MIGRATION.md` (the `## 1.5.0 — EventStore contract` section)
- Create: `docs/migration/swift-ddd-kit-1.3-to-1.5.html`
- Modify: `docs/index.html`: add a `doc-card` next to the 0.x card (~:636) and a footer link next to the 0.x one (~:669). Task 4 adds the v1.5 `cta-row`.

**Interfaces:**
- Consumes:
  - the existing MIGRATION.md sections `## 1.4.0 — ForwardingRule.translate returns an array` and `## 1.5.0 — EventStore contract`
  - spec B's compatibility section
  - spec C §5
  - the main-line tags `1.4.0-beta.9` … `1.4.0-beta.14`
  - PRs #31–#33

- [ ] **Step 1: Extend MIGRATION.md's 1.5.0 section** in Traditional Chinese, one subsection per item:
  - `PersistentEventStore` / `LocalEventStore` (new; nothing to migrate; points to the README section)
  - the new error codes 503/504 and `StoreUnavailableReason`, if §4 doesn't already list them
  - `.iOS(.v18)`: source-breaking for anyone who builds **any** product of this package for iOS or Mac Catalyst below 18
  - the three new products (source-compatible)
  - `KurrentStorageCoordinator` turning expected revisions above `Int64.max` into `commitConflict`, a behaviour change from a server error

  Do not repeat what §1–§8 already say.
- [ ] **Step 2: Gather the 1.4 history** without `1.3.0..main --merges`, which misses rebase-merged PRs and the beta.9 commits:
  - For each pair `1.3.0→1.4.0-beta.9` and `beta.N→beta.N+1` up to beta.14, run `git log --first-parent --oneline <from>..<to>`.
  - "Unreleased" is exactly #31, #32 and #33. A PR whose head commit is an ancestor of `1.4.0-beta.14` (#29, #30 and earlier) already shipped in a beta, so do not list it twice.
  - Note the user-facing changes for each tag.
  - Cross-check them against MIGRATION.md's 1.4.0 section and the `docs/index.html` v1.4 table.
- [ ] **Step 3: Write the guide.**
  - Copy `<head>`, `<style>` and the structure of `docs/migration/swift-ddd-kit-0.x-to-1.0.html`, in Traditional Chinese like that guide, including its AI Migration Manifest JSON section.
  - Set `x-migration-from` to `1.3` and `x-migration-to` to `1.5`, and update the title and description to match.
  - Drop the mermaid script unless the guide draws a diagram.
  - Sections:
    1. Who is affected.
    2. Source-breaking changes:
       - swift-kurrentdb ≥ 2.6.0
       - `DDDError.Code` 501–504 and `EventStoreClientError.tombstoneUnsupported` break a `switch` with no `default`
       - the generator import change, with both remedies from MIGRATION.md §7
       - `ForwardingRule.translate` returns an array (1.4)
       - iOS / Mac Catalyst 18 minimum
    3. Behaviour changes: MIGRATION.md §1, §3, §6 and the R4 guard. `tombstoneStream`'s default compiles with a deprecation warning, but `purge` fails at run time unless a wrapper forwards it.
    4. Additions: the moved types and their typealiases, `PersistentEventStore`, the three products, and the 1.4 additions.
    5. The 1.4 betas: one row per main-line tag (beta.9 to beta.14) plus one "Unreleased" row for #31–#33. One line says betas 0–8 belong to a retired line, and that modules introduced only there, such as `NotificationDefinition`, are not in 1.5.
    6. Upgrade steps as a checklist.
    7. A note naming the reference KurrentDB `26.1.3`.
- [ ] **Step 4: Verify the guide.**
  - Grep `Sources/` for every symbol the guide names, with the exact spelling used.
  - Parse the page with `python3 -c "import html.parser,sys; html.parser.HTMLParser().feed(open(sys.argv[1]).read())" docs/migration/swift-ddd-kit-1.3-to-1.5.html`.
  - Validate the manifest JSON with `python3 -m json.tool`.
  - Confirm that every `docs/index.html` link to the guide resolves to the file path.
- [ ] **Step 5: Commit** with the message `docs(migration): 1.5.0 notes in MIGRATION.md and a 1.3 to 1.5 guide`.

### Task 6: Verify, push, PR (controller, after the final review)

- [ ] **Step 1: Verify.** Run `swift build --build-tests` and the offline filter, then the local live run (Task 3 Step 2) once more.
- [ ] **Step 2: Push and open the PR.**
  - Push `feat/eventstore-ci-platform` and open a PR to `main` titled "EventStore CI, platform and packaging (1.5, part C)".
  - In the body, mention R5 and R7, and say that main's CI has been red since 7791238.
  - Do not merge.
- [ ] **Step 3: Watch the checks.** Run `gh pr checks --watch`. Every job must pass, including `kurrent-live-contract` and `build-ios`.
