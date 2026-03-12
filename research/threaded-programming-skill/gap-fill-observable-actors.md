# Gap Fill: @Observable + Actor Interaction Patterns for SwiftUI

Phase 3 research for gap #4 from synthesis.md. Covers the current-gen state management threading recipe: the intersection of the Observation framework and Swift concurrency.

---

## 1. How @Observable Works Under the Hood

### Macro Expansion

The `@Observable` macro rewrites stored properties as computed properties backed by underscore-prefixed storage. It injects an `ObservationRegistrar` instance and wraps every property getter in `access()` and every setter in `withMutation()` calls.

### withObservationTracking Mechanism

1. `withObservationTracking` creates an `_AccessList` in **thread-local storage**.
2. The `apply` closure executes. Any `@Observable` property reads trigger `access()`, which records the property-observer mapping in the object's `ObservationRegistrar`.
3. When a tracked property's `willSet` fires, the `onChange` closure is invoked, then tracking state is cleared.
4. **Observation is one-shot**: after `onChange` fires once, the observation is invalidated. SwiftUI re-establishes observation on each `body` evaluation.

### Thread Safety of the Registrar

The `ObservationRegistrar` uses `_ManagedCriticalState` (wrapping Swift 6's `Mutex`) internally. Registration and invalidation are thread-safe. `withObservationTracking` can run on any thread; the `onChange` closure runs on the thread that triggered the mutation.

**Critical distinction**: the registrar's internal locking makes *observation bookkeeping* thread-safe. It does NOT make property *mutation* thread-safe. Two threads mutating the same property simultaneously is still a data race on the stored value itself.

### When View Updates Fire

SwiftUI wraps `body` evaluation in `withObservationTracking`. Only properties actually **read** during `body` are tracked. When any tracked property mutates, SwiftUI schedules a re-render. This is property-level granularity, unlike `ObservableObject` which invalidates on *any* `@Published` change.

---

## 2. @Observable vs @ObservableObject Threading Differences

| Aspect                  | @Observable                           | ObservableObject                                        |
| ----------------------- | ------------------------------------- | ------------------------------------------------------- |
| Invalidation model      | Pull-based, property-level tracking   | Push-based, object-level `objectWillChange`             |
| Granularity             | Only views reading changed prop       | All views observing the object                          |
| Computed properties     | Observable (if they read tracked)     | Not observable                                          |
| Main thread requirement | Not enforced by framework             | `@Published` sends on calling thread                    |
| Combine dependency      | None                                  | Built on Combine publishers                             |
| Performance at scale    | O(changed props x reading views)      | O(any change x all observing views)                     |
| SwiftUI integration     | `@State`, `@Environment`, `@Bindable` | `@StateObject`, `@ObservedObject`, `@EnvironmentObject` |

**Key threading difference**: `@Published` on `ObservableObject` would send `objectWillChange` on whatever thread the mutation happened on. With `@Observable`, the `onChange` callback fires on the mutating thread. In both cases, SwiftUI needs the resulting view update to happen on the main thread. The difference is that `@Observable` gives you no Combine `receive(on:)` escape hatch -- you must ensure main-thread mutation yourself.

---

## 3. @Observable + @MainActor

### The Canonical Pattern

```swift
@Observable
@MainActor
final class ViewModel {
    var items: [Item] = []
    var isLoading = false

    func load() async {
        isLoading = true
        let result = await service.fetchItems() // hops off main
        items = result  // back on MainActor -- compiler enforced
        isLoading = false
    }
}
```

Apple engineer Philippe Hausler (Swift team): models interacting with SwiftUI should be **bound to the main actor**. Mutations from a different isolation context than where they're consumed is a concurrency violation that won't ensure stability.

### Why @MainActor on the Whole Class

- **Compile-time enforcement**: the compiler prevents accidental background mutation of any property.
- **No runtime surprises**: all property access is guaranteed main-thread.
- **Matches SwiftUI's contract**: View body runs on MainActor; reading MainActor-isolated properties is synchronous with no await needed.

### Accessing from Background Tasks

```swift
@Observable @MainActor
final class ViewModel {
    var progress: Double = 0

    func processInBackground() async {
        // Heavy work runs off-main via a regular async function
        let result = await heavyComputation()
        // Assignment happens on MainActor (we're in a MainActor method)
        progress = 1.0
    }
}

// Called from a non-MainActor context:
await viewModel.load()  // 'await' required to cross isolation boundary
```

### When NOT to Use @MainActor on the Whole Class

- **Pure data models** not directly observed by SwiftUI -- use an actor instead.
- **Computation-heavy classes** where most methods do CPU work -- @MainActor would block the UI thread. Use a regular actor or nonisolated async methods.
- **Shared service layers** consumed by multiple actors -- actor isolation is more appropriate.

Rule of thumb: if SwiftUI views directly read properties from it, it should be `@MainActor`. If it only feeds data to a `@MainActor` view model, it should be a regular actor.

---

## 4. @Observable + Actors: Crossing Boundaries

### The Architecture: MainActor ViewModel + Background Actor Service

```swift
actor DataService {
    private var cache: [String: Item] = [:]

    func fetchItem(_ id: String) async throws -> Item {
        if let cached = cache[id] { return cached }
        let item = try await network.fetch(id)
        cache[id] = item
        return item
    }
}

@Observable @MainActor
final class ItemViewModel {
    var item: Item?
    var error: Error?

    private let service: DataService

    init(service: DataService) {
        self.service = service
    }

    func load(id: String) async {
        do {
            item = try await service.fetchItem(id)  // crosses actor boundary
        } catch {
            self.error = error
        }
    }
}
```

The `await` at the actor boundary is the isolation handoff. The return value crosses from `DataService`'s isolation to `MainActor`. The value must be `Sendable`.

### AsyncStream from Actor to @Observable

```swift
actor SensorMonitor {
    func readings() -> AsyncStream<SensorReading> {
        AsyncStream { continuation in
            // Set up sensor callbacks, yield values
            startMonitoring { reading in
                continuation.yield(reading)
            }
            continuation.onTermination = { _ in self.stopMonitoring() }
        }
    }
}

@Observable @MainActor
final class SensorViewModel {
    var latestReading: SensorReading?
    private let monitor: SensorMonitor

    func startObserving() async {
        for await reading in await monitor.readings() {
            latestReading = reading  // On MainActor, safe for UI
        }
    }
}
```

The `for await` loop runs on MainActor because the method is MainActor-isolated. Each yielded value crosses the actor boundary implicitly.

### Task {} in SwiftUI Views Reading from Actors

```swift
struct SensorView: View {
    @State private var viewModel: SensorViewModel

    var body: some View {
        Text(viewModel.latestReading?.description ?? "No data")
            .task {
                await viewModel.startObserving()
            }
    }
}
```

The `.task` inherits MainActor context from `body`. When the view disappears, the task is cancelled, which terminates the `for await` loop.

---

## 5. SwiftUI View Lifecycle and Concurrency

### .task {} -- Actor Isolation

`.task` uses `@_inheritActorContext` on its closure parameter. When called inside `body` (which is `@MainActor`), the closure inherits MainActor isolation. **Synchronous code** in the closure runs on MainActor. Async calls may hop to other executors as usual.

If `.task` is called from a helper method NOT annotated `@MainActor`, it runs on the cooperative thread pool. Always annotate helper methods/properties with `@MainActor` or call `.task` directly in `body`.

### .task(id:) for Cancellation and Restart

```swift
.task(id: selectedItemID) {
    await viewModel.load(id: selectedItemID)
}
```

When `selectedItemID` changes: the existing task is **cancelled** (cooperative -- check `Task.isCancelled`), then a new task starts. Also runs on initial appear.

### .onChange + Async Work

`.onChange` is synchronous. To do async work on change, launch a `Task`:

```swift
.onChange(of: searchText) { oldValue, newValue in
    // This is synchronous, on MainActor
    Task {
        await viewModel.search(newValue)
    }
}
```

Caution: these Tasks are NOT automatically cancelled on disappear. Prefer `.task(id:)` when possible.

### .refreshable Concurrency Contract

`.refreshable` keeps the refresh indicator spinning until the async closure completes. The closure inherits MainActor context. Known gotcha: if state mutations during the async work cause the view to be removed from the hierarchy, the task can be cancelled mid-operation.

### onAppear vs .task

- `onAppear`: synchronous, no automatic cancellation, no async support.
- `.task`: async, automatically cancelled on disappear, inherits actor context.

**Always prefer `.task` for async work.** Use `onAppear` only for synchronous setup.

---

## 6. State Management Architecture Patterns

### Pattern 1: Direct @Observable with @State

For simple cases. Single view owns the model.

```swift
@Observable @MainActor
final class CounterModel {
    var count = 0
    func increment() { count += 1 }
}

struct CounterView: View {
    @State private var model = CounterModel()
    var body: some View {
        Button("\(model.count)") { model.increment() }
    }
}
```

### Pattern 2: Shared @Observable via Environment

For app-wide or feature-wide state.

```swift
// At app level:
@main struct MyApp: App {
    @State private var appState = AppState()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }
}

// In any descendant:
struct DetailView: View {
    @Environment(AppState.self) private var appState
    // ...
}
```

### Pattern 3: MainActor ViewModel + Actor Service (Recommended for Complex Apps)

```
┌─────────────┐     await      ┌──────────────┐
│  SwiftUI    │ ──────────────▶│  @MainActor  │
│  View       │◀── observes ──│  @Observable  │
│  (.task)    │                │  ViewModel    │
└─────────────┘                └──────┬───────┘
                                      │ await
                               ┌──────▼───────┐
                               │    actor      │
                               │   Service     │
                               └──────────────┘
```

Views observe the ViewModel synchronously. The ViewModel calls actor services with `await`. Return values cross the isolation boundary. All mutations to observable state happen on MainActor.

### When to Use What

| Situation                       | Use                                     |
| ------------------------------- | --------------------------------------- |
| View-local state (toggle, text) | `@State` with value type                |
| View-local model with logic     | `@State` with `@Observable` class       |
| Shared across view subtree      | `@Observable` via `.environment()`      |
| Background data processing      | `actor` feeding `@MainActor` VM         |
| Global singleton (app settings) | `@Observable @MainActor` in Environment |

---

## 7. Common Mistakes

### Mistake 1: Mutating @Observable from Background Without @MainActor

```swift
// BUG: mutation happens on cooperative thread pool
@Observable final class VM {
    var data: [Item] = []
    func load() async {
        data = await fetchItems()  // runs off MainActor!
    }
}
```

**Fix**: Add `@MainActor` to the class, or use `await MainActor.run { }`.

Evidence: Nikita Belov documented cases where rapid off-main mutations cause SwiftUI to miss rendering intermediate state transitions.

### Mistake 2: Forgetting .task Cancels on Disappear

```swift
.task {
    for await value in stream {  // Cancelled when view disappears
        // If this does cleanup work after the loop, it may not run
    }
    // This line may never execute
}
```

**Fix**: Use `defer` for cleanup, or handle `CancellationError` explicitly.

### Mistake 3: Actor Reentrancy -- Stale State Across Await

```swift
actor Cache {
    var items: [String: Item] = [:]

    func loadIfNeeded(_ id: String) async throws -> Item {
        if items[id] == nil {
            // DANGER: another call may start loading the same id
            let item = try await network.fetch(id)
            // State may have changed while we awaited
            items[id] = item
        }
        return items[id]!
    }
}
```

**Fix**: Re-check state after `await`, or use a synchronous state transition to mark loading-in-progress before the await.

### Mistake 4: Over-Isolating Everything as @MainActor

```swift
// BAD: CPU-heavy work blocks UI
@MainActor @Observable
final class ImageProcessor {
    func processAll(_ images: [NSImage]) -> [NSImage] {
        images.map { applyFilters($0) }  // Blocks main thread!
    }
}
```

**Fix**: Only the observable state holder should be @MainActor. Heavy computation goes in a regular actor or nonisolated async function.

### Mistake 5: Launching Unmanaged Tasks in .onChange

```swift
// BUG: Tasks accumulate, never cancelled
.onChange(of: query) { _, newValue in
    Task { await vm.search(newValue) }  // Previous search still running!
}
```

**Fix**: Use `.task(id: query)` which cancels the previous task automatically.

### Mistake 6: Assuming @Observable Is Thread-Safe for Mutations

The `ObservationRegistrar`'s internal mutex protects observation bookkeeping, NOT your stored property values. Two threads writing the same property simultaneously is a data race. `@MainActor` or an explicit synchronization mechanism is still required.

---

## 8. Swift 6.2 Considerations

### Default MainActor Isolation

With `defaultIsolation: MainActor.self` (or the `MainActorIsolatedByDefault` flag), all types default to `@MainActor`. This means `@Observable` classes get MainActor isolation automatically. Use `nonisolated` or `@concurrent` to opt specific methods out for background work.

### nonisolated(nonsending)

In Swift 6.2, nonisolated async functions default to `nonisolated(nonsending)` -- they inherit the caller's isolation domain. This means a nonisolated async method called from MainActor stays on MainActor unless marked `@concurrent`. This reduces accidental isolation-boundary crossings but means heavy work in "nonisolated" methods may unexpectedly block MainActor.

### Impact on Patterns

With 6.2 defaults, the `@MainActor @Observable` pattern becomes the default. The explicit annotation becomes necessary only when NOT using default isolation. The `@concurrent` attribute marks functions that should genuinely run off-main for heavy computation.

---

## 9. Architecture Template for the Skill

### Decision Tree: Where Does Isolation Go?

```
Is this class directly observed by SwiftUI views?
├── YES → @MainActor @Observable
│   └── Does it do heavy computation?
│       ├── YES → Extract computation to actor/nonisolated async func
│       └── NO → All methods can be @MainActor
└── NO → Is it shared mutable state?
    ├── YES → Use actor
    └── NO → Plain struct/class, make Sendable if crossing boundaries
```

### The Standard Stack

1. **View layer**: SwiftUI views with `.task` for async work, `.task(id:)` for reactive async.
2. **ViewModel layer**: `@Observable @MainActor` classes holding UI state. Methods are async, calling into services.
3. **Service layer**: `actor` types encapsulating business logic, caching, network calls. Return `Sendable` values.
4. **Data flow**: View observes ViewModel (synchronous). ViewModel awaits Service (crosses isolation). Service returns Sendable results.

### Code Template: The Complete Pattern

```swift
// Service layer -- actor for thread safety
actor ItemService {
    func fetch(_ id: String) async throws -> Item { /* ... */ }
    func updates() -> AsyncStream<[Item]> { /* ... */ }
}

// ViewModel layer -- @MainActor for UI safety
@Observable @MainActor
final class ItemListViewModel {
    var items: [Item] = []
    var error: Error?
    private let service: ItemService

    init(service: ItemService) { self.service = service }

    func loadItems() async {
        do { items = try await service.fetch("all") }
        catch { self.error = error }
    }

    func observeUpdates() async {
        for await updatedItems in await service.updates() {
            items = updatedItems
        }
    }
}

// View layer -- inherits MainActor from View protocol
struct ItemListView: View {
    @State private var viewModel: ItemListViewModel

    init(service: ItemService) {
        _viewModel = State(initialValue: ItemListViewModel(service: service))
    }

    var body: some View {
        List(viewModel.items) { item in
            Text(item.name)
        }
        .task { await viewModel.loadItems() }
        .task { await viewModel.observeUpdates() }
        .refreshable { await viewModel.loadItems() }
    }
}
```

---

## Sources

- Swift Forums: threading requirements for @Observable mutations (Philippe Hausler)
- Swift Forums: patterns for consuming actor updates from MainActor
- Fatbobman: deep dive into Observation framework internals
- Ole Begemann: how View.task gets MainActor isolation via @_inheritActorContext
- Fatbobman: SwiftUI Views and @MainActor (protocol annotation history)
- Swift Forums: @Observable macro and @MainActor compatibility
- Donnywals: Swift 6.2 concurrency changes, nonisolated(nonsending)
- Avanderlee: default actor isolation in Swift 6.2
