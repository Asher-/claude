# Phase 2 Synthesis: Threaded Programming Skill

Cross-referencing all four Phase 1 research files. This document drives Phase 3 gap-filling.

---

## 1. Coverage Map

| Sub-topic                                         | Rating       | Notes                                                                                                         |
| ------------------------------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------- |
| Core threading concepts & memory models           | Well Covered | knowledge-base.md is thorough: threads/coroutines/fibers, memory models, happens-before. Solid foundation.    |
| Synchronization primitives (mutexes, atomics)     | Well Covered | knowledge-base covers classics; cutting-edge covers Swift 6 Mutex/Atomic. Good old-to-new bridge.             |
| Swift concurrency (async/await, actors, Sendable) | Well Covered | cutting-edge.md covers async/await, structured concurrency, actors, Sendable, sending keyword, AsyncStream.   |
| Swift 6 / 6.2 strict concurrency and migration    | Partial      | Concepts covered. Missing: real migration walkthroughs, specific compiler error messages, incremental recipe. |
| GCD patterns and anti-patterns                    | Well Covered | macos.md has queue fundamentals, thread explosion, deadlock. cutting-edge has migration table.                |
| Main thread contract and UI threading             | Well Covered | macos.md Section 1 is explicit and detailed. Good MUST/MUST NOT lists.                                        |
| AppKit threading rules                            | Partial      | macos.md has the table but limited depth. NSImage partial safety, drawing rules thin. No NSDocument.          |
| SwiftUI threading                                 | Partial      | macos.md covers @MainActor on View, property wrappers, .task. Missing: @Environment, NavigationStack races.   |
| Core Data / SwiftData threading                   | Partial      | macos.md covers both but SwiftData is thin. @ModelActor confusion acknowledged but not resolved.              |
| Metal / GPU threading                             | Partial      | macos.md covers command queues, triple buffering, CAMetalLayer. Missing: threadgroup sync, compute patterns.  |
| Combine / Observation threading                   | Gap          | Combine receive(on:)/subscribe(on:) not covered. @Observable threading only briefly noted in cutting-edge.    |
| XPC threading                                     | Partial      | macos.md covers queue behavior and sync vs async. Missing: error recovery, reconnection threading.            |
| Debugging tools (TSan, Instruments, MTC)          | Partial      | Tools listed across files. Missing: interpreting TSan output, Instruments walkthrough, concrete workflows.    |
| Common bugs and anti-patterns                     | Well Covered | Strong across all files. knowledge-base has classics, cutting-edge has Swift-specific, macos.md has table.    |
| Decision trees (which primitive, migration paths) | Well Covered | Both knowledge-base and cutting-edge have decision trees. Migration table in cutting-edge is good.            |
| Code review checklists                            | Partial      | knowledge-base has a checklist. Needs Swift 6.2 updates and macOS-specific items.                             |
| Testing concurrent code                           | Gap          | Mentioned as a gap in knowledge-base. swift-concurrency-extras noted in communities.md. No actual patterns.   |
| Skill structure and prior art                     | Partial      | communities.md identifies van der Lee's skill. Not yet studied for structure.                                 |

**Summary**: 6 Well Covered, 9 Partial, 2 Gap. The foundations and Swift concurrency concepts are strong. Practical application areas (testing, Combine, debugging workflows) are the weakest.

---

## 2. Foundation-to-Frontier Mapping

| Classic Problem/Pattern           | Modern Swift Solution                                        | Status        |
| --------------------------------- | ------------------------------------------------------------ | ------------- |
| Mutex-protected shared state      | `actor` (async) or `Mutex<State>` (sync, Swift 6)            | Clean mapping |
| Producer-consumer queue           | `AsyncStream` with backpressure                              | Clean mapping |
| Thread pool management            | Cooperative thread pool (automatic, no tuning needed)        | Simplified    |
| Dispatch group fan-out/fan-in     | `withTaskGroup` / `async let`                                | Clean mapping |
| Main thread dispatch              | `@MainActor` (compile-time vs runtime)                       | Elevated      |
| Callback-based async              | `withCheckedContinuation` bridge                             | Clean mapping |
| Read-write lock                   | No direct Swift equivalent; actor or Mutex depending on case | Partial gap   |
| Semaphore for resource limiting   | Bounded TaskGroup (one-in-one-out pattern)                   | Pattern shift |
| Lock ordering discipline          | Actor isolation eliminates most lock ordering concerns       | Simplified    |
| Priority inversion                | Still exists; QoS propagation in Swift concurrency helps     | Mitigated     |
| Data race detection (runtime)     | Compile-time with Swift 6 strict concurrency                 | Elevated      |
| Condition variable wait-for-state | `AsyncStream`, actor state + continuation                    | Pattern shift |

**Key insight**: The biggest conceptual shift is from "protect data with locks" to "isolate data with actors." But the old model persists in (a) sync contexts where actors don't fit, (b) legacy code, (c) performance-critical paths where actor overhead matters. The skill must handle BOTH worlds.

---

## 3. Heat Map

| Area                                 | Temperature | Rationale                                                                                 |
| ------------------------------------ | ----------- | ----------------------------------------------------------------------------------------- |
| Swift 6.2 approachable concurrency   | Hot         | Released 2025, changing defaults. Ecosystem still adapting. Dangerous to be prescriptive. |
| `sending` keyword / region isolation | Hot         | SE-0414, SE-0430 are new. Reduce false positives but patterns still emerging.             |
| @MainActor-by-default                | Hot         | Fundamental mental model change. New projects vs existing projects will differ.           |
| `@concurrent` attribute              | Hot         | New in 6.2. How/when to use it is not yet community consensus.                            |
| Swift 6 strict concurrency migration | Warm        | Stable tooling, known migration path. Active but not changing.                            |
| Actor model and Sendable             | Warm        | Core model settled. Reentrancy is understood. Stable.                                     |
| async/await basics                   | Warm        | Mature since 5.5. Well documented. Stable.                                                |
| GCD                                  | Cold        | Legacy. No new features. Still used, but migration target not migration source.           |
| Combine                              | Cold        | No evolution. Not deprecated but no investment. AsyncSequence is the future.              |
| NSThread / pthreads                  | Cold        | Irrelevant for new code. Only appears in very old codebases.                              |
| Custom executors (SE-0392)           | Warm        | Accepted but underexplored. Will matter for advanced use cases.                           |
| TSan + Swift concurrency             | Warm        | Active discussion. False positives being worked on. Not resolved.                         |
| SwiftData threading                  | Hot         | New framework, threading model has known confusion points. Evolving.                      |
| @Observable threading                | Hot         | Interaction with actors still emerging. Patterns not settled.                             |

**Skill implication**: The skill must be careful about Hot areas. State what is KNOWN and flag what is IN FLUX. For Cold areas, state rules tersely but don't invest skill space.

---

## 4. Gap List

### High Priority

**1. Testing Concurrent Code**
- Why: Without testing guidance, the skill produces code that can't be verified. This is the single biggest practical gap.
- Topics: deterministic testing with `withMainSerialExecutor`, `swift-concurrency-extras` patterns, how to test actor state, how to test async sequences, XCTest + async/await patterns.
- Search: "swift concurrency testing patterns", "withMainSerialExecutor", "swift-concurrency-extras testing", "XCTest async await"
- Priority: **HIGH**

**2. Combine Threading Model**
- Why: Combine is present in most existing macOS apps. `receive(on:)` / `subscribe(on:)` semantics are non-obvious. Mixing Combine and async/await creates threading traps. Claude will encounter Combine code constantly.
- Topics: scheduler semantics, receive(on:) vs subscribe(on:), Combine-to-AsyncSequence bridging, `values` property on publishers.
- Search: "Combine receive on subscribe on threading", "Combine to AsyncSequence migration", "Combine scheduler"
- Priority: **HIGH**

**3. Swift 6.2 Migration Recipes**
- Why: The skill will be asked to help migrate code. Without concrete recipes (specific compiler errors and their fixes), it will give vague advice.
- Topics: common Swift 6 compiler errors and their fixes, incremental adoption settings, what changes in behavior between Swift 5 and Swift 6 mode, `nonisolated(nonsending)` migration.
- Search: "Swift 6 migration common errors", "Swift 6 compiler error fixes", "nonisolated nonsending migration"
- Priority: **HIGH**

**4. @Observable + Actor Interaction Patterns**
- Why: This is the current-generation state management pattern for SwiftUI. Getting the threading wrong here produces the most common category of modern SwiftUI bugs.
- Topics: @Observable on @MainActor, actor pushing results to @Observable, AsyncStream feeding @Observable, when to use @Observable vs actor.
- Search: "Observable actor Swift concurrency", "Observable MainActor pattern", "SwiftUI Observable threading"
- Priority: **HIGH**

### Medium Priority

**5. Prior Art: Van der Lee's Agent Skill**
- Why: Direct structural reference for how to organize the skill. Understanding its coverage and gaps prevents reinventing the wheel.
- Topics: Structure analysis, what it covers, what it misses, what format works best for agent consumption.
- Search: fetch https://github.com/AvdLee/Swift-Concurrency-Agent-Skill
- Priority: **MEDIUM**

**6. Debugging Workflows (Concrete)**
- Why: The skill says "use TSan" or "use Instruments" but doesn't describe how to interpret results. Claude needs to guide users through actual debugging, not just recommend tools.
- Topics: TSan output interpretation, Instruments Swift Concurrency template walkthrough, Main Thread Checker output, LLDB commands for concurrency debugging.
- Search: "TSan output interpretation Swift", "Instruments Swift Concurrency template", "debug Swift actor deadlock"
- Priority: **MEDIUM**

**7. SwiftData @ModelActor Threading**
- Why: @ModelActor has known confusion about which thread it runs on. Getting this wrong corrupts data or crashes. This specific API is a trap.
- Topics: Where @ModelActor actually runs, how to guarantee background execution, PersistentIdentifier passing patterns, batch operations.
- Search: "SwiftData ModelActor threading", "ModelActor background thread", "SwiftData concurrency patterns"
- Priority: **MEDIUM**

**8. OperationQueue Patterns**
- Why: Still present in many codebases. maxConcurrentOperationCount, dependency graphs, and cancellation are distinct from GCD and async/await. Claude will encounter these.
- Topics: NSOperation lifecycle, dependencies, KVO for state, migration to TaskGroup.
- Search: "NSOperationQueue patterns Swift", "Operation dependencies concurrency"
- Priority: **MEDIUM**

### Low Priority

**9. Custom Executor Patterns (SE-0392)**
- Why: Advanced feature, relevant for specific use cases (database actors, render thread isolation). Not needed for most code but fills a gap in the actor model.
- Search: "Swift custom actor executor SE-0392", "custom executor patterns"
- Priority: **LOW**

**10. Metal Compute Threading (Threadgroups, Barriers)**
- Why: knowledge-base flags GPU concurrency as a gap. macos.md covers CPU-GPU sync but not intra-GPU threading. Relevant for Metal compute shaders.
- Search: "Metal threadgroup synchronization", "Metal compute shader threading", "MTLComputeCommandEncoder threading"
- Priority: **LOW**

---

## 5. Unexpected Connections

**A. The Two-World Problem**: Reading all files together reveals that macOS concurrency is not one system but two that must coexist. The "old world" (GCD, locks, manual dispatch) and the "new world" (actors, structured concurrency, Sendable) have different bug profiles, different debugging tools, and different mental models. The skill must handle BOTH simultaneously because real codebases are mixed. No file adequately addresses the boundary between them -- the `withCheckedContinuation` bridge gets mentioned but the patterns for safely wrapping GCD-based subsystems inside an actor-based architecture are not explored.

**B. Swift 6.2 Inverts the Skill's Assumptions**: The 6.2 "MainActor by default" change means the skill's advice depends on which concurrency model the project uses. A project on Swift 5.10 needs opposite guidance from one on Swift 6.2 for the same question ("should I mark this @MainActor?"). The skill needs a project-mode detector or must ask.

**C. The Testing Gap Is Connected to the Debugging Gap**: Testing and debugging concurrent code are both weak across all files. Together, they form a critical practical gap: the skill can help write concurrent code but cannot help verify or fix it. These should be addressed as a unit.

**D. Combine Is the Bridge, Not Just Legacy**: Combine's `receive(on:)` is currently the most common mechanism for pushing async results to the main thread in mixed codebases. It's not just "legacy to migrate away from" -- it's the active glue layer in most production macOS apps today. The skill treating Combine as merely "Cold" legacy would be a mistake.

**E. Priority Inversion Spans Both Worlds**: knowledge-base covers priority inversion with `os_unfair_lock` vs `DispatchSemaphore`. macos.md notes `DispatchSemaphore` lacks priority inheritance. But neither file covers how priority inversion manifests in the actor world (QoS propagation for actor-isolated calls, what happens when a high-QoS task awaits a low-QoS actor). This is a real production issue.

---

## 6. Practical Priorities for the Skill

### MUST Cover (gets things wrong without it)

1. **Main thread contract**: Exhaustive list of what requires main thread. AppKit rule, SwiftUI rule, Core Data rule. This is the #1 source of runtime crashes Claude would cause.
2. **Actor isolation model**: What `@MainActor` means, when cross-actor calls need `await`, actor reentrancy hazard. #2 source of bugs.
3. **Sendable rules**: What can cross isolation boundaries, `@unchecked Sendable` risks, `sending` keyword. Swift 6 compiler errors are opaque without this.
4. **The "do not block the cooperative pool" rule**: No semaphore.wait, no Thread.sleep, no synchronous I/O inside async contexts. Violating this deadlocks the entire app.
5. **GCD deadlock patterns**: `DispatchQueue.main.sync` from main thread, nested sync on same queue. Still the most common GCD bug.
6. **Decision tree: which primitive to use**: The combined decision tree from knowledge-base + cutting-edge, updated for Swift 6.2.
7. **Project mode detection**: Is this Swift 5.x, Swift 6, or Swift 6.2? The answer changes what advice is correct.
8. **Core Data/SwiftData thread confinement**: NSManagedObject is not sendable, pass object IDs, @ModelActor caveats.

### SHOULD Cover (significantly improves quality)

9. **Migration recipes**: GCD-to-async/await patterns with concrete before/after code.
10. **Common Swift concurrency mistakes**: The 8 mistakes from cutting-edge.md, with code examples.
11. **Testing patterns**: How to test async code, actors, AsyncSequence. Reference swift-concurrency-extras.
12. **Code review checklist**: Updated for Swift 6.2, macOS-specific additions.
13. **Combine threading basics**: receive(on:), subscribe(on:), bridging to AsyncSequence.
14. **Debugging guide**: When to use TSan vs Main Thread Checker vs Instruments. How to interpret each.
15. **@Observable + @MainActor patterns**: The current-gen state management threading recipe.

### COULD Cover (nice to have, advanced)

16. **Metal CPU-GPU synchronization**: Triple buffering, command buffer threading, CAMetalLayer timing.
17. **XPC threading**: Connection queue behavior, sync vs async proxies.
18. **Custom global actors**: When and how to create them.
19. **Custom executors**: SE-0392 patterns for specialized threading needs.
20. **Lock-free data structures**: When atomics are appropriate vs overkill.
21. **OperationQueue patterns**: For legacy code encounters.

### Where the Skill Must Be Careful

- **Swift 6.2 defaults**: State what is new, what changed, and that projects may use either model. Do not assume one mode.
- **Actor reentrancy**: This is subtle and still surprises experienced developers. The skill should flag it explicitly whenever an actor method contains `await`.
- **TSan reliability**: Note that TSan has false positives with Swift concurrency as of 2025. Do not tell users "TSan found no races, you're safe."
- **@unchecked Sendable**: The skill should treat this as a code smell and require justification, not suggest it as a quick fix.
- **`nonisolated(nonsending)` vs `@concurrent`**: New in 6.2, community consensus on when to use each is still forming. State the semantics, don't prescribe patterns yet.
