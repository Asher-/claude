# macOS Threading: Platform Knowledge

## 1. The Main Thread Contract

### MUST Run on Main Thread
- **All UI frameworks**: AppKit (NSView, NSWindow, NSViewController), SwiftUI view bodies, UIKit (Catalyst)
- **NSOpenPanel, NSSavePanel** and all system dialogs
- **Autolayout constraint modifications** (addConstraint, removeConstraint, setNeedsLayout)
- **Menu and toolbar updates** (NSMenu, NSToolbar)
- **Accessibility APIs** (NSAccessibility protocol methods)
- **Main RunLoop event handling**: user input, timers scheduled on main RunLoop, performSelector(onMainThread:)

### MUST NOT Run on Main Thread
- Network I/O (URLSession tasks are async by default, but synchronous wrappers block)
- Disk I/O (reading/writing large files, database queries)
- Heavy computation (image processing, JSON parsing of large payloads, ML inference)
- Cryptographic operations (hashing, encryption of large data)

### Detecting Violations
- **Main Thread Checker**: Xcode runtime tool (enabled by default in debug). Dynamically swaps method implementations at launch to prepend a thread check. Covers AppKit, UIKit, WebKit. No recompilation needed.
- **Runtime warnings in Xcode 14+**: Purple warnings in the issue navigator for main-thread violations detected at runtime.
- **Swift 6 compiler enforcement**: @MainActor isolation errors are compile-time, not just runtime.
- **Manual assertion**: `dispatchPrecondition(condition: .onQueue(.main))` or `assert(Thread.isMainThread)`.

### Main RunLoop
- `RunLoop.main` / `CFRunLoopGetMain()` drives event processing, timer firing, and performSelector callbacks.
- `CFRunLoopSource` for custom event sources that wake the main run loop.
- `DispatchQueue.main.async {}` enqueues work to execute on the next main run loop iteration.
- `performSelector(onMainThread:with:waitUntilDone:)` — ObjC mechanism, still used in mixed codebases.

## 2. AppKit Threading Rules

**General rule: AppKit is NOT thread-safe. All AppKit calls must be on the main thread unless explicitly documented otherwise.**

| Class/API                | Thread Safety    | Notes                                                                                                                                                       |
| ------------------------ | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| NSView, NSWindow         | Main thread only | All property access, drawing, layout                                                                                                                        |
| NSViewController         | Main thread only | Lifecycle methods, view access                                                                                                                              |
| NSOpenPanel, NSSavePanel | Main thread only | Will crash or hang if called from background                                                                                                                |
| NSImage                  | Partially safe   | Creation on background OK; accessing bitmapData triggers lazy-load mutations that are NOT safe across threads. Pre-load fully on one thread before sharing. |
| NSBitmapImageRep         | Not safe         | Mutable state; confine to one thread                                                                                                                        |
| NSColor                  | Immutable, safe  | Can pass across threads freely                                                                                                                              |
| NSFont                   | Immutable, safe  | Can pass across threads freely                                                                                                                              |
| NSManagedObjectContext   | Thread-confined  | See Core Data section                                                                                                                                       |
| NSApplication            | Main thread only | Event loop, delegate callbacks                                                                                                                              |

### Drawing and Layer-Backed Views
- All drawing (`draw(_:)`, `updateLayer()`) occurs on the main thread.
- `CALayer` property mutations must be on the main thread (or within a `CATransaction`).
- `lockFocus()`/`unlockFocus()` on NSImage is main-thread only in practice due to graphics context.

### Autolayout
- Adding/removing/modifying constraints: main thread only.
- `setNeedsLayout()`, `layoutSubtreeIfNeeded()`: main thread only.
- Constraint priority changes: main thread only.

## 3. SwiftUI Threading

### @MainActor and View Bodies
- **Since WWDC 2024**: The `View` protocol itself is annotated `@MainActor`. All conforming types automatically inherit main-actor isolation.
- `body` property is always evaluated on the main thread — guaranteed by the framework.
- View initializers run on the main thread.

### Property Wrappers and Thread Safety
- `@State`: Main-actor isolated. Only access from `body` or main-actor context.
- `@Binding`: Main-actor isolated. Wraps a reference to parent's `@State`.
- `@ObservedObject` / `@StateObject`: The object itself might not be main-actor isolated, but SwiftUI observes changes on the main thread. The `@Published` property setter MUST fire on the main thread — this is the most common mistake.
- `@Observable` (Observation framework): The object should be `@MainActor` if it drives UI. Observation tracks access, and changes must be published on main thread.

### .task {} Modifier
- Runs on the **cooperative thread pool**, not the main thread (unless the closure inherits main-actor isolation).
- Automatically cancelled when the view disappears.
- Safe to `await` async work, then assign to `@State` (the assignment crosses back to main actor).

### Common Mistake: @Published from Background
```swift
// WRONG — fires objectWillChange on background thread
class MyModel: ObservableObject {
    @Published var items: [Item] = []
    func load() {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            self.items = parse(data!) // Background thread!
        }.resume()
    }
}

// CORRECT — dispatch to main
func load() async {
    let data = try await URLSession.shared.data(from: url).0
    await MainActor.run { self.items = parse(data) }
}
```

## 4. GCD on macOS

### Queue Fundamentals
- **Main queue** (`DispatchQueue.main`): Serial, always executes on the main thread. Tied to the main RunLoop.
- **Global concurrent queues**: System-managed, shared. Four QoS levels:
  - `.userInteractive` — animation, event handling (highest priority)
  - `.userInitiated` — user-triggered work that needs quick result
  - `.utility` — long-running tasks with progress (downloads, imports)
  - `.background` — invisible work (indexing, sync, backup)
- **Custom serial queues**: Lightweight mutex replacement. No lock overhead, no deadlock risk from re-entrancy (unless you use `.sync` on the same queue).
- **Custom concurrent queues**: Rarely needed; prefer serial queues or async/await.

### Thread Explosion: Causes and Prevention
**Cause**: Each blocked thread on a concurrent queue causes GCD to spawn a new thread. If many tasks block (I/O, semaphore waits, locks), GCD creates 100+ threads, exhausting the 512-thread default limit.

**Prevention strategies**:
1. **Use a small number of long-lived serial queues** instead of global concurrent queues (one per subsystem: networking, database, processing).
2. **Never use `DispatchSemaphore` or `DispatchGroup.wait()` on concurrent queues** — use completion handlers or async/await instead.
3. **Use `concurrentPerform(iterations:execute:)` (dispatch_apply)** for parallel loops — GCD manages thread count automatically.
4. **Avoid dispatching to `.global()` directly** — your code and system libraries may both block, compounding the problem.
5. **Set target queues** to create queue hierarchies — child queues inherit the target queue's thread pool.

### Key GCD Patterns
- **DispatchWorkItem**: Supports cancellation via `.cancel()`. Check `isCancelled` in the closure. Cancellation is cooperative, not preemptive.
- **DispatchGroup**: Fan-out/fan-in. `group.enter()`/`group.leave()` for async work; `group.notify(queue:)` for async completion; `group.wait()` for sync (avoid on main thread).
- **Dispatch I/O**: `DispatchIO` for chunked, non-blocking file I/O. Preferred over synchronous `read()`/`write()`.
- **Dispatch Sources**: Monitor file descriptors, signals, timers, Mach ports, process events without polling.

### Critical Deadlock
```swift
// DEADLOCK — calling .sync on the queue you're already on
DispatchQueue.main.sync { /* ... */ } // from main thread = instant deadlock

// Also deadlocks with custom serial queues:
let q = DispatchQueue(label: "my.queue")
q.async {
    q.sync { /* deadlock */ }
}
```

## 5. Core Data & Persistence Threading

### NSManagedObjectContext Thread Confinement
- Each context is bound to one queue: `NSMainQueueConcurrencyType` (main thread) or `NSPrivateQueueConcurrencyType` (private serial queue).
- **NSManagedObject instances are NOT thread-safe** — never pass them across threads. Pass `NSManagedObjectID` instead, then fetch in the target context.
- `perform {}` — async, executes on the context's queue. Required for all access to private contexts.
- `performAndWait {}` — sync, blocks calling thread. Safe from any thread (re-entrant on the context's own queue).

### NSPersistentContainer Pattern
```swift
let container = NSPersistentContainer(name: "Model")
// viewContext: main-queue context, use for UI reads
let viewContext = container.viewContext
// Background work:
container.performBackgroundTask { context in
    // context is a fresh private-queue context
    // Do work, save, then merge changes to viewContext via notification
}
```

### SwiftData Threading Model
- `ModelContext` is **not sendable** — confined to its creation thread.
- `ModelContainer` is sendable — pass it across isolation boundaries.
- `@ModelActor` macro: Creates a custom actor with a `ModelContext` on its own serial queue. The queue is determined by where the `@ModelActor` is instantiated, which is a known source of confusion.
- **Pass `PersistentIdentifier`** (sendable) across actors, not model objects.
- `@ModelActor` does NOT guarantee background execution — if created on the main thread, it runs on main. Explicitly create from a background context for background work.

## 6. Metal & GPU Threading

### Command Queue and Buffers
- `MTLCommandQueue`: Thread-safe. One per app is typical.
- `MTLCommandBuffer`: Created from the queue. NOT thread-safe — encode on one thread.
- Multiple command buffers can be encoded simultaneously on different threads, then committed in order.

### Multi-Threaded Encoding
- `MTLParallelRenderCommandEncoder`: Allows multiple threads to encode render commands into the same render pass. Each thread gets its own `MTLRenderCommandEncoder` from the parallel encoder.
- Compute encoders cannot be parallelized this way — use separate command buffers instead.

### CPU-GPU Synchronization
- **Triple buffering**: Use 3 frame buffers with `DispatchSemaphore(value: 3)`. CPU writes buffer N while GPU reads buffer N-2.
- `commandBuffer.addCompletedHandler {}` — callback fires on an arbitrary thread when GPU finishes. Signal the semaphore here.
- `MTLEvent` / `MTLSharedEvent`: Fine-grained sync between command buffers or CPU-GPU.

### CAMetalLayer and the Main Thread
- `CAMetalLayer.nextDrawable()` blocks the calling thread until a drawable is available (typically at next vsync). **Acquire as late as possible** to minimize hold time.
- Call `presentDrawable(_:)` on the command buffer, not `drawable.present()` directly — this defers presentation to after scheduling.
- Layer configuration changes (pixelFormat, drawableSize) must be on the main thread.

## 7. XPC & Inter-Process Communication

### NSXPCConnection Queue Behavior
- Each connection has a **private serial queue** for all callbacks: reply handlers, interruption handlers, invalidation handlers.
- Callbacks are **never on the main thread** and **never on the calling thread** (for async calls).
- **Synchronous XPC calls** are different: reply and error blocks execute on the calling thread before the proxy method returns.
- Messages to your exported object are delivered on the connection's private serial queue.

### Synchronization with Main Thread
```swift
connection.remoteObjectProxyWithErrorHandler { error in
    // This is on the XPC connection's private queue
}.fetchData { result in
    // Also on the XPC connection's private queue
    DispatchQueue.main.async {
        self.updateUI(with: result) // Now safe for UI
    }
}
```

### Swift Concurrency Integration
- Use `withCheckedContinuation` to bridge XPC reply handlers into async/await.
- Libraries like [AsyncXPCConnection](https://github.com/ChimeHQ/AsyncXPCConnection) provide typed async wrappers.

## 8. Swift Concurrency on macOS (Swift 6 / 6.2)

### Swift 6 Strict Concurrency
- **Compile-time data-race safety**: All cross-isolation boundary transfers must involve `Sendable` types.
- `@MainActor` annotated types/functions are guaranteed to run on the main thread.
- Non-sendable types cannot cross actor boundaries — compiler enforces this.

### Swift 6.2 "Approachable Concurrency" (Xcode 16.3+)
- **Default MainActor isolation**: New compiler setting (`-default-isolation MainActor`) makes all declarations `@MainActor` by default. New projects default to this; existing projects default to `nonisolated`.
- **`nonisolated(nonsending)`**: New default for nonisolated async functions — they run in the caller's execution context instead of hopping to the global executor. This is the safe default.
- **`@concurrent`**: Explicit opt-in to run a nonisolated function on the cooperative thread pool. Use for CPU-heavy work that should NOT block the caller's actor.
- Property wrappers no longer infer isolation from their wrappedValue — must be explicit.

### Task and Structured Concurrency
- `Task { }` — inherits the current actor's isolation (e.g., if called from @MainActor, runs on main).
- `Task.detached { }` — runs on the cooperative thread pool, no actor inheritance. Use for genuinely independent background work.
- `TaskGroup` / `ThrowingTaskGroup` — structured fan-out. Child tasks inherit the enclosing actor unless detached.
- **Cooperative thread pool**: Limited to the number of CPU cores. Tasks must not block (no semaphores, no Thread.sleep). Blocking a cooperative thread starves the entire pool.

## 9. Common Anti-Patterns

| Anti-Pattern                                       | Why It's Bad                             | Fix                                               |
| -------------------------------------------------- | ---------------------------------------- | ------------------------------------------------- |
| `DispatchQueue.main.sync` from main thread         | Instant deadlock                         | Use `.async` or just execute directly             |
| `Thread.sleep()` on main thread                    | Freezes UI                               | Use `DispatchQueue.asyncAfter` or `Task.sleep`    |
| Synchronous network/disk I/O on main thread        | UI hang, watchdog kill                   | Use async APIs or dispatch to background          |
| Using `Thread`/`NSThread` directly                 | No QoS, no cancellation, manual lifetime | Use GCD, OperationQueue, or async/await           |
| Updating `@Published` from background thread       | Undefined behavior, runtime warning      | Dispatch to main or use `@MainActor`              |
| Forgetting `Sendable` for actor boundary crossings | Data race (Swift 6 compiler error)       | Make types `Sendable` or use `@Sendable` closures |
| `DispatchSemaphore.wait()` on cooperative pool     | Blocks a cooperative thread, deadlocks   | Use async/await, never block cooperative threads  |
| Accessing `NSManagedObject` across threads         | Crash or data corruption                 | Pass `NSManagedObjectID`, fetch in target context |
| Creating too many concurrent queues                | Thread explosion                         | Use serial queues, limit concurrency              |

## 10. Debugging & Profiling

### Compile-Time Tools
- **Swift 6 strict concurrency**: Catches data races, missing `Sendable`, incorrect isolation at compile time.
- **`-warn-concurrency` flag** (Swift 5.x): Preview strict concurrency diagnostics.

### Runtime Tools
- **Main Thread Checker**: Detects AppKit/UIKit calls from background threads. Enabled in Xcode scheme diagnostics. No recompilation. ~1-2% overhead.
- **Thread Sanitizer (TSan)**: Detects data races at runtime. 2x-20x slowdown, 5x memory overhead. 64-bit macOS and simulators only. Known limitations: false positives with Swift `mutating` methods; does not understand all Swift concurrency primitives. Cannot run simultaneously with Address Sanitizer.
- **Instruments — Time Profiler**: Sample-based profiling. Shows which threads are doing work and where time is spent. Identify main-thread stalls.
- **Instruments — System Trace**: Shows thread scheduling, context switches, dispatch queue activity. Essential for diagnosing priority inversion and thread starvation.
- **`os_signpost`**: Custom instrumentation. Mark intervals and events for Instruments. Use for measuring async operation durations across threads.

### LLDB Thread Commands
- `thread list` — show all threads
- `thread backtrace all` — backtraces for every thread (essential for deadlock diagnosis)
- `thread select N` — switch to thread N
- `thread info` — current thread's dispatch queue and QoS

## Gaps

1. **Combine threading model**: `receive(on:)` / `subscribe(on:)` behavior, how Combine interacts with Swift concurrency, and whether Combine is deprecated in favor of AsyncSequence.
2. **OperationQueue**: NSOperation/NSOperationQueue patterns, maxConcurrentOperationCount, dependency graphs — still relevant for complex task scheduling.
3. **Distributed actors**: macOS support, how they interact with XPC and Bonjour.
4. **App Extensions threading**: How threading differs in app extensions (no main run loop in some extension types).
5. **FileProvider threading**: NSFileProviderReplicatedExtension and its threading requirements.
6. **Virtualization.framework threading**: VZVirtualMachine requires main thread for some operations.
7. **IOKit / DriverKit threading**: Kernel callback threading for hardware interaction.
8. **Swift 6.2 `@concurrent` real-world patterns**: Still very new — best practices are evolving.
9. **`AsyncStream` / `AsyncSequence` as GCD replacements**: Patterns for replacing dispatch sources and Combine with async sequences.
10. **Memory ordering and atomics**: Swift Atomics package, how they interact with the concurrency model.
