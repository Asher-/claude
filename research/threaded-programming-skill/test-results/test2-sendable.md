# Test 2: Make This Class Sendable

## Input Code

```swift
class NetworkCache {
    private var store: [String: Data] = [:]
    private let queue = DispatchQueue(label: "cache")

    func get(_ key: String) -> Data? {
        queue.sync { store[key] }
    }

    func set(_ key: String, data: Data) {
        queue.async { self.store[key] = data }
    }
}
```

## Produced Code

The class is a serial-queue-protected mutable cache. The correct modernization is to restructure it as an actor, which is the direct Swift concurrency replacement for "serial DispatchQueue protecting mutable state" (skill section 4, Migration Table: Serial `DispatchQueue` -> `actor`).

```swift
actor NetworkCache {
    private var store: [String: Data] = [:]

    func get(_ key: String) -> Data? {
        store[key]
    }

    func set(_ key: String, data: Data) {
        store[key] = data
    }
}
```

**What changed and why:**

1. **`class` -> `actor`**: An actor serializes all access to its mutable state, which is exactly what the `DispatchQueue` was doing manually. Actors are `Sendable` by definition -- no annotation needed.

2. **Removed `queue`**: The actor's built-in serialization replaces the explicit serial queue. No locks, no queues, no manual synchronization.

3. **Removed `store` from being queue-protected**: The actor itself protects `store`. Direct property access inside actor methods is safe.

4. **Callers change**: `get` and `set` now require `await` at call sites since actor methods are implicitly async from outside. This is a trade-off -- if the cache is called from synchronous-only code that cannot tolerate `await`, a different approach is needed (see alternative below).

**Alternative if callers cannot use `await`** (e.g., deeply embedded in synchronous GCD code that cannot be migrated yet):

```swift
// ONLY if actor restructuring is not feasible due to call-site constraints.
// This is the @unchecked Sendable path -- use with caution.
final class NetworkCache: @unchecked Sendable {
    // SAFETY: `store` is exclusively accessed within `queue.sync`/`queue.async`.
    // All reads go through `queue.sync`, all writes through `queue.async`.
    // The serial queue provides the synchronization that makes this safe.
    // Verify with Thread Sanitizer (TSan) under concurrent load.
    private var store: [String: Data] = [:]
    private let queue = DispatchQueue(label: "cache")

    func get(_ key: String) -> Data? {
        queue.sync { store[key] }
    }

    func set(_ key: String, data: Data) {
        queue.async { self.store[key] = data }
    }
}
```

**Why the alternative is worse**: `@unchecked Sendable` tells the compiler "trust me, this is safe" -- but the compiler will never verify it. If someone later adds a property or accesses `store` outside the queue, the race is invisible to the type checker. The actor version makes races a compile-time error.

---

## Self-Evaluation

### 1. Did I avoid slapping `@unchecked Sendable` on it?

**Yes.** The primary recommendation is restructuring as an actor. `@unchecked Sendable` is only shown as a secondary alternative with explicit caveats about when it is appropriate and why it is worse.

### 2. Did I consider restructuring as an actor?

**Yes.** Actor restructuring is the primary and recommended solution. The skill's Migration Table (section 4) directly maps Serial `DispatchQueue` -> `actor`, which is exactly this pattern. The skill's decision tree (section 5) also points to actor for "reference type, protected by Mutex/actor."

### 3. Did I explain WHY `@unchecked Sendable` is dangerous?

**Yes.** Explained that it silences the compiler without providing actual safety, that future modifications can silently introduce races, and that the actor version catches races at compile time. This aligns with skill Hard Rule 6: "`@unchecked Sendable` on a mutable class is not a fix. It silences the compiler; the race remains."

### 4. If I used `@unchecked Sendable`, did I add a comment explaining protection?

**Yes.** The alternative path includes a `// SAFETY:` comment documenting exactly which mechanism protects the mutable state (serial queue), how reads and writes are synchronized, and a note to verify with TSan. This follows skill section 5: "Every escape hatch needs a comment explaining why it's safe."

### Skill Adherence Summary

| Skill Requirement                                  | Met? |
| -------------------------------------------------- | ---- |
| Restructure as actor (Migration Table, section 4)  | Yes  |
| Avoid @unchecked Sendable as primary fix (Rule 6)  | Yes  |
| Document protection if @unchecked used (section 5) | Yes  |
| Check deployment target for Mutex (section 0, 2)   | N/A  |
| Explain trade-offs of approach                     | Yes  |

**Overall**: The skill successfully guided the response away from the common mistake (#3 in section 6: "@unchecked Sendable as quick fix") and toward the correct structural solution. The decision tree and migration table both pointed clearly to `actor` as the right primitive for this pattern.
