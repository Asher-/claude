# Cutting-Edge Concurrent Programming (2020-2025)

Research on recent advances in concurrent programming, with emphasis on Apple platforms and Swift.

---

## 1. Swift Concurrency

### async/await and the Cooperative Thread Pool

Swift 5.5 (2021) introduced async/await, backed by a **cooperative thread pool** rather than traditional GCD dispatch queues. The pool creates only as many threads as CPU cores, preventing thread explosion. When a task hits an `await` suspension point, its thread is freed for other tasks -- thousands of concurrent tasks run on a handful of threads. Internally, the compiler transforms async functions into state machines with continuations that can pause and resume. (SwiftRocks, "How async/await works internally in Swift"; van der Lee, "Threads vs. Tasks in Swift Concurrency", SwiftLee 2024)

Key properties:
- Suspension points are **explicit** (every `await`); between suspension points, execution is synchronous
- Tasks inherit the caller's actor context (unless detached)
- `withCheckedContinuation` / `withUnsafeContinuation` bridge callback-based APIs into async/await
- The cooperative pool is a completely separate mechanism from GCD's `DispatchQueue` system

### Structured Concurrency: TaskGroup, async let, Cancellation

Structured concurrency ensures every async task has a parent and a well-defined lifetime. Two primary mechanisms:

- **`async let`** -- fork-join for a known number of concurrent operations
- **`withTaskGroup` / `withThrowingTaskGroup`** -- dynamic fan-out with an arbitrary number of child tasks; conforms to `AsyncSequence` for result collection

Task cancellation is **cooperative**: calling `task.cancel()` sets a flag; the task must check `Task.isCancelled` or call `try Task.checkCancellation()` to respond. Child tasks inherit cancellation from parents. (SE-0304: Structured Concurrency; van der Lee, "Task Groups in Swift", SwiftLee 2024)

Bounded concurrency pattern: fill a task group to max capacity, then follow a one-in-one-out pattern using `group.next()` to limit parallelism.

### Actors and Actor Isolation

Actors provide **mutual exclusion without explicit locks**. Each actor serializes access to its mutable state -- only one task executes on an actor at a time. Cross-actor calls require `await` because they may suspend.

**Actor reentrancy** is the primary pitfall: when an actor method suspends at an `await`, another task can execute on the same actor before the first resumes. State may change between suspension points, invalidating earlier checks. Mitigation: perform all state mutations synchronously before any `await`, or move `await` calls to the beginning of methods. (Bartlett, "Advanced Swift Actors: Re-entrancy & Interleaving", 2024; Tsai, "Actor Reentrancy in Swift", 2024)

### Sendable and @Sendable

The `Sendable` protocol (SE-0302) marks types safe to pass across concurrency boundaries. Value types, actors, and immutable classes are `Sendable` by default. `@Sendable` marks closures that cannot capture mutable local state.

Recent evolution:
- **SE-0418**: Compiler infers `@Sendable` for methods of `Sendable` types (unapplied/partially-applied)
- **`sending` keyword** (SE-0430): marks parameters/results that transfer ownership across isolation domains, more flexible than requiring full `Sendable` conformance
- **`@unchecked Sendable`**: escape hatch for types you know are safe but the compiler cannot verify; use sparingly (Wals, "Sending vs Sendable in Swift", 2024; Fat Bob Man, "Sendable, sending and nonsending", 2024)

### @MainActor and Global Actors

`@MainActor` isolates code to the main thread at **compile time** -- the compiler enforces that `@MainActor`-isolated code is only called from the main actor or with `await`. This replaces runtime-only checks like `DispatchQueue.main.async`.

**Custom global actors** (SE-0316) extend the same pattern to arbitrary domains: database access, image processing, file I/O. Declare with `@globalActor struct DatabaseActor { static let shared = ... }`, then annotate types/functions. Useful when multiple unrelated types need synchronized access to a shared resource. (Swift with Majid, "Global actors in Swift", 2024)

### Swift 6 Strict Concurrency (2024)

Swift 6.0 (WWDC 2024) made data-race safety checks **compiler errors** by default. What were optional warnings under `-strict-concurrency=complete` became hard errors. The compiler flags:
- Non-`Sendable` values crossing isolation boundaries
- Mutable shared state without actor isolation
- Missing `@MainActor` annotations on UI code

**Migration path**: minimal -> targeted -> complete checking, then Swift 6 language mode. (Apple, "Adopting strict concurrency in Swift 6 apps"; van der Lee, "Swift 6: Migrating Xcode Projects", 2024)

### Region-Based Isolation (SE-0414)

SE-0414 (accepted 2024) introduces **isolation regions** -- a flow-sensitive analysis that tracks whether non-`Sendable` values can safely cross isolation boundaries. The compiler groups values into regions and proves they do not alias state accessible from another isolation domain. This eliminates many false positives from Swift 5.10's conservative checking, allowing natural patterns that are provably race-free. (Massicotte, "SE-0414: Region based Isolation", 2024; Swift Evolution proposal SE-0414)

### Swift 6.2 Approachable Concurrency (2025)

Swift 6.2 (WWDC 2025) introduced "approachable concurrency" to address widespread developer frustration:

- **`@MainActor` by default**: new Xcode 26 projects isolate all code to the main actor by default. You start single-threaded and opt into concurrency explicitly.
- **`nonisolated(nonsending)`**: nonisolated async functions run on the **caller's executor** by default (not the global pool). This prevents unintentional thread hops.
- **`@concurrent`**: explicit attribute to mark functions that should run on the global concurrent executor (background thread).
- **Isolation inheritance** (SE-0420): functions can adopt isolation context from callers via `#isolation` macro.
- **Inferred isolated conformances**: protocol conformances can be restricted to specific isolation domains.

The mental model shifts from "everything runs anywhere unless you annotate" to "everything is serial unless you opt in to concurrency." (van der Lee, "Approachable Concurrency in Swift 6.2", 2025; Wals, "Setting default actor isolation in Xcode 26", 2025; Massicotte, "Default isolation with Swift 6.2", 2025)

### AsyncSequence and AsyncStream

`AsyncSequence` is the async counterpart to `Sequence`; `AsyncStream` provides a concrete implementation with a continuation-based API for bridging delegate/callback patterns.

Key patterns:
- `AsyncStream.makeStream(of:bufferingPolicy:)` -- modern creation API
- Buffering policies: `.unbounded`, `.bufferingOldest(n)`, `.bufferingNewest(n)`
- Continuation's `yield`, `finish` methods bridge synchronous producers
- Conforms to `for await ... in` iteration

The **Swift Async Algorithms** package extends this with `merge`, `combineLatest`, `debounce`, `throttle`, and other operators -- bridging much of Combine's reactive functionality into native concurrency. (Bartlett, "Advanced Swift Concurrency: AsyncStream"; Swift with Majid, "Discovering Swift Async Algorithms package", 2024)

---

## 2. Synchronization Primitives (Swift 6)

### Mutex (SE-0433)

The `Synchronization` framework (iOS 18 / macOS 15) introduces `Mutex<State>` -- a value-type wrapper around `os_unfair_lock` with a protected state pattern. Unlike actors, `Mutex` is synchronous (no `await`) and works in non-async contexts. It is `Sendable` by design. Declared `let`-only (`@_staticExclusiveOnly`). (Bartlett, "The Synchronisation Framework in Swift 6"; van der Lee, "Modern Swift Lock: Mutex", SwiftLee 2024)

### Atomics

`Atomic<T>` provides lock-free atomic operations for simple types. Both `Mutex` and `Atomic` use the `~Copyable` ownership system for safety guarantees.

**When to use what:**
- `Mutex` -- synchronous protection of compound state; replaces `NSLock`/`os_unfair_lock` boilerplate
- `Actor` -- async protection; natural for state accessed from async contexts
- `Atomic` -- single-value lock-free counters, flags, simple CAS operations

---

## 3. GCD: Modern Role

GCD remains in the runtime but its role has narrowed:

**Where GCD still fits:**
- Legacy codebases not yet migrated to Swift concurrency
- Precise dispatch queue targeting (e.g., specific QoS, custom serial queues for third-party libraries)
- Low-level timing with `DispatchSource` (timers, file descriptors, signals)
- Interop with C/Objective-C APIs that expect dispatch queues

**GCD anti-patterns to flag:**
- Thread explosion from unbounded `DispatchQueue.global().async` calls
- Nested `sync` calls causing deadlocks
- `DispatchSemaphore` used to serialize async work (blocks threads)
- `DispatchGroup` for patterns better served by `TaskGroup`

**Migration mappings:**
| GCD Pattern                    | Modern Replacement                  |
| ------------------------------ | ----------------------------------- |
| `DispatchQueue.main.async`     | `@MainActor` or `MainActor.run`     |
| Serial `DispatchQueue`         | `actor`                             |
| `DispatchGroup`                | `withTaskGroup` / `async let`       |
| `DispatchSemaphore`            | Actor or `AsyncStream` backpressure |
| `DispatchQueue.global().async` | `Task { }` or `@concurrent`         |
| `NSLock` / `os_unfair_lock`    | `Mutex` (Synchronization framework) |

(Bugfender, "Swift Concurrency Guide", 2024; Sheldon Wang, "Complete Guide to Migrating iOS Swift Code to Async/Await", 2025)

---

## 4. Combine and Observation

### Combine's Status

Combine is **not deprecated** but is no longer actively evolved. Apple's direction is clear: new APIs use async/await. Combine remains appropriate for **reactive stream processing** (multi-value over time, complex operator chains). For single-value async operations, prefer async/await. (Swift Forums, "Should AsyncSequence replace Combine?")

The **Swift Async Algorithms** package provides async-native equivalents of many Combine operators, making migration feasible without abandoning stream semantics.

### Observation Framework (@Observable)

The Observation framework (iOS 17+, SE-0395) replaces `ObservableObject`/`@Published` with the `@Observable` macro. Key threading facts:

- `@Observable` is **not thread-safe by default**. The observation tracking is synchronous.
- For SwiftUI, mutations must happen on the main thread (SwiftUI reads properties during view body evaluation on main).
- Pattern: store `@Observable` state in a type, have actors do async work, push results back via `@MainActor`-isolated setters.
- Performance gain: only properties actually read in a view body trigger re-renders (vs. `ObservableObject` which fires for any `@Published` change).

(Fat Bob Man, "New Frameworks, New Mindset", 2024; Swift with Majid, "Mastering Observation framework", 2023)

---

## 5. Tooling

### Thread Sanitizer (TSan)

TSan detects data races at runtime. Known issues with Swift concurrency: **false positives** remain a problem as of 2025, particularly around actor isolation and task-local storage. The Swift community is actively discussing TSan's reliability in the concurrency world. (Swift Forums, "ThreadSanitizer in a Swift Concurrency World", 2025)

### Swift 6.2 Debugging Improvements

- LLDB reliably steps into async functions
- Task context shown at breakpoints (which task, which actor)
- Human-readable task names in debugger and Instruments profiling
- Instruments: Swift Concurrency instrument tracks task creation, suspension, and resumption

### Compile-Time Diagnostics

The strongest tooling advance is making concurrency errors **compile-time** rather than runtime:
- Swift 6 strict concurrency: data race potential = compiler error
- Purple runtime warnings in Xcode for main-thread violations
- Thread Performance Checker (Xcode 14+): detects priority inversions at runtime

---

## 6. Cross-Platform Comparison

### Kotlin Coroutines

Like Swift, Kotlin uses compiler-transformed **suspend functions** with explicit suspension points. Key differences: Kotlin's `CoroutineScope` is more explicit than Swift's structured concurrency; Kotlin lacks compile-time data-race prevention (no `Sendable` equivalent). Both use cooperative scheduling. (Bhatti, "Structured Concurrency in Modern Programming Languages -- Part IV", Medium)

### Java Project Loom (Virtual Threads)

Java 21's virtual threads take the **opposite approach**: implicit suspension via runtime scheduling. Any blocking call (`Thread.sleep`, I/O) automatically yields. No language-level `async`/`await`. Scales to millions of virtual threads. Better for thread-per-request server patterns; less relevant to UI frameworks. (Xebia, "Structured Concurrency: Will Java Loom Beat Kotlin's Coroutines?")

### Rust Ownership Model

Rust's `Send` and `Sync` traits are the closest analog to Swift's `Sendable`. `Send` = safe to transfer across threads; `Sync` = safe to share references. Rust enforces these at compile time via the ownership/borrow system, catching more bugs statically than Swift's current analysis. Swift's region-based isolation (SE-0414) moves in this direction. (Rust Book, "Fearless Concurrency")

### Key Insight for the Skill

Swift's approach is unique in combining **actor isolation** (runtime serialization) with **compile-time Sendable checking** and **structured task lifetimes**. No other mainstream language has all three. The skill should emphasize this combination.

---

## 7. Research Trends

### Lock-Free Data Structures

2024 advances include batch-parallel structures (OBatcher, Multicore OCaml), ML-augmented lock-free search structures, and adaptive runtime structure swapping. Key challenge remains formal correctness proofs. (SPLASH/OOPSLA 2024, "Concurrent Data Structures Made Easy")

### Formal Verification

TLA+ remains the standard for specifying concurrent/distributed algorithms. 2024 advances: AI-assisted specification generation, system execution validation against TLA+ specs (TLA+ Conf 2024), and APALACHE symbolic model checker. Increasingly used in industry for critical concurrent algorithm design. (TLA+ Conf 2024; Alibaba Cloud, "Formal Verification Tool TLA+")

---

## 8. What a Claude Code Skill Needs

### Migration Decision Tree

```
Is this new code?
  YES -> Use Swift concurrency (async/await, actors, TaskGroup)
  NO  -> Is it GCD-based?
    YES -> Can you migrate incrementally?
      YES -> Wrap callbacks with withCheckedContinuation
             Replace DispatchGroup with TaskGroup
             Replace serial queues with actors
             Replace DispatchQueue.main with @MainActor
      NO  -> Keep GCD, ensure no anti-patterns
    NO  -> Is it NSThread/pthread based?
      YES -> Migrate to actors or Task {}
```

### Common Swift Concurrency Mistakes

1. **Actor reentrancy bugs**: checking state, awaiting, then acting on stale state
2. **Forgetting `@MainActor`** on UI-mutating code (runtime crash or silent corruption)
3. **`Task.detached` misuse**: loses actor context, priority, and cancellation
4. **Blocking the cooperative pool**: calling synchronous blocking APIs (semaphore.wait, Thread.sleep) inside async contexts starves the pool
5. **`@unchecked Sendable` overuse**: silences the compiler without fixing the race
6. **Unnecessary MainActor hops**: `await MainActor.run` when already on `@MainActor`
7. **Ignoring cancellation**: async work continues after task is cancelled
8. **Unbounded TaskGroup**: spawning millions of child tasks without throttling

### When to Use Which Primitive

| Need                                  | Primitive                         |
| ------------------------------------- | --------------------------------- |
| Single async operation                | `async let` or `Task { }`         |
| Fan-out N operations                  | `withTaskGroup`                   |
| Protect mutable state (async context) | `actor`                           |
| Protect mutable state (sync context)  | `Mutex` (Synchronization)         |
| UI thread safety                      | `@MainActor`                      |
| Cross-domain synchronization          | Custom global actor               |
| Reactive streams                      | `AsyncSequence` / `AsyncStream`   |
| Simple atomic counter/flag            | `Atomic` (Synchronization)        |
| Bridge callback API                   | `withCheckedContinuation`         |
| Legacy code interop                   | GCD with careful queue management |

---

## Gaps

1. **Swift 6.2 real-world adoption data** -- too new (WWDC 2025) to have broad migration experience reports
2. **TSan + Swift concurrency reliability** -- active discussion, unclear when false positives will be resolved
3. **Custom executor patterns** -- SE-0392 (custom actor executors) is accepted but real-world patterns are underexplored
4. **Task-local values** -- threading of context (tracing, logging) through task hierarchies; needs deeper coverage
5. **Distributed actors** -- Swift's distributed actor system for cross-process/network isolation; out of scope per README but adjacent
6. **Performance benchmarks** -- cooperative pool vs GCD throughput in real macOS apps; mostly anecdotal data
7. **Instruments Swift Concurrency template** -- detailed walkthrough of the profiling workflow is sparse in public sources
8. **Interaction between @Observable and actors** -- patterns for combining these correctly are still emerging
