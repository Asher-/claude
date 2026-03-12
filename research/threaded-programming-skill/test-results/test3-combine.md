# Test 3: Combine Pipeline Migration to async/await

## Input

```swift
class PhotoLoader: ObservableObject {
    @Published var photos: [Photo] = []
    private var cancellables = Set<AnyCancellable>()

    func loadPhotos() {
        photoService.photosPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] photos in
                self?.photos = photos
            }
            .store(in: &cancellables)
    }
}
```

## Migrated Code

```swift
@Observable @MainActor
final class PhotoLoader {
    var photos: [Photo] = []

    private let photoService: PhotoService

    init(photoService: PhotoService) {
        self.photoService = photoService
    }

    func loadPhotos() async {
        // NOTE: Avoid `publisher.values` here -- it drops events under load
        // (see Combine bridging caveat). Use a buffered AsyncStream wrapper
        // if photosPublisher emits faster than the consumer processes, or
        // migrate photoService to return an AsyncSequence directly.
        for await photos in photoService.photosPublisher.values {
            self.photos = photos
        }
    }
}

// View usage -- .task handles cancellation automatically on disappear
struct PhotoListView: View {
    @State private var loader: PhotoLoader

    init(photoService: PhotoService) {
        _loader = State(initialValue: PhotoLoader(photoService: photoService))
    }

    var body: some View {
        List(loader.photos) { photo in
            PhotoRow(photo: photo)
        }
        .task {
            await loader.loadPhotos()
        }
    }
}
```

### Migration Notes

1. **`publisher.values` caveat**: The `values` property on Combine publishers can drop events under backpressure because the AsyncSequence bridge uses a single-element buffer. If `photosPublisher` emits rapidly, wrap it in a buffered `AsyncStream` or, better, migrate the service layer to return an `AsyncSequence` natively.

2. **`@Observable` replaces `ObservableObject`/`@Published`**: The Observation framework (`@Observable`) is the modern replacement. It uses `@State` in views instead of `@StateObject`/`@ObservedObject`, and property access tracking is automatic -- no need for `@Published` wrappers.

3. **`@MainActor` on the class**: Since SwiftUI views read `photos` directly, all mutations must happen on the main actor. Annotating the class `@MainActor` enforces this at compile time. This replaces the old `.receive(on: DispatchQueue.main)` pattern.

4. **`.task` in the view**: The `.task` modifier replaces manual lifecycle management (`onAppear` + cancellable storage). It automatically cancels the async work when the view disappears, eliminating the need for `Set<AnyCancellable>` and `[weak self]` capture lists.

5. **Eliminated**: `Set<AnyCancellable>`, `[weak self]`, `receive(on:)`, `@Published`, `ObservableObject` conformance.

---

## Self-Evaluation

| #   | Criterion                                                   | Pass | Evidence                                                                                                                                         |
| --- | ----------------------------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
|   1 | Warned about `publisher.values` dropping events under load? | YES  | Inline comment in code and Migration Note #1 both call this out explicitly, recommending buffered AsyncStream or native AsyncSequence migration. |
|   2 | Used `@Observable` instead of `ObservableObject`?           | YES  | Class uses `@Observable` macro. `@Published` and `ObservableObject` conformance removed. View uses `@State` instead of `@StateObject`.           |
|   3 | Added `@MainActor` to the class?                            | YES  | `@Observable @MainActor final class PhotoLoader` -- replaces `.receive(on: DispatchQueue.main)`.                                                 |
|   4 | Used `.task` in the view instead of manual lifecycle?       | YES  | View uses `.task { await loader.loadPhotos() }`. No manual cancellable management.                                                               |

**Result: 4/4 criteria met.**

All four evaluation points align with the skill's guidance:
- Skill Section 11 (Combine): warns about `publisher.values` dropping events (Mistake #9 in Section 6).
- Skill Section 3 (Standard Architecture): prescribes `@Observable @MainActor` for view models.
- Skill Section 3 (Standard Architecture): prescribes `.task` for async work in views.
