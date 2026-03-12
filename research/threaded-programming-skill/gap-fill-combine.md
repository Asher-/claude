# Gap Fill: Combine Threading Model

Phase 3 research for the threaded-programming skill. Covers Combine's scheduler semantics,
thread safety of its types, interop with Swift concurrency, SwiftUI integration, and common bugs.

---

## 1. Combine's Threading Model

### Default Behavior: No Scheduler Guarantee

Combine operators run on **whatever thread the upstream emits from**. There is no default
scheduler. If a `PassthroughSubject` is sent to from thread X, every downstream operator
and subscriber runs on thread X unless a scheduler operator intervenes.

This is the single most important thing to understand: **Combine does not hop threads
unless you explicitly tell it to.**

### receive(on:) -- Moves Downstream to a Scheduler

```swift
publisher
    .map { transform($0) }         // runs on upstream's thread
    .receive(on: DispatchQueue.main) // hops HERE
    .sink { value in                // runs on main thread
        updateUI(value)
    }
```

- Affects **everything downstream** of where it's placed.
- Can be used multiple times in a chain; each one changes the downstream scheduler.
- Does NOT affect upstream operators (map, filter, etc. above it still run on the upstream thread).

### subscribe(on:) -- Moves Subscription Upstream

```swift
publisher
    .subscribe(on: DispatchQueue.global())  // subscription created on background queue
    .receive(on: DispatchQueue.main)
    .sink { value in updateUI(value) }
```

- Controls where **subscription, cancellation, and request** operations happen upstream.
- Does NOT reliably control where values are delivered downstream -- that's a side effect.
- **Common misconception**: developers use `subscribe(on:)` thinking it controls delivery
  thread. It does not. Use `receive(on:)` for that.

### The Confusion Matrix

| Goal                                    | Correct Operator         |
| --------------------------------------- | ------------------------ |
| Receive values on main thread           | `receive(on: .main)`     |
| Start subscription work on a background | `subscribe(on: .global)` |
| Both                                    | Both, in that order      |
| Control where map/filter run            | Neither -- they inherit  |

### DispatchQueue as Scheduler

`DispatchQueue.main` is the most common scheduler. Values are dispatched via
`DispatchQueue.main.async`, which means delivery is always asynchronous (even if already
on main thread). This introduces a one-runloop-cycle delay.

### RunLoop as Scheduler

`RunLoop.main` as a Combine scheduler only executes in the **default run loop mode**.
During scrolling or tracking (which switches to `UITrackingRunLoopMode`), delivery pauses.
This means `receive(on: RunLoop.main)` can silently delay updates during user interaction.

**Rule**: Use `DispatchQueue.main` unless you have a specific reason to align with run loop
modes. `RunLoop.main` is a niche choice.

### ImmediateScheduler (Testing)

Combine's built-in `ImmediateScheduler` has its own associated types, making it incompatible
as a drop-in replacement for `DispatchQueue` or `RunLoop`. Point-Free's `combine-schedulers`
library solves this with `DispatchQueue.immediate`, `RunLoop.immediate`, etc. -- same associated
types as the real scheduler, but executes synchronously. Essential for deterministic tests.

Limitation: `ImmediateScheduler` cannot test timing-dependent operators (`debounce`, `throttle`,
`Timer.Publisher`). Use `TestScheduler` for those.

---

## 2. Thread Safety of Combine Types

### Publishers: Generally Safe

Most publishers are value types (structs). They describe a computation but don't hold mutable
state, so copying and using them across threads is safe. Custom publishers with reference
semantics require manual synchronization.

### Subjects: send() Is Thread-Safe (With Caveats)

Both `PassthroughSubject` and `CurrentValueSubject` use `os_unfair_lock` internally to
serialize concurrent `send()` calls. Concurrent sends from multiple threads will not corrupt
internal state, and downstream closures will never be invoked concurrently from the same subject.

**Caveats**:
- **Cross-thread re-entrancy deadlocks**: If thread A is inside a `send()` and its downstream
  synchronously triggers a `send()` on thread B that blocks on the same subject's lock, deadlock.
- **Ordering is not guaranteed** under concurrent sends. If threads A and B both send, the
  order of delivery is non-deterministic.
- **Cancellation race**: Cancelling a subscription while a scheduled async delivery is in flight
  does not reliably prevent that delivery from arriving.

### @Published: Main Thread Requirement

`@Published` wraps a `CurrentValueSubject` internally. In SwiftUI, setting a `@Published`
property on an `ObservableObject` from a background thread triggers the runtime warning:

> "Publishing changes from background threads is not allowed"

**Why**: `ObservableObject`'s `objectWillChange` publisher fires synchronously on property set.
SwiftUI subscribes to this publisher and expects it on the main thread. The warning is a
runtime check (not a compile-time error), which means it only fires when the code actually
executes off-main.

**How to fix**:
```swift
// Option 1: Wrap the assignment
DispatchQueue.main.async { self.result = newValue }

// Option 2: receive(on:) in the pipeline feeding the property
cancellable = networkPublisher
    .receive(on: DispatchQueue.main)
    .assign(to: &$result)

// Option 3 (best): Make the class @MainActor
@MainActor
class ViewModel: ObservableObject {
    @Published var result: String = ""
}
```

### Subscribers: Thread Affinity

`Subscribers.Sink` and `Subscribers.Assign` have no internal thread safety. They execute on
whatever thread values arrive on. If you need main-thread execution, you must ensure it via
`receive(on:)` upstream.

`Subscribers.Assign` writes directly to an object's property. If that object is not thread-safe
(most aren't), you must guarantee single-thread access.

### AnyCancellable Storage: NOT Thread-Safe

`Set<AnyCancellable>` is a Swift `Set` -- not thread-safe. Calling `.store(in: &cancellables)`
from multiple threads simultaneously is a data race.

**Solutions**:
- Store cancellables only from one thread (typically main).
- Protect with a lock (`NSLock`, `os_unfair_lock`, or actor isolation).
- If using actors, store the set inside the actor.

---

## 3. Combine + Swift Concurrency Interop

### AsyncPublisher / publisher.values

```swift
for await value in somePublisher.values {
    process(value)
}
```

`publisher.values` returns an `AsyncPublisher` conforming to `AsyncSequence`. This was the
last update Apple shipped for Combine (2021).

**Critical bug**: `publisher.values` can **miss events**, especially with `PassthroughSubject`.

Mechanism: The `for-await` loop must be actively waiting before events are sent. If the
subject sends synchronously before the async iteration starts, those events are lost. Even
with proper timing, rapid sends can outpace the async bridge -- tested cases show ~94% of
events received vs 100% with a regular `sink`.

**Workaround**: Bridge through `AsyncStream` with explicit buffering:
```swift
extension Publisher where Failure == Never {
    var stream: AsyncStream<Output> {
        AsyncStream { continuation in
            let cancellable = self.sink(
                receiveCompletion: { _ in continuation.finish() },
                receiveValue: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
```

### Combine Closures + Actor Isolation (Swift 6 Crash)

In Swift 6, closures passed to Combine operators (`sink`, `filter`, `map`) inherit the
surrounding actor isolation. The compiler inserts runtime assertions that the closure runs
on the expected executor. But Combine delivers values on arbitrary threads, violating the
assertion and **crashing at runtime**.

```swift
// Swift 6: This crashes if values arrive off-main
@MainActor
func setup() {
    publisher
        .sink { value in  // closure inherits @MainActor isolation
            self.handle(value)  // runtime assertion: must be on main queue
        }
        .store(in: &cancellables)
}
```

**Fixes**:
1. Add `@Sendable` to clear inherited isolation: `.sink { @Sendable value in ... }`
2. Add `receive(on: DispatchQueue.main)` before the closure operator.
3. Migrate to async alternatives entirely.

### receive(on: .main) vs @MainActor

| Aspect                 | `receive(on: .main)`              | `@MainActor`                  |
| ---------------------- | --------------------------------- | ----------------------------- |
| Enforcement            | Runtime only                      | Compile-time + runtime        |
| Applies to             | Downstream Combine operators      | Entire function/class         |
| Works with async/await | No                                | Yes                           |
| Combine-aware          | Yes                               | No -- Combine predates actors |
| Swift 6 safe           | Partially (no compile-time check) | Yes                           |

**Decision**: For new code, prefer `@MainActor`. For existing Combine pipelines that can't
be rewritten, `receive(on: DispatchQueue.main)` remains the practical choice.

### Future: Is Combine Being Replaced?

Combine is **not deprecated** but receives no new features. Apple's direction is clear:
- `AsyncSequence` + `AsyncStream` replace publisher chains.
- Swift Async Algorithms package provides `merge`, `combineLatest`, `debounce`, etc.
- `Notification.notifications(named:)` replaces `NotificationCenter.publisher(for:)`.
- `@Observable` replaces `ObservableObject` + `@Published` (no Combine dependency).

Combine will persist in existing codebases for years. The skill must handle both.

---

## 4. Combine + SwiftUI

### @Published + ObservableObject Threading

The contract: `objectWillChange` (fired by `@Published` setters) must be on the main thread.
SwiftUI's view update mechanism subscribes to this publisher and assumes main-thread delivery.

Pattern for network calls:
```swift
class ViewModel: ObservableObject {
    @Published var items: [Item] = []

    func load() {
        URLSession.shared.dataTaskPublisher(for: url)
            .decode(type: [Item].self, decoder: JSONDecoder())
            .receive(on: DispatchQueue.main)  // REQUIRED before assign
            .assign(to: &$items)
    }
}
```

### @Observable vs @ObservableObject Threading

| Behavior                   | `ObservableObject` + `@Published` | `@Observable`                  |
| -------------------------- | --------------------------------- | ------------------------------ |
| Framework                  | Combine                           | Observation (iOS 17+)          |
| Main-thread requirement    | Yes (runtime warning)             | Yes (but no automatic warning) |
| Compiler enforcement       | None                              | None (unless `@MainActor`)     |
| Background update behavior | Warning, potential crash          | Silent race condition, crash   |
| Recommended isolation      | `@MainActor` on class             | `@MainActor` on class          |

**Key difference**: `@Observable` does NOT emit a runtime warning when mutated off-main.
It simply causes a race condition or crash silently. This makes `@MainActor` annotation
even more important with `@Observable` than with `ObservableObject`.

---

## 5. Common Combine Threading Bugs

### Bug 1: Forgetting receive(on: .main) Before UI Updates

Most common Combine threading bug. The `sink` or `assign` subscriber updates UI state from
a background thread because no scheduler operator was added.

**Fix**: Always add `.receive(on: DispatchQueue.main)` as the last operator before a
subscriber that touches UI state.

### Bug 2: subscribe(on:) Misuse

Developers write `.subscribe(on: DispatchQueue.global())` thinking it makes the sink run
on a background queue. It does not. It affects subscription management upstream only.

### Bug 3: Cancellable Retained on Wrong Thread

Storing `AnyCancellable` into a shared `Set` from multiple threads. Often manifests as an
intermittent `EXC_BAD_ACCESS` in `AnyCancellable.store(in:)`.

**Fix**: Only mutate `Set<AnyCancellable>` from one thread, or protect with a lock.

### Bug 4: Memory Leaks from Strong Reference Cycles

```swift
publisher.sink { [weak self] value in  // [weak self] is essential
    self?.handle(value)
}
```

Without `[weak self]`, the sink closure captures `self` strongly, and the cancellable
(stored in `self.cancellables`) holds the sink. Classic retain cycle.

**Also**: `assign(to:on:)` captures the object strongly. Use `assign(to: &$property)`
(the `@Published` variant) which does NOT create a retain cycle.

### Bug 5: Backpressure and Thread Starvation

Combine uses demand-based backpressure. If a subscriber requests `.unlimited` demand (which
`sink` does by default), a fast upstream can flood the subscriber's thread. With
`receive(on: DispatchQueue.main)`, this means hundreds of blocks dispatched to main queue,
causing UI freezes.

**Fix**: Use `throttle` or `debounce` upstream of `receive(on:)` to limit event rate, or
use `buffer` to absorb bursts.

### Bug 6: Swift 6 Actor Isolation Inheritance

Closures in Combine operators silently inherit `@MainActor` isolation in Swift 6, then
crash when Combine delivers values on background threads. Discussed in Section 3 above.

---

## 6. What the Skill Needs

### Quick Reference: Where Does This Operator Run?

| Operator            | Runs On                                           |
| ------------------- | ------------------------------------------------- |
| `map`, `filter`     | Upstream's thread (inherited)                     |
| `receive(on: X)`    | Schedules downstream onto X                       |
| `subscribe(on: X)`  | Subscription/cancel/request on X (not delivery)   |
| `sink`              | Whatever thread the last upstream value came from |
| `assign`            | Whatever thread the last upstream value came from |
| `debounce(for:on:)` | The specified scheduler                           |
| `throttle(for:on:)` | The specified scheduler                           |
| `delay(for:on:)`    | The specified scheduler                           |
| `merge`, `zip`      | Whichever upstream fires (non-deterministic)      |

### Decision Tree: receive(on:) vs @MainActor

```
Need to update UI from a Combine pipeline?
  |
  +-- Is this new code you're writing from scratch?
  |     YES --> Use @MainActor on the class. Skip Combine if possible.
  |             Use AsyncSequence / async-await instead.
  |
  +-- Is this existing Combine code you're maintaining?
  |     YES --> Add .receive(on: DispatchQueue.main) before the subscriber.
  |             Consider adding @Sendable to sink closures for Swift 6 safety.
  |
  +-- Are you mixing Combine with async/await?
        YES --> Prefer migrating the pipeline to AsyncSequence.
                If keeping Combine: use .stream extension (buffered AsyncStream)
                instead of .values (which drops events).
```

### Migration Patterns: Combine to AsyncSequence

| Combine Pattern                         | AsyncSequence Replacement                            |
| --------------------------------------- | ---------------------------------------------------- |
| `NotificationCenter.publisher(for:)`    | `NotificationCenter.default.notifications(named:)`   |
| `publisher.sink { ... }`                | `for await value in publisher.values { ... }`        |
| `.receive(on: DispatchQueue.main).sink` | `@MainActor func` + `for await`                      |
| `publisher.map { }.filter { }`          | `.map { }.filter { }` (AsyncSequence has these)      |
| `Publishers.CombineLatest(a, b)`        | `combineLatest(a, b)` (from AsyncAlgorithms package) |
| `publisher.debounce(for:scheduler:)`    | `.debounce(for:)` (from AsyncAlgorithms)             |
| `@Published var` + `ObservableObject`   | `@Observable` class (no Combine dependency)          |
| `CurrentValueSubject`                   | Actor with `AsyncStream` continuation                |
| `PassthroughSubject`                    | `AsyncStream.makeStream()` (buffered)                |

**Migration caution**: `publisher.values` drops events under load. When migrating, use
the buffered `AsyncStream` wrapper from Section 3, not raw `.values`.
