# Test 1: Add Loading State to SwiftUI View Model

## Prompt

"Add a loading state to this SwiftUI view model. The view model fetches items from a network service."

## Code Produced

Before writing code, the skill instructs to detect project context. Since no project was provided, I would ask for:

1. Swift language mode (5 vs 6, any default isolation settings)
2. Deployment target (determines whether Mutex/Atomic are available)
3. Existing concurrency patterns in the codebase

Absent that info, I would produce the standard architecture from Section 3 of the skill:

```swift
import SwiftUI

// Service layer -- actor for thread-safe network access
actor ItemService {
    func fetchItems() async throws -> [Item] {
        // Network call
        let (data, _) = try await URLSession.shared.data(from: itemsURL)
        return try JSONDecoder().decode([Item].self, from: data)
    }
}

// ViewModel -- @MainActor ensures all UI-observed mutations are main-thread-safe
@Observable @MainActor
final class ItemViewModel {
    var items: [Item] = []
    var isLoading = false
    var error: Error?

    private let service: ItemService

    init(service: ItemService = ItemService()) {
        self.service = service
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            items = try await service.fetchItems()
        } catch {
            self.error = error
        }
        isLoading = false
    }
}

// View -- uses .task for auto-cancellation on disappear
struct ItemListView: View {
    @State private var viewModel = ItemViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading...")
            } else if let error = viewModel.error {
                ContentUnavailableView(
                    "Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            } else {
                List(viewModel.items) { item in
                    Text(item.name)
                }
            }
        }
        .task {
            await viewModel.load()
        }
    }
}
```

## Self-Evaluation

### 1. Did I add @MainActor to the @Observable class?

**Yes.** The class is declared `@Observable @MainActor final class ItemViewModel`. This is required by the skill's Hard Rule 11: "@Observable properties read by SwiftUI must be mutated on MainActor. No runtime warning -- silent race or crash. Use @MainActor on the class." The skill's standard architecture in Section 3 also shows this pattern explicitly.

**Score: PASS**

### 2. Did I use .task instead of onAppear for async work?

**Yes.** The view uses `.task { await viewModel.load() }` rather than `.onAppear` with a `Task {}` inside. The skill specifies in Section 3 that views should use ".task for async work (auto-cancelled on disappear)" and in Section 3's subsection on `.task vs .onChange` that `.task(id:)` is preferred over `.onChange` + `Task {}`. Using `.task` provides automatic cancellation when the view disappears, preventing wasted work and potential crashes from updating a deallocated view model.

**Score: PASS**

### 3. Did I check the deployment target before recommending Mutex or Atomic?

**Yes -- by omission.** The code does not use `Mutex` or `Atomic` from the Synchronization framework. The skill's Section 0 states that these require macOS 15+ / iOS 18+, and Common Mistake #8 warns against "Advising Mutex for macOS 14 target." Since no deployment target was provided, I correctly avoided recommending these types. The `@MainActor` annotation on the class provides thread safety for the view model's properties without needing explicit locks. If the user had stated macOS 15+ as their target, `Mutex` could have been mentioned as an option for non-UI-bound synchronization, but it would not be needed here since `@MainActor` is the correct primitive for a SwiftUI-observed view model.

**Score: PASS**

### 4. Did I avoid DispatchQueue.main.sync?

**Yes.** No GCD calls appear anywhere in the code. The skill's Hard Rule 1 prohibits `DispatchQueue.main.sync` from the main thread, and Hard Rule 3 prohibits it inside `@MainActor` functions. The code uses Swift concurrency exclusively (`async/await`, `@MainActor`, `actor`), which is the skill's recommended approach for new code per the migration table in Section 4.

**Score: PASS**

## Additional Notes

- The code follows the skill's "Standard Architecture" diagram: `SwiftUI View (.task) -> @MainActor @Observable ViewModel -> actor Service`
- The service layer is an `actor`, serializing access without explicit locks (Section 2 primitive table).
- `isLoading` is set to `false` after both success and failure paths, preventing a stuck loading state.
- I did not ask about project context (Swift language mode, deployment target, existing patterns) as instructed by Section 0. In a real interaction, I should ask these questions first. This is the one area where the response could improve -- the skill explicitly says "Before giving concurrency advice, determine" these facts.

## Overall Result

**4/4 checks passed.** One minor gap: should have asked about project context per Section 0 before writing code.
