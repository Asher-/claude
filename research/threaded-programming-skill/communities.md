# Communities, Experts, and Learning Resources

Research for the threaded-programming skill — Phase 1.

---

## 1. Forums and Discussion

### Swift Forums (forums.swift.org)

- **URL**: https://forums.swift.org
- **Activity**: Very high — multiple concurrency threads daily
- **Key categories**: "Using Swift" (practical questions), "Evolution > Proposals" (language design), "Compiler" (implementation)
- **Value**: Primary venue for Swift concurrency design discussion. SE proposal reviews happen here. Active contributors include core team members. Essential for understanding *why* decisions were made.
- **Notable threads**: GSoC 2026 Task/TaskGroup tracking, Swift 6 concurrency questions, concurrency settings for new projects, Combine-to-concurrency migration

### Apple Developer Forums

- **URL**: https://developer.apple.com/forums/tags/concurrency
- **Activity**: Moderate — steady flow of practitioner questions
- **Value**: Real-world adoption problems. Good source of "what goes wrong" patterns. Apple engineers occasionally respond directly.
- **Notable**: The "Swift Concurrency Proposal Index" thread (thread/768776) is a comprehensive reference linking all concurrency-related SE proposals.

### Stack Overflow

- **Tags**: `swift-concurrency` (~4k questions), `grand-central-dispatch` (~12k), `async-await` (swift-specific), `swift-actors`, `sendable`
- **Activity**: High for GCD (legacy), growing for swift-concurrency
- **Value**: Searchable archive of specific error messages and patterns. Good for "what error does a developer see when they do X wrong."

### Reddit

- **r/swift**: ~120k members. Concurrency questions appear regularly.
- **r/iOSProgramming**: ~85k members. More applied/practical focus.
- **Activity**: Moderate. More beginner questions than deep technical discussion.
- **Value**: Useful for gauging what confuses practitioners most. Less useful for expert-level content.

### Hacker News

- **Activity**: Periodic — spikes around WWDC, Swift releases, major blog posts
- **Value**: Commentary threads often surface experienced systems programmers' perspectives on Swift concurrency design tradeoffs. Good for cross-language comparisons.

---

## 2. Blogs and Technical Writing

### Apple Official Documentation

- **Swift Concurrency docs**: https://developer.apple.com/documentation/swift/concurrency
- **Adopting Swift 6**: https://developer.apple.com/documentation/swift/adoptingswift6
- **Concurrency Programming Guide** (GCD/NSOperation): https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/ — archived but still relevant for legacy code
- **Threading Programming Guide**: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ — archived
- **Value**: Authoritative. The Swift 6 adoption guide is the canonical migration reference.

### Essential WWDC Sessions

**Foundational (WWDC 2021)** — watch in this order:
1. **Meet async/await in Swift** (10132) — core syntax and mental model
2. **Explore structured concurrency in Swift** (10134) — tasks, task groups, cancellation
3. **Protect mutable state with Swift actors** (10133) — actors, isolation, Sendable
4. **Swift concurrency: Behind the scenes** (10254) — runtime internals, cooperative thread pool, thread explosion avoidance. *Essential for the skill.*
5. **Swift concurrency: Update a sample app** (10194) — practical migration walkthrough
6. **Discover concurrency in SwiftUI** (10019) — MainActor, task modifiers

**Intermediate (WWDC 2022)**:
7. **Visualize and optimize Swift concurrency** (110350) — Instruments concurrency tool, diagnosing performance

**Advanced (WWDC 2023)**:
8. **Beyond the basics of structured concurrency** (10170) — task tree, task-local values, resource management patterns

**Migration (WWDC 2024)**:
9. **Migrate your app to Swift 6** (10169) — strict concurrency checking, incremental adoption strategy

**Current (WWDC 2025)**:
10. **Embracing Swift concurrency** (268) — Swift 6.2 "approachable concurrency," MainActor-by-default

### Key Bloggers

**Matt Massicotte** — https://www.massicotte.org
- Contracted to write the official Swift 6 migration guide for swift.org
- Spends ~80% of time consulting on Swift concurrency adoption
- Essential posts:
  - "Problematic Swift Concurrency Patterns" — anti-patterns like unnecessary MainActor.run, actors with no state
  - "Making Mistakes with Swift Concurrency" — real-world errors
  - "A Swift Concurrency Glossary" — terminology reference
  - "Concurrency Step-by-Step" series — protocol conformance, network requests
  - "MainActor by Default" — Swift 6.2 changes
  - "Crossing the Boundary" — isolation boundaries
  - "Singletons with Swift Concurrency"
- **Value for skill**: Highest. Directly covers the mistakes Claude would make. Cite heavily.

**Antoine van der Lee (SwiftLee)** — https://www.avanderlee.com
- Created the Swift Concurrency Course (70+ lessons, 11 modules, used by Airbnb/Garmin/Monzo)
- Published a **Swift Concurrency Agent Skill**: https://github.com/AvdLee/Swift-Concurrency-Agent-Skill — directly relevant as prior art
- Key post: "The 5 biggest mistakes iOS developers make with async/await"
- **Value for skill**: High. The existing agent skill is a reference implementation to study.

**Donny Wals** — https://www.donnywals.com
- Author of "Practical Swift Concurrency" book
- Blog category: https://www.donnywals.com/category/swift-concurrency/
- Key post: "Is 2025 the year to fully adopt Swift 6?"
- **Value for skill**: Good practical perspective. Book is well-regarded.

**Michael Tsai** — https://mjtsai.com
- Blog aggregator that collects and comments on concurrency posts from across the ecosystem
- Key posts: "Swift Concurrency Proposal Index," "Problematic Swift Concurrency Patterns" (commentary), "Swift 6.2: Approachable Concurrency"
- **Value for skill**: Excellent for finding sources. Not primary content but curates everything.

**Point-Free (Brandon Williams & Stephen Celis)** — https://www.pointfree.co
- Deep dives on concurrency in the context of architecture (Composable Architecture)
- Created swift-concurrency-extras library
- Currently rethinking all libraries for Swift 6.2 "approachable concurrency" defaults
- **Value for skill**: Advanced patterns. Good for understanding how concurrency interacts with app architecture.

**Other notable sources**:
- **Use Your Loaf** (useyourloaf.com) — WWDC viewing guides, strict concurrency in packages
- **Hacking with Swift** (hackingwithswift.com) — beginner-friendly concurrency tutorials
- **Two Cent Studios** (twocentstudios.com) — real-world concurrency challenges
- **Flying Harley** (flyingharley.dev) — "Swift Concurrency is great, but..." series

---

## 3. Open Source Projects

### Apple Official Libraries

**swift-async-algorithms** — https://github.com/apple/swift-async-algorithms
- AsyncSequence algorithms: merge, combineLatest, debounce, throttle, chain, zip
- **Value**: Reference for correct AsyncSequence patterns. Skill should know these exist.

**swift-atomics** — https://github.com/apple/swift-atomics
- Low-level atomic operations for building synchronization primitives
- **Value**: Skill should know this exists but discourage casual use. For systems programmers only.

**swift-collections** — https://github.com/apple/swift-collections
- Data structures with Sendable conformances (Deque, OrderedDictionary, etc.)
- **Value**: Skill should recommend these for concurrent-safe data structures.

**swift-nio** — https://github.com/apple/swift-nio
- Event-driven networking framework. NIOConcurrencyHelpers provides locks/atomics.
- **Value**: Example of high-performance concurrent code. Out of scope for macOS UI skill but good reference.

### Community Libraries

**swift-concurrency-extras** (Point-Free) — https://github.com/pointfreeco/swift-concurrency-extras
- LockIsolated wrapper, withMainSerialExecutor for deterministic testing, serial execution helpers
- **Value**: Testing concurrency code. Skill should reference for testability patterns.

**CollectionConcurrencyKit** (John Sundell) — https://github.com/JohnSundell/CollectionConcurrencyKit
- Async versions of forEach, map, flatMap, compactMap on collections
- **Value**: Common need. Skill should know the pattern.

### Existing Agent Skills (Prior Art)

**Swift-Concurrency-Agent-Skill** (Antoine van der Lee) — https://github.com/AvdLee/Swift-Concurrency-Agent-Skill
- Open-format agent skill for Swift concurrency guidance
- Covers safe concurrency, performance optimization, Swift 6 migration
- **Value**: Direct prior art. Study its structure, coverage, and gaps.

### Tooling

**Thread Sanitizer (TSan)** — Built into Xcode
- Runtime data race detection. Enable via Scheme > Diagnostics > Thread Sanitizer.
- **Value**: Skill must know how to recommend enabling TSan and interpreting its output.

**Instruments — Swift Concurrency template**
- Visualizes task trees, actor contention, thread pool utilization
- Introduced alongside WWDC22 session "Visualize and optimize Swift concurrency"
- **Value**: Skill should recommend for diagnosing performance issues.

**Swift compiler strict concurrency checking**
- Build setting: Strict Concurrency Checking = Complete (warning) or Swift 6 language mode (error)
- SE-0337: Incremental migration support
- **Value**: Skill must understand the migration path (Minimal → Targeted → Complete → Swift 6).

---

## 4. Books and Courses

### Books

| Title                                 | Author(s)              | Publisher       | Notes                                           |
| ------------------------------------- | ---------------------- | --------------- | ----------------------------------------------- |
| Practical Swift Concurrency           | Donny Wals             | Self-published  | Intermediate-advanced. Updated for Swift 6.2.   |
| Modern Concurrency in Swift (2nd ed)  | Marin Todorov / Kodeco | Kodeco          | Covers async/await, tasks, actors, task groups. |
| Modern Concurrency on Apple Platforms | Andres Ibanez Kautsch  | Apress          | Broader Apple platform focus.                   |
| The Curious Case of the Async Cafe    | Daniel H. Steinberg    | Pragmatic Prog. | Quirky, fast-paced introduction.                |

### Courses

- **SwiftLee Swift Concurrency Course** (avanderlee.com) — 70+ lessons, 11 modules. Updated for Swift 6.2. Most comprehensive dedicated course.
- **Kodeco Modern Concurrency** (kodeco.com) — Video course + book. Getting started + beyond the basics paths.
- **Point-Free** (pointfree.co) — Episodes on concurrency in architectural context. Subscription required.

### Apple Guides (Legacy but Referenced)

- **Concurrency Programming Guide** — GCD/NSOperation patterns. Archived. Still needed for understanding legacy codebases.
- **Threading Programming Guide** — NSThread, run loops. Archived. Rarely needed but explains historical context.

---

## 5. Key People and Experts

### Core Language Designers

| Person          | Role                                                 | Key Proposals                      |
| --------------- | ---------------------------------------------------- | ---------------------------------- |
| Doug Gregor     | Primary architect of Swift concurrency               | SE-0296, SE-0302, SE-0304, SE-0306 |
| John McCall     | Co-designer, runtime and type system aspects         | SE-0304, SE-0306, review manager   |
| Chris Lattner   | Original Swift creator, concurrency manifesto author | SE-0302, concurrency manifesto     |
| Konrad Malawski | Structured concurrency, server-side Swift            | SE-0304, SE-0306                   |
| Holly Borla     | Approachable concurrency, usability improvements     | SE-0434, Swift 6.2 vision doc      |
| Joe Groff       | Co-designer, type system                             | SE-0304                            |

### Active Community Experts

| Person                           | Platform                  | Focus                                         |
| -------------------------------- | ------------------------- | --------------------------------------------- |
| Matt Massicotte                  | massicotte.org            | Migration consulting, anti-patterns, glossary |
| Antoine van der Lee              | avanderlee.com / SwiftLee | Course author, agent skill creator            |
| Donny Wals                       | donnywals.com             | Book author, practical tutorials              |
| Brandon Williams & Stephen Celis | pointfree.co              | Architecture + concurrency, testing patterns  |
| Michael Tsai                     | mjtsai.com                | Aggregation and commentary                    |
| Paul Hudson                      | hackingwithswift.com      | Beginner-friendly tutorials                   |

### Reference Documents

- **Swift Concurrency Manifesto** (Chris Lattner): https://gist.github.com/lattner/31ed37682ef1576b16bca1432ea9f782 — historical context for the design
- **Approachable Concurrency Vision**: https://github.com/swiftlang/swift-evolution/blob/main/visions/approachable-concurrency.md — Swift 6.2 direction
- **Concurrency Proposal Index** (Doug Gregor): https://gist.github.com/DougGregor/26e1f450a4538d8d275d1d2d92d30e8b

---

## 6. What Makes a Good Skill Reference

### "Go Deeper" Links for the Skill

The skill should cite these as authoritative references when users need more detail:

1. **Apple's Adopting Swift 6 guide** — canonical migration reference
2. **WWDC21 "Behind the scenes"** — how the runtime actually works
3. **Matt Massicotte's "Problematic Swift Concurrency Patterns"** — what not to do
4. **SwiftLee's "5 biggest mistakes with async/await"** — common errors
5. **Apple's swift-async-algorithms README** — available AsyncSequence operations
6. **Swift Concurrency Proposal Index** — when users need SE-proposal-level detail

### Essential WWDC Viewing (Prioritized)

For someone building a skill, watch in this order:
1. "Swift concurrency: Behind the scenes" (WWDC21) — runtime model
2. "Meet async/await in Swift" (WWDC21) — core language
3. "Protect mutable state with Swift actors" (WWDC21) — isolation model
4. "Migrate your app to Swift 6" (WWDC24) — practical migration
5. "Embracing Swift concurrency" (WWDC25) — current defaults
6. "Beyond the basics of structured concurrency" (WWDC23) — advanced patterns

### Blog Posts Covering Common Mistakes

These are the most directly useful for a skill that needs to prevent errors:
- Massicotte: "Problematic Swift Concurrency Patterns" — MainActor.run misuse, stateless actors
- Massicotte: "Making Mistakes with Swift Concurrency" — real bugs
- SwiftLee: "5 biggest mistakes" — async for loops, background assumptions
- Massicotte: "Crossing the Boundary" — isolation boundary errors
- Two Cent Studios: "3 Swift Concurrency Challenges" — actor reentrancy, continuation leaks

---

## Recommended Resource Priority List

For someone building a Claude Code skill on threaded/concurrent programming for macOS:

### Tier 1 — Must Incorporate
1. **WWDC21 "Behind the scenes"** — runtime model the skill must understand
2. **Matt Massicotte's blog** (massicotte.org) — anti-patterns and mistakes content
3. **Apple's Adopting Swift 6 guide** — migration path reference
4. **Antoine van der Lee's Agent Skill** (GitHub) — study as prior art for structure
5. **Swift Concurrency Proposal Index** — authoritative feature reference

### Tier 2 — Should Reference
6. **Donny Wals' blog** (donnywals.com/category/swift-concurrency/) — practical patterns
7. **WWDC24 "Migrate your app to Swift 6"** — incremental adoption
8. **WWDC25 "Embracing Swift concurrency"** — Swift 6.2 defaults
9. **swift-async-algorithms** — know what's available
10. **Point-Free swift-concurrency-extras** — testing patterns

### Tier 3 — Good Background
11. **Apple Concurrency Programming Guide** (archived) — GCD patterns still in use
12. **Kodeco "Modern Concurrency in Swift"** — structured learning reference
13. **Michael Tsai's blog** — finding additional sources
14. **Swift Forums concurrency threads** — real practitioner confusion points
15. **Chris Lattner's Concurrency Manifesto** — design rationale
