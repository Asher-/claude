# Foundations of Threaded & Concurrent Programming

Knowledge base for the threaded-programming Claude Code skill. Dense reference material with citations.

---

## 1. Core Concepts & Mental Models

### Threads vs Processes vs Coroutines vs Fibers

**Processes** are OS-managed, isolated address spaces. Inter-process communication requires explicit mechanisms (pipes, shared memory, sockets). Context switching is expensive (TLB flush, page table swap).

**Threads** share a process's address space but have independent stacks and register state. The OS schedules them preemptively — any thread can be interrupted at any instruction boundary. This is the root of most concurrency bugs: the programmer cannot control interleaving. Each thread costs ~512KB-8MB of stack memory depending on platform.

**Coroutines** yield cooperatively at explicit suspension points (e.g., `await`). They are not preemptible — only one runs at a time per executor thread. This eliminates data races *within* a single executor but not across executors. Memory cost is minimal (often <1KB per coroutine). Swift's `async/await`, Kotlin coroutines, Python's `asyncio`, and Rust's `async` all use this model. See Knuth (1968) "The Art of Computer Programming" for the original coroutine concept.

**Fibers** are cooperatively scheduled like coroutines but have their own stack (unlike stackless coroutines which use state machines). Java's Project Loom virtual threads and Windows fibers are examples. They sit between threads and coroutines in weight.

**Key insight for the skill**: Most macOS concurrency uses OS threads (via GCD/pthreads) or Swift's cooperative async/await. The skill must know which model is active to assess what bugs are possible.

### Shared Mutable State: The Root Problem

All concurrency bugs stem from one source: **multiple threads accessing the same mutable data without adequate synchronization**. Immutable data is always safe to share. Unshared mutable data is always safe to mutate. Only the combination of shared + mutable + unsynchronized produces bugs.

This is why functional programming (immutable by default), the actor model (unshared by default), and Swift's `Sendable` protocol (compiler-enforced sharing rules) all work: each eliminates one vertex of the danger triangle.

### Memory Models

A **memory model** defines what values a read can return when writes happen on other threads. Without one, compilers and CPUs reorder operations freely.

**Sequential consistency** (Lamport 1979): operations appear to execute in some total order consistent with each thread's program order. Simplest model but expensive — prevents most hardware and compiler optimizations. Lamport (1979) "How to Make a Multiprocessor Computer That Correctly Executes Multiprocess Programs", IEEE Transactions on Computers.

**Acquire/release**: a release-store on thread A synchronizes-with an acquire-load on thread B that reads the stored value. All writes before the release are visible after the acquire. This is the backbone of mutex semantics — unlock is a release, lock is an acquire.

**Relaxed ordering**: no cross-thread ordering guarantees. Only guarantees atomicity. Useful for counters where exact ordering doesn't matter, dangerous for almost everything else.

**The C/C++/Swift model** (based on C11/C++11) provides `seq_cst`, `acquire`, `release`, `acq_rel`, and `relaxed` orderings on atomic operations. See Cox (2021) "Programming Language Memory Models" at research.swtch.com/plmm for the best modern treatment.

**Java Memory Model** (Manson, Pugh, Adve 2005): defined in terms of happens-before, with the key guarantee that data-race-free programs are sequentially consistent ("DRF-SC"). Formalized in JSR-133.

### Happens-Before Relationships

"Happens-before" is the formal tool for reasoning about concurrent programs. Event A *happens-before* event B if: (1) A and B are in the same thread and A precedes B in program order, OR (2) A is a synchronization release and B is the corresponding acquire, OR (3) there exists C such that A happens-before C and C happens-before B (transitivity).

If two memory accesses are not ordered by happens-before and at least one is a write, you have a **data race** — undefined behavior in C/C++/Swift. Lamport (1978) "Time, Clocks, and the Ordering of Events in a Distributed System" introduced the foundational partial-ordering concepts.

---

## 2. Synchronization Primitives

### Mutexes (Mutual Exclusion)

The most common primitive. Only one thread holds the lock at a time. Unlock is a release; lock is an acquire — establishing happens-before between critical sections. Recursive/reentrant mutexes allow the same thread to lock multiple times (must unlock the same count). On macOS: `os_unfair_lock` (preferred, spin-then-sleep), `pthread_mutex_t`, `NSLock`, Swift `Mutex` (Swift 6).

**Skill check**: mismatched lock/unlock, forgetting to unlock on error paths, holding locks across `await` suspension points.

### Read-Write Locks

Allow concurrent readers OR one exclusive writer. Useful when reads vastly outnumber writes. Risk: writer starvation if readers keep arriving. On macOS: `pthread_rwlock_t`.

### Semaphores

A counter-based primitive. `wait()` decrements (blocks if zero), `signal()` increments. Binary semaphore approximates a mutex but has no ownership — any thread can signal. On macOS: `DispatchSemaphore`, `sem_t` (POSIX). Dijkstra (1965) introduced the concept.

**Skill check**: using `DispatchSemaphore.wait()` on the main thread (causes deadlock with GCD).

### Condition Variables

Allow threads to wait for a predicate to become true. Always used with a mutex: unlock-and-wait is atomic to prevent missed wakeups. **Spurious wakeups** are permitted — always check the predicate in a loop. On macOS: `pthread_cond_t`, `NSCondition`.

Pattern: `while (!predicate) { cond.wait(mutex) }`

### Atomics and Memory Ordering

Atomic operations guarantee no torn reads/writes and provide ordering based on the chosen memory order. C11/C++11/Swift provide: `atomic_load`, `atomic_store`, `atomic_compare_exchange_strong/weak` (CAS), `atomic_fetch_add/sub/or/and`.

**Compare-and-swap (CAS)**: atomically compares a memory location to an expected value and, only if they match, replaces it with a new value. The foundation of all lock-free algorithms. Hardware provides this as `CMPXCHG` (x86) or `LDXR/STXR` (ARM).

**Load-linked/store-conditional (LL/SC)**: ARM and RISC-V alternative to CAS. LL reads a value; SC writes only if no other store to that address occurred since the LL. Immune to the ABA problem (unlike CAS) because it monitors the *address*, not the *value*.

### Lock-Free and Wait-Free Data Structures

**Lock-free**: guarantees system-wide progress — at least one thread makes progress in a finite number of steps. Uses CAS loops: if CAS fails, retry. No thread can block others permanently. Herlihy & Shavit (2008/2012) "The Art of Multiprocessor Programming" is the definitive reference.

**Wait-free**: guarantees per-thread progress — every thread completes in bounded steps. Strictly stronger than lock-free. Much harder to implement. Example: wait-free atomic read/write registers.

**Obstruction-free**: weakest progress guarantee — a thread makes progress only if no other threads are executing concurrently. Herlihy (1991) "Wait-Free Synchronization" established the theoretical foundations.

---

## 3. Classic Problems & Patterns

### Producer-Consumer

One or more producers enqueue work; one or more consumers dequeue. Requires: a queue, a mutex protecting it, and condition variables (or semaphores) to signal non-empty/non-full. GCD dispatch queues implement this pattern directly.

### Readers-Writers

Multiple readers can proceed concurrently; writers need exclusive access. Three variants: (1) readers-preference (readers never wait if lock is held for reading — starves writers), (2) writers-preference, (3) fair. Courtois et al. (1971) "Concurrent Control with Readers and Writers."

### Dining Philosophers

Illustrates deadlock. N philosophers, N forks, each needs two adjacent forks to eat. Naive solution: each picks up left fork, then right — all hold one fork, all wait for the other = deadlock. Solutions: resource hierarchy (always pick up lower-numbered fork first), or a waiter (central coordinator). Dijkstra (1965).

### Thread Pools

Pre-allocate a fixed number of worker threads. Submit tasks to a queue; workers pull and execute. Avoids thread creation/destruction overhead. Sizing: CPU-bound tasks = core count, I/O-bound = higher. GCD's global concurrent queues are thread pools.

### Work Stealing

Each worker has a local deque. Workers push/pop tasks from their own deque (LIFO for locality); idle workers steal from the back of another worker's deque (FIFO for large tasks). Used in Intel TBB, Java ForkJoinPool, and GCD internally. Blumofe & Leiserson (1999) "Scheduling Multithreaded Computations by Work Stealing."

### Actor Model

Actors are objects that: (1) have private state (never shared), (2) communicate only via asynchronous messages, (3) process one message at a time. No shared mutable state by construction. Hewitt, Bishop, Steiger (1973) "A Universal Modular Actor Formalism for Artificial Intelligence." Swift actors implement this model with compiler enforcement.

### Communicating Sequential Processes (CSP)

Processes communicate via synchronous channels — sender blocks until receiver is ready (rendezvous). No shared memory. Go's goroutines+channels implement CSP. Hoare (1978) "Communicating Sequential Processes."

Key difference from actors: CSP channels are anonymous (any process can send/receive); actor mailboxes are identity-based. CSP is synchronous by default; actors are asynchronous.

### Futures/Promises and Async/Await

A **future** (or promise) represents a value not yet computed. The producer *fulfills* the promise; consumers *await* the future. Async/await is syntactic sugar that transforms sequential-looking code into state machines that suspend at `await` points and resume when the future resolves. Baker & Hewitt (1977) introduced futures. Modern implementations: Swift `async/await`, JavaScript Promises, Rust `Future`, C++ `std::future/std::promise`.

**Key insight**: async/await does not eliminate concurrency bugs — it changes which bugs are possible. No data races within a single actor/executor, but race conditions (logic-level ordering bugs) remain. Holding resources across `await` points is the new deadlock risk.

---

## 4. Classic Bugs & Failure Modes

### Data Races vs Race Conditions

A **data race** is a specific, formal property: two threads access the same memory location concurrently, at least one is a write, and there is no happens-before ordering between them. In C/C++/Swift, this is undefined behavior. Thread Sanitizer (TSan) detects these.

A **race condition** is a logic bug where correctness depends on thread scheduling order. Example: check-then-act (`if (file.exists()) file.read()`) where another thread deletes the file between check and act. This is a race condition even if every individual access is data-race-free. Regehr (2011) "Race Condition vs. Data Race" explains this distinction clearly.

**Skill check**: "I made everything atomic" does not fix race conditions. Atomicity of individual operations does not mean atomicity of compound operations.

### Deadlock

All four Coffman conditions must hold simultaneously. Coffman et al. (1971) "System Deadlocks":
1. **Mutual exclusion**: a resource can only be held by one thread
2. **Hold and wait**: a thread holds one resource while waiting for another
3. **No preemption**: resources can only be released voluntarily
4. **Circular wait**: a cycle exists in the wait-for graph

Break any one condition to prevent deadlock. Most practical: impose a total ordering on lock acquisition (breaks circular wait). **Skill check**: nested lock acquisition in inconsistent order, calling unknown code while holding a lock, blocking the main thread waiting for a GCD task that itself needs the main thread.

### Livelock

Threads keep changing state in response to each other but make no progress — like two people in a corridor both stepping aside in the same direction. Often caused by naive retry logic. Unlike deadlock, CPU is busy.

### Starvation

A thread never gets to run because higher-priority threads monopolize the scheduler. Read-write locks can starve writers. Priority scheduling can starve low-priority threads indefinitely.

### Priority Inversion

A high-priority thread is blocked on a lock held by a low-priority thread, while a medium-priority thread preempts the low-priority thread. The high-priority thread effectively runs at low priority. **Mars Pathfinder (1997)**: the information bus task (high priority) blocked on a mutex held by the meteorological task (low priority), while the communications task (medium priority) preempted the met task. System watchdog triggered resets. Fix: enable priority inheritance on the mutex in VxWorks. Sha, Rajkumar, Lehoczky (1990) "Priority Inheritance Protocols."

On macOS, `os_unfair_lock` supports priority inheritance. `DispatchSemaphore` does NOT — this is a key macOS-specific foot-gun.

### ABA Problem

Specific to CAS-based lock-free algorithms. Thread 1 reads value A, is preempted. Thread 2 changes A to B then back to A. Thread 1's CAS succeeds (value is still A) but the underlying data structure has changed. Particularly dangerous in lock-free linked lists where node A was freed and a new node reuses the same address.

Solutions: tagged pointers (version counter alongside pointer), hazard pointers, LL/SC hardware (ARM), epoch-based reclamation. Michael (2004) "Hazard Pointers: Safe Memory Reclamation for Lock-Free Objects."

### Memory Ordering Bugs

Using `relaxed` ordering when `acquire/release` is needed. These bugs are architecture-dependent — may work on x86 (strong memory model) but fail on ARM (weak model). Extremely hard to reproduce and debug. Apple Silicon is ARM, so this matters for macOS.

**Skill check**: any use of `relaxed` ordering should be flagged for careful review.

### Signal Safety Issues

POSIX signals can interrupt any instruction. Signal handlers can only safely call async-signal-safe functions (POSIX defines the list: `write`, `_exit`, `signal`, a few others). Calling `malloc`, `printf`, or any pthread function in a signal handler is undefined behavior. In multithreaded programs, signals are delivered to an arbitrary thread unless masked.

On macOS, signals are mostly relevant for C/C++ code. Swift code should use GCD signal sources (`DispatchSource.makeSignalSource`) instead of `signal()`.

---

## 5. Key References

### Essential Textbooks
- Herlihy & Shavit (2008, 2nd ed. 2012) "The Art of Multiprocessor Programming" — the definitive reference on lock-free algorithms, linearizability, progress guarantees
- Goetz et al. (2006) "Java Concurrency in Practice" — despite Java focus, the principles (visibility, atomicity, ordering) are universal. Best treatment of practical patterns
- Butenhof (1997) "Programming with POSIX Threads" — the authoritative pthreads reference, still relevant for macOS
- Williams (2019, 2nd ed.) "C++ Concurrency in Action" — C++11/17 memory model, atomics, lock-free programming
- Downey (2005) "The Little Book of Semaphores" — free, concise problem sets for classical synchronization

### Foundational Papers
- Lamport (1978) "Time, Clocks, and the Ordering of Events in a Distributed System" — happens-before, logical clocks (ACM Turing Award work)
- Lamport (1979) "How to Make a Multiprocessor Computer That Correctly Executes Multiprocess Programs" — sequential consistency definition
- Coffman et al. (1971) "System Deadlocks" — the four necessary conditions
- Dijkstra (1965) "Cooperating Sequential Processes" — semaphores, dining philosophers, mutual exclusion
- Hewitt, Bishop, Steiger (1973) "A Universal Modular Actor Formalism" — the actor model
- Hoare (1978) "Communicating Sequential Processes" — CSP
- Herlihy (1991) "Wait-Free Synchronization" — consensus numbers, impossibility results
- Sha, Rajkumar, Lehoczky (1990) "Priority Inheritance Protocols" — the theory behind the Mars Pathfinder fix

### Key Online Resources
- Cox (2021) "Hardware Memory Models" and "Programming Language Memory Models" — research.swtch.com/hwmm and research.swtch.com/plmm. Best modern explainers
- Preshing on Programming (preshing.com) — Jeff Preshing's articles on lock-free programming and memory ordering are outstanding
- SEI CERT C Coding Standard, CON sections — concurrency rules for C
- CPPReference atomics documentation — canonical C++ atomics reference

---

## 6. What a Claude Code Skill Needs From This

### Decision Tree: When to Use Which Primitive

```
Need to protect shared mutable state?
  -> Single value, simple update? -> Atomic (if operation fits in one atomic op)
  -> Compound operation? -> Mutex
  -> Many readers, rare writers? -> Read-write lock
  -> Need to wait for a condition? -> Mutex + condition variable
  -> Producer-consumer queue? -> Use GCD serial queue or OperationQueue
  -> Independent state per logical entity? -> Actor

Need inter-thread signaling (not protecting data)?
  -> One-shot completion? -> Future/Promise, Swift async/await
  -> Counting resource slots? -> Semaphore (but NOT on main thread)
  -> Event stream? -> AsyncSequence, Combine, DispatchSource
```

### Common Mistake Patterns to Check For

1. **Unprotected shared mutable state** — any `var` accessed from multiple threads/queues without synchronization
2. **Lock ordering violations** — acquiring locks in inconsistent order across code paths
3. **Blocking the main thread** — `DispatchSemaphore.wait()`, `sync` dispatch to main, synchronous I/O on main thread
4. **Holding locks across await** — a mutex held when an `await` suspends = potential deadlock (the lock may never be released to the waiting thread)
5. **Check-then-act without atomicity** — `if dict[key] == nil { dict[key] = value }` without a lock
6. **Relaxed atomics misuse** — using `.relaxed` ordering when publish/consume ordering is needed
7. **Mixing sync primitives with async/await** — `os_unfair_lock` inside an actor method (actors already serialize)
8. **Capturing mutable state in closures dispatched to other queues** — silent data race
9. **Semaphore without priority inheritance** — `DispatchSemaphore` does not donate priority, causes priority inversion

### Code Review Checklist for Threaded Code

- [ ] Every shared mutable variable has a documented synchronization strategy
- [ ] Lock acquisition order is consistent (check call graphs, not just single functions)
- [ ] No blocking calls on the main thread
- [ ] No locks held across `await` suspension points
- [ ] Condition variable waits use a `while` loop (not `if`)
- [ ] Atomic operations use the correct memory ordering (not just `.relaxed`)
- [ ] Error paths release all held locks
- [ ] Closures dispatched to other queues do not capture `self` mutably without synchronization
- [ ] Thread Sanitizer has been run (or is part of CI)
- [ ] `@Sendable` closures only capture `Sendable` types

---

## Gaps

1. **Transactional memory** — software and hardware TM (Intel TSX, etc.) not covered. Increasingly relevant but limited hardware support on Apple Silicon.
2. **Formal verification** — model checkers (SPIN, TLA+) for verifying concurrent protocols. Important for correctness proofs but outside typical app developer scope.
3. **RCU (Read-Copy-Update)** — Linux kernel's scalable read-side primitive. Relevant if doing kernel-adjacent work.
4. **Linearizability vs serializability** — correctness criteria for concurrent data structures. Covered in Herlihy & Shavit but not summarized here.
5. **GPU concurrency** — Metal's threading model, threadgroup synchronization, memory coherence for GPU compute. Separate domain from CPU threading.
6. **Weak memory model specifics for Apple Silicon (ARM)** — the fact that ARM is weaker than x86 is noted but detailed barrier semantics are not enumerated.
7. **Distributed concurrency** — consensus protocols (Paxos, Raft), distributed transactions. Out of scope per README but patterns overlap.
8. **Testing strategies** — stress testing, deterministic testing frameworks, controlled schedulers. Deferred to the macOS-specific document or synthesis phase.
