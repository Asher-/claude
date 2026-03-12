# Gap Fill: Testing Concurrent Code on macOS/Swift

Phase 3 research for the #1 identified gap: the skill can help write concurrent code but cannot help verify it.

---

## 1. Framework Landscape

Two test frameworks coexist. The skill must handle both.

| Framework     | Status              | Async Support            | Concurrency Testing Primitive |
| ------------- | ------------------- | ------------------------ | ----------------------------- |
| XCTest        | Legacy, still used  | `async` test methods     | `XCTestExpectation`           |
| Swift Testing | Current, Apple-made | Native `async` + `@Test` | `confirmation()`              |

**Rule**: Prefer Swift Testing for new test code. XCTest patterns are needed for existing codebases and mixed projects.

---

## 2. XCTest Patterns for Concurrent Code

### 2.1 Async Test Methods (Modern)

Since Swift 5.5, XCTest supports `async` directly:

```swift
func testFetchUser() async throws {
    let service = UserService()
    let user = try await service.fetch(id: "42")
    XCTAssertEqual(user.name, "Alice")
}
```

No expectations needed. The test suspends at `await` and resumes when the async work completes.

### 2.2 Testing @MainActor Code from XCTest

Mark the test method (or entire class) `@MainActor`:

```swift
@MainActor
func testViewModelUpdate() async {
    let vm = ViewModel()       // @MainActor-isolated
    await vm.loadData()
    XCTAssertFalse(vm.items.isEmpty)
}
```

Without `@MainActor` on the test, accessing actor-isolated properties produces compiler errors in Swift 6.

### 2.3 XCTestExpectation: Old vs Modern Pattern

**Old pattern** (pre-async, still works for callback APIs):
```swift
func testCallback() {
    let exp = expectation(description: "callback fires")
    service.fetch { result in
        XCTAssertNotNil(result)
        exp.fulfill()
    }
    waitForExpectations(timeout: 5)
}
```

**Modern pattern** (async context, avoids deadlocks):
```swift
func testCallback() async {
    let exp = expectation(description: "callback fires")
    service.fetch { result in
        XCTAssertNotNil(result)
        exp.fulfill()
    }
    await fulfillment(of: [exp], timeout: 5)
}
```

**Critical**: In async test methods, `wait(for:)` can deadlock. Always use `await fulfillment(of:)` instead. If no code under test uses Swift concurrency, the old `waitForExpectations` is fine and faster.

### 2.4 Testing Actor-Isolated Code

Actors are tested like any async code -- access through `await`:

```swift
func testCounter() async {
    let counter = Counter()  // actor
    await counter.increment()
    await counter.increment()
    let value = await counter.value
    XCTAssertEqual(value, 2)
}
```

---

## 3. Swift Testing Framework

### 3.1 Basic Async Tests

```swift
@Test func fetchUser() async throws {
    let user = try await service.fetch(id: "42")
    #expect(user.name == "Alice")
}
```

`@Test` functions can be `async`, `throws`, or both. Thrown errors fail the test automatically.

### 3.2 Confirmation API (Replaces XCTestExpectation)

For callback/delegate APIs where you need to verify an event fires:

```swift
@Test func delegateNotified() async {
    await confirmation("delegate called", expectedCount: 3) { confirm in
        let delegate = MockDelegate(onUpdate: { confirm() })
        let sut = Engine(delegate: delegate)
        sut.processAll()  // should trigger delegate 3x
    }
}
```

Key behaviors:
- `expectedCount: 1` is the default (event must fire exactly once)
- `expectedCount: 0` asserts the event NEVER fires
- Supports ranges: `expectedCount: 1...5`
- Auto-waits and fails if count is wrong -- no manual timeout

### 3.3 Bridging Completion Handlers

Wrap legacy callback APIs with `withCheckedThrowingContinuation`:

```swift
@Test func legacyAPI() async throws {
    let data = try await withCheckedThrowingContinuation { cont in
        legacyFetch { result in cont.resume(with: result) }
    }
    #expect(!data.isEmpty)
}
```

### 3.4 withKnownIssue for Concurrency Bugs

When a race condition or concurrency bug is known but not yet fixed:

```swift
@Test func knownRace() async {
    withKnownIssue("FB12345: race in cache invalidation") {
        let result = await cache.fetchWithInvalidation()
        #expect(result.isConsistent)
    }
}
```

The test runs but does not fail the suite. When the bug is fixed, the test starts passing -- signaling you to remove `withKnownIssue`. Use `isIntermittent: true` for flaky races that sometimes pass.

### 3.5 Controlling Parallelism

Swift Testing runs tests in parallel by default. Control this with traits:

```swift
@Suite(.serialized) struct DatabaseTests {
    // All tests in this suite run sequentially
    @Test func insert() async { ... }
    @Test func query() async { ... }
}
```

- `.serialized` forces sequential execution within a suite
- Other suites still run in parallel alongside serialized ones
- `.timeLimit(.minutes(2))` prevents hung tests from blocking CI

---

## 4. Deterministic Testing with swift-concurrency-extras

The biggest challenge in testing concurrent code: non-determinism. Point-Free's `swift-concurrency-extras` solves this.

### 4.1 withMainSerialExecutor

Forces all async tasks to execute serially on the main thread:

```swift
import ConcurrencyExtras

@Test func deterministic() async {
    await withMainSerialExecutor {
        let vm = ViewModel()
        await vm.loadData()
        // Every suspension point resolves deterministically
        #expect(vm.state == .loaded)
    }
}
```

How it works: temporarily overrides the global executor so all tasks enqueue on the main serial executor. Suspension still works (tasks can interleave at `await` points), but execution order becomes deterministic.

**When to use**: Tests that verify ordering of state changes across suspension points, actor interactions, or task group behavior.

**When NOT to use**: Tests that specifically validate concurrent behavior (race resilience, parallel performance). For those, use the default executor and make weaker assertions.

### 4.2 Two-Test Strategy

For complex concurrent systems, write both:

1. **Deterministic tests** (wrapped in `withMainSerialExecutor`): verify core logic, state transitions, ordering guarantees
2. **Concurrent tests** (default executor): verify the system handles real concurrency gracefully, with looser assertions

---

## 5. Testing Time-Dependent Code with swift-clocks

### 5.1 The Problem

Code using `Task.sleep` or `Clock.sleep` in production makes tests slow and flaky:

```swift
// Production code -- hard to test
func poll() async throws {
    while !cancelled {
        try await Task.sleep(for: .seconds(30))
        await refresh()
    }
}
```

### 5.2 The Solution: Inject a Clock

```swift
// Testable production code
func poll(clock: some Clock<Duration> = ContinuousClock()) async throws {
    while !cancelled {
        try await clock.sleep(for: .seconds(30))
        await refresh()
    }
}
```

### 5.3 TestClock in Tests

```swift
import Clocks

@Test func pollRefreshes() async {
    let clock = TestClock()
    let model = Model(clock: clock)

    Task { await model.poll(clock: clock) }

    await clock.advance(by: .seconds(30))
    #expect(model.refreshCount == 1)

    await clock.advance(by: .seconds(30))
    #expect(model.refreshCount == 2)
}
```

The test runs instantly -- no real waiting. `TestClock.advance(by:)` moves time forward deterministically.

---

## 6. Protocol-Based Injection for Testable Actors

### 6.1 The Pattern

Define a protocol for the dependency, not the actor itself:

```swift
protocol DataFetching: Sendable {
    func fetch(id: String) async throws -> Data
}

actor DataManager {
    private let fetcher: any DataFetching
    init(fetcher: any DataFetching) { self.fetcher = fetcher }

    func load(id: String) async throws -> Model {
        let data = try await fetcher.fetch(id: id)
        return try Model(data: data)
    }
}
```

### 6.2 Mock in Tests

```swift
struct MockFetcher: DataFetching {
    var result: Result<Data, Error>
    func fetch(id: String) async throws -> Data {
        try result.get()
    }
}

@Test func loadSuccess() async throws {
    let fetcher = MockFetcher(result: .success(testData))
    let manager = DataManager(fetcher: fetcher)
    let model = try await manager.load(id: "1")
    #expect(model.isValid)
}
```

### 6.3 Testing AsyncSequence Producers

For code that produces values over time:

```swift
protocol EventStreaming: Sendable {
    func events() -> AsyncStream<Event>
}

// In tests: provide a controlled stream
struct MockEventStream: EventStreaming {
    let values: [Event]
    func events() -> AsyncStream<Event> {
        AsyncStream { cont in
            for v in values { cont.yield(v) }
            cont.finish()
        }
    }
}
```

---

## 7. Thread Sanitizer as a Testing Tool

### 7.1 Enabling TSan

In Xcode: Edit Scheme > Run > Diagnostics > Thread Sanitizer.

For CI (xcodebuild):
```bash
xcodebuild test \
    -scheme MyApp \
    -enableThreadSanitizer YES \
    -destination 'platform=macOS'
```

For SwiftPM:
```bash
swift test --sanitize=thread
```

### 7.2 Known Limitations (as of 2025)

TSan has **known false positives with Swift concurrency**:
- Actor-isolated access sometimes triggers false reports
- `Mutex` from Swift 6 may not be recognized by TSan's synchronization model
- Code coverage instrumentation (`__llvm_gcov_ctr`) generates spurious warnings

**Skill guidance**: TSan is valuable but not definitive with modern Swift concurrency. A clean TSan run does NOT guarantee absence of races. A TSan report on actor-isolated code may be a false positive. TSan is most reliable for:
- GCD-based code
- Lock-based synchronization (`os_unfair_lock`, `NSLock`)
- Mixed old/new codebases where the boundary is the likely bug site

### 7.3 CI Integration

- Run TSan as a **separate CI job** (it adds 5-10x overhead)
- Use a suppression file for known false positives rather than disabling TSan entirely
- Combine with `-enableCodeCoverage NO` to avoid coverage-related false positives

---

## 8. Common Testing Mistakes

### 8.1 Tests That Pass Locally, Fail in CI

**Cause**: Timing assumptions. Local machine is fast enough that races don't manifest.

**Fix**: Use `withMainSerialExecutor` for deterministic tests. For integration tests, use generous timeouts and assert on eventual state, not intermediate states.

### 8.2 Tests That Don't Actually Test Concurrency

```swift
// BAD: This is accidentally serial
@Test func testConcurrent() async {
    let result1 = await service.fetch(id: "1")
    let result2 = await service.fetch(id: "2")
    // These run sequentially -- no concurrency tested
}

// GOOD: Actually concurrent
@Test func testConcurrent() async {
    async let r1 = service.fetch(id: "1")
    async let r2 = service.fetch(id: "2")
    let (result1, result2) = await (r1, r2)
}
```

### 8.3 Missing await in Assertions

```swift
// WRONG: compiler error in Swift 6 (accessing actor property without await)
let value = counter.value

// RIGHT
let value = await counter.value
#expect(value == 42)
```

### 8.4 Non-Sendable Closures in Test Helpers

```swift
// BAD: captures mutable state across isolation boundary
var count = 0
await confirmation(expectedCount: 3) { confirm in
    count += 1  // WARNING: mutation of captured var in Sendable closure
    confirm()
}

// GOOD: use the confirmation mechanism, not shared mutable state
await confirmation(expectedCount: 3) { confirm in
    sut.onEvent = { confirm() }
    sut.run()
}
```

### 8.5 Deadlocking with wait(for:) in Async Context

```swift
// DEADLOCK: wait(for:) blocks the thread that async code needs
func testBad() async {
    let exp = expectation(description: "done")
    Task { exp.fulfill() }
    wait(for: [exp], timeout: 1)  // blocks cooperative thread pool
}

// FIX: use await fulfillment(of:)
func testGood() async {
    let exp = expectation(description: "done")
    Task { exp.fulfill() }
    await fulfillment(of: [exp], timeout: 1)
}
```

---

## 9. Decision Tree: Which Testing Approach?

```
What are you testing?
│
├─ Pure async/await function
│  └─ Mark test async, use await, assert result directly
│
├─ Actor state changes
│  └─ Mark test async, access state via await
│     └─ Need deterministic ordering? → withMainSerialExecutor
│
├─ @MainActor-isolated code
│  └─ Mark test @MainActor + async
│
├─ Callback/delegate API
│  ├─ Swift Testing → confirmation(expectedCount:)
│  └─ XCTest → XCTestExpectation + await fulfillment(of:)
│
├─ Time-dependent code (debounce, polling, timeout)
│  └─ Inject Clock protocol, use TestClock in tests
│
├─ Race condition resilience
│  └─ Two-test strategy:
│     ├─ Deterministic: withMainSerialExecutor + exact assertions
│     └─ Concurrent: default executor + loose assertions + stress runs
│
├─ AsyncSequence/AsyncStream consumer
│  └─ Inject protocol, provide mock stream with known values
│     └─ Swift Testing: confirmation(expectedCount:) for value counting
│
└─ Legacy GCD / lock-based code
   └─ TSan in CI + XCTestExpectation with generous timeouts
```

---

## 10. CI Configuration Recommendations

### Xcode Cloud / GitHub Actions Template

```yaml
# Separate job for TSan -- runs slower, catches different bugs
tsan-tests:
  steps:
    - xcodebuild test
        -scheme MyApp
        -enableThreadSanitizer YES
        -enableCodeCoverage NO   # avoid TSan false positives
        -destination 'platform=macOS'

# Main test job -- fast, deterministic
unit-tests:
  steps:
    - xcodebuild test
        -scheme MyApp
        -destination 'platform=macOS'
        -resultBundlePath TestResults.xcresult
```

### Recommended CI Settings

| Setting              | Value              | Rationale                                             |
| -------------------- | ------------------ | ----------------------------------------------------- |
| TSan                 | Separate job       | 5-10x slower; don't gate every PR on it               |
| Test timeout         | 2-5 minutes/suite  | Catch hung async tests; `.timeLimit` in Swift Testing |
| Parallelism          | Default (parallel) | Surfaces hidden test ordering dependencies            |
| Code coverage + TSan | Never together     | Coverage instrumentation creates TSan false positives |
| Retry flaky          | 0 retries          | Fix flaky tests, don't mask them                      |

---

## 11. Template Test Code

### Template: Testing an Actor

```swift
@Test func actorStateTransition() async {
    let cache = Cache()                    // actor
    await cache.store("key", value: data)
    let retrieved = await cache.get("key")
    #expect(retrieved == data)
}
```

### Template: Testing @MainActor ViewModel

```swift
@Test @MainActor func viewModelLoads() async throws {
    let vm = ViewModel(service: MockService())
    try await vm.load()
    #expect(vm.items.count == 3)
    #expect(vm.isLoading == false)
}
```

### Template: Testing AsyncStream Consumer

```swift
@Test func processesAllEvents() async {
    let events: [Event] = [.a, .b, .c]
    let stream = AsyncStream { cont in
        for e in events { cont.yield(e) }
        cont.finish()
    }

    var processed: [Event] = []
    for await event in stream {
        processed.append(event)
    }
    #expect(processed == events)
}
```

### Template: Deterministic Actor Interaction

```swift
@Test func coordinatedActors() async {
    await withMainSerialExecutor {
        let producer = Producer()
        let consumer = Consumer(source: producer)

        await producer.emit(.data("hello"))
        await consumer.process()

        let result = await consumer.lastProcessed
        #expect(result == .data("hello"))
    }
}
```

---

## 12. Key Dependencies for the Skill to Reference

| Package                     | Purpose                                   | When to Recommend                     |
| --------------------------- | ----------------------------------------- | ------------------------------------- |
| `swift-concurrency-extras`  | `withMainSerialExecutor`, `LockIsolated`  | Deterministic actor/async testing     |
| `swift-clocks`              | `TestClock` for time control              | Debounce, polling, timeout testing    |
| Swift Testing (built-in)    | `confirmation`, `withKnownIssue`, `@Test` | All new test code                     |
| XCTest (built-in)           | `XCTestExpectation`, `fulfillment(of:)`   | Existing test suites, legacy bridging |
| Thread Sanitizer (built-in) | Runtime race detection                    | CI, GCD/lock code, mixed codebases    |
