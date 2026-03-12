# Threaded Programming Skill Research

## Goal
Research what's needed to write an expert Claude Code skill for handling threaded programming contexts, with emphasis on macOS (UI thread + background work, GCD, Swift concurrency, etc.).

## Phase Tracker

| Phase | Status   | Files                                                        |
| ----- | -------- | ------------------------------------------------------------ |
|     1 | complete | knowledge-base.md, cutting-edge.md, communities.md, macos.md |
|     2 | complete | synthesis.md                                                 |
|     3 | complete | gap-fill-*.md                                                |
|     4 | complete | final-review.md                                              |

## File Index

| File              | Lines | Topic                                           | Phase |
| ----------------- | ----- | ----------------------------------------------- | ----- |
| knowledge-base.md | —     | Foundations of threaded/concurrent programming  |     1 |
| cutting-edge.md   | —     | Recent advances, Swift concurrency, async/await |     1 |
| communities.md    |   290 | Forums, blogs, OSS projects, experts            |     1 |
| macos.md          | —     | macOS-specific: GCD, MainActor, AppKit/SwiftUI  |     1 |
| synthesis.md      |   202 | Cross-reference, gaps, and priorities           |     2 |

## Scope

### In Scope
- Threading models: preemptive threads, GCD, structured concurrency, actors
- macOS UI threading rules (main thread for UI, background for work)
- Swift concurrency (async/await, actors, Sendable, MainActor)
- GCD patterns and anti-patterns
- Common bugs: races, deadlocks, priority inversion, main-thread stalls
- Debugging tools: Thread Sanitizer, Instruments, os_signpost
- What makes a good Claude Code skill for this domain
- Existing Claude Code skills as reference for structure

### Out of Scope
- Server-side Swift concurrency (Vapor, etc.) — unless patterns transfer
- Non-Apple platforms (Linux threading, Windows)
- Low-level kernel threading internals

## Agent Guidance
See the deep-research skill for standard rules. Key additions:
- Focus on what a Claude Code skill needs: patterns, anti-patterns, decision trees, code templates
- Think about what mistakes Claude would make without this skill
- Think about what the user needs Claude to know to get correct threaded code
