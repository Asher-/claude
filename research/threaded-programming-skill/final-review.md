# Final Review: Threaded Programming Skill for Claude Code

Phase 4 assessment. This document drives skill creation.

---

## 1. Completeness Assessment

| Topic Area                                     | Rating        | Notes                                                                                                        |
| ---------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------ |
| Core threading concepts & memory models        | Ready         | knowledge-base.md is thorough and well-cited. No gaps for skill purposes.                                    |
| Synchronization primitives (classic + Swift 6) | Ready         | Old-world (mutexes, semaphores, atomics) and new-world (Mutex, Atomic) both covered with clear mappings.     |
| Swift concurrency (async/await, actors)        | Ready         | Comprehensive: cooperative pool, structured concurrency, actor reentrancy, Sendable, sending, AsyncSequence. |
| Swift 6/6.2 strict concurrency & migration     | Ready         | gap-fill-swift6-migration.md delivers: error lookup table, escape hatch ranking, migration decision tree.    |
| GCD patterns and anti-patterns                 | Ready         | Queue fundamentals, thread explosion, deadlock patterns, migration table to modern replacements.             |
| Main thread contract & UI threading            | Ready         | Exhaustive MUST/MUST NOT lists, AppKit rules, SwiftUI @MainActor semantics, detection tools.                 |
| @Observable + actor interaction patterns       | Ready         | gap-fill-observable-actors.md covers the full architecture: canonical pattern, boundary crossings, mistakes. |
| Combine threading model                        | Ready         | gap-fill-combine.md covers scheduler semantics, Swift 6 crash trap, .values event-dropping bug, migration.   |
| Testing concurrent code                        | Ready         | gap-fill-testing.md covers XCTest, Swift Testing, swift-concurrency-extras, TSan, TestClock, CI config.      |
| Core Data / SwiftData threading                | Needs polish  | Core Data is solid. SwiftData @ModelActor confusion documented but real-world patterns are thin.             |
| Debugging workflows                            | Needs polish  | Tools listed but no walkthrough of interpreting TSan output or Instruments Swift Concurrency template.       |
| Metal / GPU threading                          | Needs polish  | CPU-GPU sync covered. Threadgroup sync and compute shader patterns are absent. Fine for the skill's scope.   |
| XPC threading                                  | Needs polish  | Queue behavior covered. Error recovery and reconnection threading missing. Niche enough for skill purposes.  |
| OperationQueue patterns                        | Still missing | Not researched. Encountered in legacy codebases. Low priority -- skill can note "migrate to TaskGroup."      |
| Custom executors (SE-0392)                     | Still missing | Accepted proposal, no patterns researched. Advanced use case. Can defer.                                     |
| Distributed actors                             | Still missing | Out of scope per README. Correct decision -- not needed for macOS client-side skill.                         |

**Summary**: 10 Ready, 4 Needs Polish, 3 Still Missing. The research corpus is sufficient to write an authoritative skill. The "needs polish" items are either niche (Metal, XPC) or secondary concerns (debugging can be a brief section with tool recommendations rather than full walkthroughs). The "still missing" items are all low-priority and can be deferred.

---

## 2. Recommended Skill Structure

The skill should be organized as a reference document with fast navigation. Claude will consult it while writing, reviewing, debugging, or migrating concurrent code. The structure follows the natural workflow: detect the project context, choose the right approach, apply it, test it, debug it.

### Proposed Sections

**0. Project Context Detection** (5-10 lines)
Before giving any concurrency advice, determine: Swift language mode (5.x, 6.0, 6.2), whether default MainActor isolation is enabled, minimum deployment target (determines Mutex/Atomic availability), and whether the codebase uses GCD, Swift concurrency, or both. Instructions for Claude on how to detect each.

**1. Hard Rules** (20-30 lines)
Non-negotiable rules that prevent crashes and deadlocks. No explanation needed -- just the rules. This is the section Claude checks first on every concurrency-related edit. See Section 3 below for the full list.

**2. Which Primitive? (Decision Tree)** (30-40 lines)
The unified decision tree combining knowledge-base and cutting-edge material, updated for Swift 6.2. Covers: protecting shared state, inter-task signaling, fan-out/fan-in, rate limiting, UI updates.

**3. Writing New Concurrent Code** (40-50 lines)
The modern stack: @MainActor @Observable ViewModel + actor Service + .task in views. Code templates for the three architecture patterns from gap-fill-observable-actors.md. When to use `@concurrent`, when to use `nonisolated`.

**4. The Two-World Problem: GCD + Swift Concurrency Coexistence** (20-30 lines)
How to safely wrap GCD-based subsystems in actor boundaries. `withCheckedContinuation` patterns. When GCD is still the right choice. Migration table (GCD pattern -> modern replacement).

**5. Sendable & Isolation Boundaries** (20-30 lines)
Sendable conformance decision tree. The `sending` keyword. Escape hatches ranked by danger. The rule: every `@unchecked Sendable` needs a comment explaining why it's safe.

**6. Common Mistakes** (30-40 lines)
The top 15 mistakes consolidated from all research files, organized by category: deadlocks, data races, actor reentrancy, main thread violations, cooperative pool starvation, Combine threading traps.

**7. Swift 6 Migration** (30-40 lines)
Error-to-fix lookup table (top 10 errors). Migration ladder (minimal -> targeted -> complete -> Swift 6 mode). Per-file tools (@preconcurrency import). Swift 6.2 feature flags and what each changes.

**8. Code Review Checklist** (15-20 lines)
Concise checklist for reviewing concurrent code. Covers both GCD and Swift concurrency. Includes macOS-specific items (AppKit main thread, Core Data confinement, @Published from background).

**9. Testing Concurrent Code** (20-30 lines)
Decision tree for testing approach. Key packages (swift-concurrency-extras, swift-clocks). TSan guidance with known limitations. Two-test strategy (deterministic + concurrent).

**10. Debugging** (15-20 lines)
When to use which tool: TSan for data races, Main Thread Checker for UI violations, Instruments System Trace for priority inversion, LLDB thread commands for deadlocks. Brief, tool-focused.

**11. Platform-Specific Rules** (20-30 lines)
Core Data/SwiftData thread confinement. Combine receive(on:) vs @MainActor. Metal CPU-GPU sync basics. XPC callback queue behavior. AppKit-specific thread safety table.

**Estimated total**: 250-330 lines. Dense but scannable. Every section should be independently useful without reading the whole document.

---

## 3. Critical Rules the Skill Must Encode

These are the hard rules. Violating any one of these produces crashes, deadlocks, or data corruption -- not just suboptimal code.

### Deadlock Rules
1. **Never call `DispatchQueue.main.sync` from the main thread.** Instant deadlock. Also applies to any serial queue calling `.sync` on itself.
2. **Never call `DispatchSemaphore.wait()` or `Thread.sleep()` inside an async context.** Blocks a cooperative thread pool thread. With enough blocked threads, the entire app deadlocks.
3. **Never call `DispatchQueue.main.sync` from inside a `@MainActor` function.** Same deadlock, different syntax. The function is already on main; sync dispatch to main deadlocks.
4. **Never hold a lock across an `await` suspension point.** The lock may never be released because another task may need it to proceed, and the suspended task can't release it until it resumes.

### Data Race Rules
5. **Every mutable variable accessed from multiple isolation domains must have a documented synchronization strategy.** No exceptions. `var` without protection = data race = undefined behavior.
6. **`@unchecked Sendable` on a mutable class is not a fix.** It silences the compiler but the race remains. The type must actually be protected (Mutex, actor, or immutable).
7. **`@Observable` is NOT thread-safe for mutations.** The registrar's internal lock protects observation bookkeeping, not your stored properties. Two threads writing the same property is a data race.
8. **`NSManagedObject` instances must never cross thread boundaries.** Pass `NSManagedObjectID` (Sendable) and fetch in the target context. Same for SwiftData: pass `PersistentIdentifier`.

### Main Thread Rules
9. **All AppKit API calls must be on the main thread** unless explicitly documented otherwise. NSView, NSWindow, NSViewController, NSOpenPanel, autolayout, menus, accessibility.
10. **`@Published` property setters must fire on the main thread** when the object is observed by SwiftUI. Background mutation produces runtime warning and potential crash.
11. **`@Observable` properties read by SwiftUI must be mutated on MainActor.** No runtime warning (unlike @Published), just silent race condition or crash. Use `@MainActor` on the class.

### Continuation Rules
12. **`withCheckedContinuation` must be resumed exactly once on every code path.** Missing resume = caller hangs forever (leaked task, no crash, no error). Double resume = runtime crash.

### Actor Rules
13. **Actor state is NOT stable across `await` points.** Actor reentrancy means another caller can execute between suspension and resumption. Always re-read state after awaiting, or mutate state only before/after awaits.

---

## 4. Decision Trees to Include

### Tree 1: Which Concurrency Primitive?
Input: "I need to [protect state / signal completion / fan out work / limit concurrency / update UI]."
Branches by need, then by context (sync vs async, Swift version). Outputs specific primitive with one-line justification. This is the most-consulted tree.

### Tree 2: Code Review -- What to Check
Input: "I'm reviewing code that uses [actors / GCD / locks / async-await / Combine]."
Checklist-style branches. For each concurrency mechanism, the specific bugs to look for. Ends with "run TSan" recommendation and its caveats.

### Tree 3: Debugging Flowchart
Input: "The app [deadlocks / crashes with EXC_BAD_ACCESS / shows purple runtime warning / hangs / has inconsistent state]."
Branches by symptom to diagnostic tool and likely root cause. Deadlock -> LLDB `thread backtrace all`. Purple warning -> Main Thread Checker, fix with @MainActor. EXC_BAD_ACCESS in concurrent code -> TSan + check Sendable boundaries.

### Tree 4: Migration Path
Input: "This project is on [Swift 5.x / Swift 6.0 / Swift 6.2] and uses [GCD / mixed / Swift concurrency]."
Outputs the correct migration ladder. Includes which compiler flags to enable in what order. Points to error-to-fix table for specific compiler errors.

### Tree 5: Testing Approach
Input: "I need to test [an actor / a MainActor ViewModel / an AsyncStream consumer / a callback API / race condition resilience]."
Branches to specific testing pattern with framework recommendation (Swift Testing vs XCTest) and key packages.

### Tree 6: @Observable Architecture
Input: "I'm building [view-local state / shared state / background service feeding UI]."
Branches to the right pattern: @State value type, @Observable @MainActor class, actor service + MainActor ViewModel.

---

## 5. What Claude Gets Wrong Without This Skill

Concrete mistakes, from most to least likely:

1. **Uses `DispatchQueue.main.sync` inside a @MainActor function.** Claude sees "I need this on the main thread" and reaches for the GCD pattern, not realizing the function is already main-isolated. Deadlock.

2. **Omits `@MainActor` on @Observable classes.** Claude creates a ViewModel with `@Observable` but no isolation annotation. SwiftUI reads it on main, async methods mutate it off-main. Silent data race.

3. **Uses `@unchecked Sendable` as a quick fix for compiler errors.** When Claude encounters "capture of non-sendable type," the fastest fix is slapping `@unchecked Sendable` on the class. This silences the error but preserves the race.

4. **Puts `DispatchSemaphore.wait()` inside an async function.** Claude knows semaphores from GCD patterns and uses them for rate limiting inside a TaskGroup. This blocks cooperative pool threads and can deadlock the app.

5. **Ignores actor reentrancy.** Claude writes an actor method that checks state, awaits a network call, then mutates state based on the earlier check. The state may have changed during the await.

6. **Forgets `receive(on: DispatchQueue.main)` before a Combine `.sink` that updates UI state.** The sink runs on whatever thread the upstream emits from. Without the scheduler hop, UI updates happen on background threads.

7. **Uses `Task.detached` when `Task {}` would inherit the correct actor context.** Claude detaches unnecessarily, losing MainActor isolation and requiring explicit `await MainActor.run {}` to get back.

8. **Advises the same concurrency pattern regardless of Swift version.** Claude recommends `Mutex` to a project targeting macOS 14 (not available), or suggests `@concurrent` to a Swift 6.0 project (not available).

9. **Uses `publisher.values` to bridge Combine to async/await.** This drops events under load. The correct approach is a buffered `AsyncStream` wrapper.

10. **Writes tests that are accidentally serial.** `await fetch1(); await fetch2()` in a test method -- sequential, not concurrent. Should use `async let` to actually test concurrent behavior.

11. **Passes `NSManagedObject` across actor boundaries.** Claude treats Core Data objects like regular model types and sends them from a background context to the MainActor. Crash or corruption.

12. **Creates `@ModelActor` from MainActor context, expecting background execution.** The actor runs on main because it was created there. Claude doesn't know this trap.

---

## 6. Remaining Gaps

### Important
- **Debugging walkthrough**: A concrete example of interpreting TSan output and the Instruments Swift Concurrency template would make the debugging section significantly more useful. The skill can function without it but will give generic tool recommendations rather than specific guidance. Worth a focused research pass.

### Nice-to-Have
- **OperationQueue patterns**: Still present in older codebases but the skill can handle encounters with a brief "migrate to TaskGroup" note. Not worth dedicated research.
- **Custom executors (SE-0392)**: Relevant for database actors or render-thread isolation. Too niche for the initial skill. Add when real-world patterns emerge.
- **SwiftData @ModelActor deep dive**: The confusion points are documented but concrete "do this, not that" patterns would be stronger. Emerging area -- revisit after WWDC 2026.
- **Distributed actors**: Out of scope for client-side macOS skill. Correct exclusion.
- **Priority inversion in the actor world**: synthesis.md flagged this. QoS propagation for actor-isolated calls is not well-documented anywhere. Low incidence but real in production.

---

## 7. Recommended Next Steps

1. **Study van der Lee's Swift Concurrency Agent Skill** (https://github.com/AvdLee/Swift-Concurrency-Agent-Skill). Read its structure, measure its length, identify what it covers well and what it misses. Use it as a structural reference but not a content source -- our research is deeper.

2. **Draft the skill file** following the structure in Section 2. Write each section as a self-contained reference. Prioritize decision trees and hard rules over explanatory prose. Target 250-300 lines of dense markdown.

3. **Include project context detection as the first section.** This is the key differentiator: the skill must teach Claude to ask "what Swift version and concurrency settings is this project using?" before giving advice. Build detection heuristics (check Package.swift for swiftSettings, check .swift-version file, look at import statements for Synchronization framework usage).

4. **Test the skill against real scenarios.** Before finalizing, run Claude with the skill loaded against these test prompts:
   - "Add a loading state to this SwiftUI view" (should use @Observable @MainActor)
   - "This GCD code deadlocks, fix it" (should diagnose before prescribing)
   - "Make this class Sendable" (should not reach for @unchecked Sendable first)
   - "Write tests for this actor" (should use Swift Testing + swift-concurrency-extras)
   - "Migrate this Combine pipeline to async/await" (should warn about .values dropping events)

5. **Mark "hot" areas explicitly in the skill.** Swift 6.2 defaults, `@concurrent` usage patterns, and `nonisolated(nonsending)` behavior should carry notes that community consensus is still forming. The skill should state semantics without prescribing patterns that may change.

6. **Keep the skill updated.** Schedule a review after WWDC 2026 for any changes to the concurrency model. The Swift 6.2 "approachable concurrency" features are new enough that best practices will evolve over the next year.
