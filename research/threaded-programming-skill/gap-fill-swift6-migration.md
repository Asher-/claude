# Gap Fill: Swift 6/6.2 Migration Recipes

Phase 3 research for the threaded programming skill. Addresses gap #3 from synthesis.md:
concrete compiler errors, fixes, migration strategies, and Swift 6.2 behavioral changes.

---

## 1. Error-to-Fix Lookup Table

### Error: "Capture of non-sendable type 'X' in @Sendable closure"

**Trigger**: Passing a non-Sendable value into a closure that crosses isolation boundaries (Task, DispatchQueue.async, etc.).

```swift
class MyModel { var data = [String]() }

func process() {
    let model = MyModel()
    Task { print(model.data) }  // ERROR
}
```

**Correct fixes** (pick based on context):
1. Make the type Sendable: `final class MyModel: Sendable` (only if truly immutable)
2. Make it a struct (value types are Sendable when all stored properties are)
3. Use an actor instead: `actor MyModel { var data = [String]() }`
4. Use `sending` parameter (SE-0430): transfer ownership so compiler can prove safety
5. Extract Sendable values before the closure: capture `let snapshot = model.data` then use snapshot

**Wrong fix**: Slapping `@unchecked Sendable` on a mutable class. This silences the error but the data race remains.

### Error: "Main actor-isolated property 'X' cannot be mutated from a non-isolated context"

**Trigger**: Accessing a @MainActor property from a non-isolated function or a different actor.

```swift
@MainActor class ViewModel {
    var title = ""
}

func update(vm: ViewModel) {
    vm.title = "New"  // ERROR
}
```

**Correct fixes**:
1. Mark the calling function `@MainActor`: `@MainActor func update(vm:)`
2. Use `await`: `await MainActor.run { vm.title = "New" }`
3. If inside an async context, `await vm.title = "New"` (the await switches to main actor)
4. In Swift 6.2 with `defaultIsolation(MainActor.self)`, the function is MainActor by default -- no annotation needed

**Wrong fix**: Making the property `nonisolated`. This removes the protection, doesn't fix the race.

### Error: "Static property 'X' is not concurrency-safe because it is nonisolated global shared mutable state"

**Trigger**: Any `static var` on a non-Sendable type, or a global `var`.

```swift
class Logger {
    static var shared = Logger()  // ERROR: static var is mutable global state
}
```

**Correct fixes** (in order of preference):
1. Make it `static let` if the instance is constant: `static let shared = Logger()`
2. Make the type Sendable: `final class Logger: Sendable` (requires all properties be Sendable and immutable)
3. Isolate to a global actor: `@MainActor static var shared = Logger()`
4. Use `nonisolated(unsafe)` as a last resort: `nonisolated(unsafe) static var shared = Logger()`

**Wrong fix**: `@unchecked Sendable` on the type when it has mutable state. The `let` + Sendable type approach is the real fix.

**Note on singletons**: The common `static let shared` pattern is fine as long as the type itself is Sendable. If it has mutable state, wrap it in a Mutex or make it an actor.

### Error: "Global variable 'X' is not concurrency-safe because it is nonisolated global shared mutable state"

Same root cause as the static property error. A module-level `var` is globally mutable.

```swift
var currentConfig = AppConfig()  // ERROR
```

**Correct fixes**: Same as above. Prefer `let`, or isolate to `@MainActor`, or wrap in an actor/Mutex.

### Error: "Sending value of non-Sendable type 'X' risks causing data races"

**Trigger**: The compiler detects that a non-Sendable value might be accessed from multiple isolation domains after being sent.

```swift
func loadData() async -> MyModel {
    let model = MyModel()
    await populate(model)
    return model  // ERROR: sending non-Sendable return value
}
```

**Correct fixes**:
1. Mark the return as `sending`: `func loadData() async -> sending MyModel` (SE-0430). This tells the compiler to verify safety at the call site.
2. Make MyModel Sendable (struct or final class with Sendable properties)
3. Use an actor to own the data and return Sendable projections

### Error: "Task-isolated value of type 'X' passed as a strongly transferred parameter"

**Trigger**: A value created inside a Task is passed out where it could be accessed concurrently.

**Fix**: Same strategies as above -- `sending`, Sendable conformance, or restructure to avoid passing the value across boundaries.

### Error: "Actor-isolated property 'X' cannot be referenced from a @Sendable closure"

**Trigger**: Capturing actor-isolated state in a closure that may execute concurrently.

```swift
@MainActor class ViewModel {
    var items: [Item] = []
    func refresh() {
        Task.detached {
            let data = self.items  // ERROR
        }
    }
}
```

**Correct fixes**:
1. Don't use `Task.detached` unless you actually need a new isolation context. Use `Task { }` which inherits actor isolation.
2. Copy the value before the closure: `let snapshot = items; Task.detached { use(snapshot) }`
3. Access with await: `Task.detached { let data = await self.items }`

---

## 2. Swift 6.2 Behavioral Changes

### MainActor-by-Default (SE-0466)

**What it does**: All declarations in the module are implicitly `@MainActor` unless explicitly marked otherwise.

**How to enable**:
- Xcode: Build Settings > "Default Actor Isolation" > MainActor
- Package.swift: `.defaultIsolation(MainActor.self)` in swiftSettings

**What changes**: Functions, classes, structs, and enums are all MainActor-isolated. Background work requires explicit `@concurrent` or `nonisolated`.

**Who should use it**: App targets, UI packages. NOT general-purpose libraries or networking layers.

### nonisolated(nonsending) by Default (SE-0461)

**What it does**: Nonisolated async functions now run on the caller's executor by default (instead of hopping to the global concurrent executor).

**How to enable**: `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`

**The key behavioral change**: In Swift 6.0/6.1, a `nonisolated async` function always ran on a background thread. In 6.2 with this flag, it stays on whatever actor called it.

**Before (Swift 6.1)**:
```swift
nonisolated func loadPhotos() async -> [Photo] {
    // Always runs on background thread, even if called from MainActor
}
```

**After (Swift 6.2 with flag)**:
```swift
nonisolated func loadPhotos() async -> [Photo] {
    // Runs on caller's actor. If called from MainActor, runs on main thread.
    // This is nonisolated(nonsending) implicitly.
}
```

**To explicitly run on background**: Mark function `@concurrent`:
```swift
@concurrent
nonisolated func loadPhotos() async -> [Photo] {
    // Always runs off the caller's actor
}
```

### InferIsolatedConformances (SE-0470)

Protocol conformances on @MainActor types are automatically inferred as isolated conformances. Reduces boilerplate where you had to explicitly annotate protocol conformance isolation.

### InferSendableFromCaptures

Compiler automatically infers `@Sendable` for closures and key path literals when it can prove safety from the captured values. Reduces manual `@Sendable` annotations.

### All Five Feature Flags

```swift
// Package.swift swiftSettings for full approachable concurrency
.enableUpcomingFeature("DisableOutwardActorInference"),
.enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
.enableUpcomingFeature("InferIsolatedConformances"),
.enableUpcomingFeature("InferSendableFromCaptures"),
.enableUpcomingFeature("NonisolatedNonsendingByDefault")
```

---

## 3. Migration Strategies

### Incremental Concurrency Checking Ladder

1. **Swift 5 mode, StrictConcurrency = minimal** (default): Almost no checking. Starting point.
2. **Swift 5 mode, StrictConcurrency = targeted**: Checks code that uses concurrency features. Warnings only.
3. **Swift 5 mode, StrictConcurrency = complete**: Full data-race checking, but as warnings.
4. **Swift 6 mode**: Same checks as complete, but now errors.

**Strategy**: Climb one rung at a time. Fix all warnings before moving up. In a multi-module project, migrate leaf modules first (those with no internal dependencies).

### Per-File / Per-Module Tools

**@preconcurrency import**: Suppresses Sendable warnings from a specific module.
```swift
@preconcurrency import SomeFramework
// Types from SomeFramework won't trigger Sendable errors
```
Use for: Third-party libraries that haven't adopted Sendable yet. Apple frameworks that predate concurrency annotations. Plan to remove as dependencies update.

Do NOT use as a blanket fix for all imports. Prefer targeted workarounds over broad suppression.

### Escape Hatches (ranked by danger level)

| Escape Hatch             | Danger Level | When Acceptable                                                       |
| ------------------------ | ------------ | --------------------------------------------------------------------- |
| `@preconcurrency import` | Low          | Dependency hasn't adopted Sendable. Temporary measure.                |
| `nonisolated(unsafe)`    | Medium       | You know it's safe (e.g., written once before any concurrent access). |
| `@unchecked Sendable`    | High         | Type is protected by a lock/Mutex YOU control. Must verify with TSan. |
| `assumeIsolated`         | High         | You know the actor context at runtime but compiler can't prove it.    |

**Rule**: Every escape hatch should have a comment explaining why it's safe. If you can't write that comment, you shouldn't use the escape hatch.

### Sendable Conformance Decision Tree

```
Is the type a value type (struct/enum)?
├── YES: Are all stored properties Sendable?
│   ├── YES → Sendable automatically (compiler synthesizes)
│   └── NO → Make those properties Sendable, or use @unchecked Sendable + Mutex
└── NO (class):
    ├── Is it final with only immutable (let) Sendable properties?
    │   └── YES → Conform to Sendable explicitly: final class X: Sendable
    ├── Is it protected by a lock/Mutex/actor?
    │   └── YES → @unchecked Sendable (document the protection mechanism)
    └── Otherwise → Restructure as actor, or make it a struct
```

---

## 4. Common Migration Patterns

### Completion Handler to async/await

```swift
// BEFORE
func fetchUser(id: String, completion: @escaping (Result<User, Error>) -> Void) {
    URLSession.shared.dataTask(with: url) { data, _, error in
        if let error { completion(.failure(error)); return }
        completion(.success(decode(data!)))
    }.resume()
}

// AFTER
func fetchUser(id: String) async throws -> User {
    let (data, _) = try await URLSession.shared.data(from: url)
    return try decode(data)
}
```

### Wrapping Legacy Callbacks with withCheckedContinuation

```swift
func fetchUser(id: String) async throws -> User {
    try await withCheckedThrowingContinuation { continuation in
        legacyFetchUser(id: id) { result in
            switch result {
            case .success(let user):
                continuation.resume(returning: user)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}
```

**Critical rule**: Resume exactly once on every code path. Missing a resume hangs the caller forever. Double resume crashes at runtime. Use `withCheckedContinuation` (not `withUnsafeContinuation`) during development to get crash-on-misuse diagnostics.

### DispatchQueue.main.async to @MainActor

```swift
// BEFORE
DispatchQueue.main.async { self.label.text = newText }

// AFTER (option A: annotate the enclosing function)
@MainActor func updateUI() { label.text = newText }

// AFTER (option B: explicit switch)
await MainActor.run { label.text = newText }

// AFTER (option C: Task on MainActor from non-isolated code)
Task { @MainActor in label.text = newText }
```

### Serial DispatchQueue to Actor

```swift
// BEFORE
class Cache {
    private let queue = DispatchQueue(label: "cache")
    private var store: [String: Data] = [:]
    func get(_ key: String) -> Data? {
        queue.sync { store[key] }
    }
}

// AFTER
actor Cache {
    private var store: [String: Data] = [:]
    func get(_ key: String) -> Data? { store[key] }
}
```

### NotificationCenter to AsyncSequence

```swift
// BEFORE
NotificationCenter.default.addObserver(self, selector: #selector(handle), name: .didUpdate, object: nil)

// AFTER
for await _ in NotificationCenter.default.notifications(named: .didUpdate) {
    handleUpdate()
}
```

Note: The `for await` loop runs indefinitely. Place it in a `Task` and cancel the task when the observer should stop.

### DispatchSemaphore to Structured Concurrency

**Do NOT use DispatchSemaphore in async contexts.** It blocks a cooperative thread pool thread and can deadlock the entire app.

```swift
// BEFORE: rate-limiting concurrent work
let semaphore = DispatchSemaphore(value: 3)
for item in items {
    semaphore.wait()
    queue.async { process(item); semaphore.signal() }
}

// AFTER: bounded task group
await withTaskGroup(of: Void.self) { group in
    var inFlight = 0
    for item in items {
        if inFlight >= 3 { await group.next(); inFlight -= 1 }
        group.addTask { await process(item) }
        inFlight += 1
    }
}
```

---

## 5. Gotchas and Traps

### withCheckedContinuation: Resume Exactly Once

- Missing resume on an error path = caller hangs forever (no crash, no error, just a leaked task)
- Double resume = runtime crash: "SWIFT TASK CONTINUATION MISUSE: tried to resume its continuation more than once"
- Use `withCheckedThrowingContinuation` for APIs that can fail. The checked variant crashes immediately on misuse; the unsafe variant silently corrupts.

### Actor Reentrancy

Actor methods are NOT atomic across suspension points. State may change between awaits.

```swift
actor Counter {
    var count = 0
    func incrementTwice() async {
        let current = count
        await someAsyncWork()  // Another caller can run here!
        count = current + 1    // BUG: may overwrite a concurrent increment
    }
}
```

**Fix**: Re-read state after suspension, or perform all state mutations before/after awaits, never across them.

### Global Actors on Protocol Conformances

If a protocol method is not isolated, conforming from a @MainActor type creates a conflict. The method must be `nonisolated` or the protocol must opt into the actor.

In Swift 6.2 with `InferIsolatedConformances`, the compiler infers isolated conformances automatically, which resolves many of these errors.

### Sendable Closures Capturing Mutable State

A `@Sendable` closure cannot capture a mutable local variable. The compiler enforces this even if the closure only reads the variable.

```swift
var count = 0
Task { print(count) }  // ERROR: capture of mutable var in @Sendable closure
```

**Fix**: Copy to a `let`: `let snapshot = count; Task { print(snapshot) }`

### Task Cancellation Is Not Automatic

Tasks do not stop when cancelled. Cancellation is cooperative -- your code must check.

```swift
func processAll(_ items: [Item]) async throws {
    for item in items {
        try Task.checkCancellation()  // Throws if cancelled
        await process(item)
    }
}
```

Without explicit checks, a cancelled task runs to completion, wasting resources.

### NonisolatedNonsendingByDefault Conformance Trap

When enabling this Swift 6.2 flag, existing protocol conformances may break. A protocol that expects a `nonisolated` (concurrent) method will conflict with the new default of `nonisolated(nonsending)`. Fix by adding explicit `@concurrent` to methods that must run concurrently.

---

## 6. Migration Decision Tree

```
What Swift language version is the project using?
│
├── Swift 5.x mode
│   ├── Set StrictConcurrency = targeted
│   ├── Fix warnings (focus on Sendable conformances and global state)
│   ├── Set StrictConcurrency = complete
│   ├── Fix remaining warnings
│   └── Switch to Swift 6 language mode
│
├── Swift 6.0/6.1
│   ├── Already have strict concurrency errors as errors
│   ├── Consider enabling Swift 6.2 approachable concurrency flags one at a time
│   ├── Start with InferSendableFromCaptures (least disruptive)
│   ├── Then InferIsolatedConformances (fixes protocol conformance noise)
│   ├── Then NonisolatedNonsendingByDefault (changes runtime behavior -- test thoroughly)
│   └── Then consider defaultIsolation(MainActor.self) for app targets
│
└── New project on Swift 6.2
    ├── Enable defaultIsolation(MainActor.self) for app targets
    ├── Enable all five approachable concurrency flags
    ├── Write sequential code by default
    ├── Add @concurrent only where background execution is needed
    └── Use actors for shared state that lives outside the MainActor
```

---

## 7. Quick-Fix Templates for Top 10 Errors

| #   | Error (abbreviated)                                         | Quick Fix                                                                  |
| --- | ----------------------------------------------------------- | -------------------------------------------------------------------------- |
|   1 | Capture of non-sendable type in @Sendable closure           | Make type Sendable, or capture a Sendable snapshot before the closure      |
|   2 | Main actor-isolated property cannot be mutated from non-iso | Add @MainActor to the calling function, or use `await MainActor.run {}`    |
|   3 | Static property is not concurrency-safe                     | Change `static var` to `static let`, or add `@MainActor`                   |
|   4 | Global variable is not concurrency-safe                     | Change to `let`, or wrap in actor, or `nonisolated(unsafe)` + comment      |
|   5 | Sending value of non-Sendable type risks data races         | Add `sending` to the parameter/return, or make the type Sendable           |
|   6 | Non-sendable type returned from actor-isolated function     | Mark return as `sending`, or make the type Sendable                        |
|   7 | Actor-isolated property cannot be referenced from @Sendable | Copy value to local `let` before closure, or use `Task {}` not `.detached` |
|   8 | Call to MainActor-isolated function in synchronous context  | Make caller @MainActor, or wrap in `Task { @MainActor in }`                |
|   9 | Reference to var is not concurrency-safe (mutable capture)  | Copy to `let snapshot` before the closure                                  |
|  10 | Protocol conformance requires nonisolated method            | Add `nonisolated` to method, or enable InferIsolatedConformances (6.2)     |

---

## Sources

- [Swift.org Common Compiler Errors](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/)
- [Swift.org Migration Strategy](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/migrationstrategy/)
- [SE-0430: sending parameter and result values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md)
- [SE-0461: nonisolated(nonsending) by default](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
- [SE-0466: Default Actor Isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
- [SE-0412: Strict concurrency for global variables](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md)
- [Donny Wals: Solving capture of non-sendable type](https://www.donnywals.com/solving-capture-of-non-sendable-type-in-sendable-closure-in-swift/)
- [Donny Wals: Exploring concurrency changes in Swift 6.2](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/)
- [Donny Wals: Should you opt-in to Swift 6.2 MainActor isolation](https://www.donnywals.com/should-you-opt-in-to-swift-6-2s-main-actor-isolation/)
- [SwiftLee: Approachable Concurrency in Swift 6.2](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/)
- [SwiftLee: Default Actor Isolation in Swift 6.2](https://www.avanderlee.com/concurrency/default-actor-isolation-in-swift-6-2/)
- [SwiftLee: Concurrency-safe global variables](https://www.avanderlee.com/concurrency/concurrency-safe-global-variables-to-prevent-data-races/)
- [Donny Wals: Using singletons in Swift 6](https://www.donnywals.com/using-singletons-in-swift-6/)
- [Matt Massicotte: Default isolation in Swift 6.2](https://www.massicotte.org/default-isolation-swift-6_2/)
- [Fat Bob Man: Sendable, sending, and nonsending](https://fatbobman.com/en/posts/sendable-sending-nonsending/)
