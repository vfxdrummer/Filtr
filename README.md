# Filtr

A VSCO-style photo app built to answer one interview question:

> *How would you handle concurrency in an app like VSCO, where you're applying filters
> to images and putting them back in the main list view?*

96 photos, 12 film presets, and the full Adjust toolset — exposure, contrast,
saturation, temp, tint, highlights, shadows, clarity, sharpen, fade, grain, vignette.
Open a photo, edit it, **Save or Discard**, and the saved edit lands on that photo's
thumbnail in the feed. An on-screen HUD reports what the pipeline is doing, and a
**Pipeline Lab** switches off each technique one at a time so you can watch it break.

SwiftUI, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY=complete`, iOS 18+.

```bash
cd ~/code/Filtr && xcodegen generate && open Filtr.xcodeproj
```

---

## The answer, in layers

**1. Nothing heavy on the main thread.** The main actor only ever receives a finished
`CGImage`. All the pixel work happens elsewhere.

**2. One shared, Metal-backed `CIContext`** (`FilterEngine`). It caches compiled
kernels and intermediate buffers; building one per render is a classic way to make an
image app crawl. Note that `FilterEngine` is a `final class`, **not an actor** —
`CIContext` is already thread-safe, and an actor's job is mutual exclusion, so
wrapping it would have quietly serialised every render in the app down to one at a
time. Actors protect mutable state; there is none here. The concurrency limit belongs
one layer up, where it can be tuned.

**3. Downsample before you filter** (`SourceImageLoader`).
`CGImageSourceCreateThumbnailAtIndex` decodes *straight to* the size we're going to
draw; the full bitmap never exists. This is the single biggest win and the step most
often skipped. Measured in-app: **20 MB decoded with it on, 116 MB with it off**, for
the same 18 visible tiles.

**4. Filter at display size, not source size.** A 132pt tile gets a ~416px render. The
full-resolution pass happens once, on demand, when the user actually commits — the
editor's Export button reports **2000×1126 in 932 ms, 8.6 MB of bitmap**. Doing that
eagerly for every thumbnail is what makes photo grids feel broken.

**5. Cancellation tied to view lifetime.** `.task(id:)` starts work when a tile
appears, cancels it when the tile disappears, and cancels-then-restarts when the
filter changes underneath it. There is no recycled cell to put the wrong image into —
the identity *is* the request. Cooperative `Task.checkCancellation()` checkpoints sit
before the decode, after the decode, and before the render.

**6. Request coalescing with reference-counted cancellation** (`RenderCoordinator`).
One in-flight `Task` per key, shared by every caller. The subtle part is the refcount:
if three tiles share a render and one scrolls away, cancelling the job would be a bug
that shows up only as intermittently blank cells under fast scrolling. Only the last
subscriber out cancels.

**7. Bounded concurrency with two priority lanes** (`AsyncSemaphore`). A fling-scroll
over 96 tiles must not start 96 renders. `DispatchSemaphore` would park a whole
cooperative-pool thread, so this one suspends the *task* instead. It has an
interactive lane and a background lane, because a plain FIFO gate has a nasty failure
mode here: prefetch requests queue ahead of the tile the user is looking at, and
lookahead ends up making visible content slower.

**8. Priority.** Visible work is `.userInitiated`, prefetch is `.utility`. Swift also
escalates a shared job automatically when a higher-priority caller joins it.

**9. Keep the blocking work off the cooperative pool** (`RenderTaskExecutor`). Core
Image's `render` is synchronous CPU/GPU work, and the cooperative pool has roughly one
thread per core with a hard rule against blocking them.
`withTaskExecutorPreference` moves it onto a private concurrent `DispatchQueue` that
*is* allowed to block, while the surrounding code stays ordinary structured
concurrency — still cancellable, still awaitable, no hand-rolled continuations.

**10. Putting it back in the list — the part the question is actually about.**

Saving does two things in a specific order. It renders the *feed-sized* thumbnail
first, and only then writes the edit to the model. Commit first and the grid tile the
user is staring at flashes a placeholder as the editor dismisses; pre-warm first and
the tile's `.task(id:)` re-fires, hits a warm cache, and resolves in the same frame.

Note what the write-back is **not**: it is not pushing a `CGImage` into a shared
`[photoID: image]` dictionary. That is the version with the classic bug — two saves in
flight, the slower one lands last, and the feed shows the edit the user already
replaced. Here the render key *is* the edit, so a stale render can only ever populate a
stale cache entry that nothing asks for. There is no invalidation call, no
notification, and no image being pushed in from outside: the tile derives its identity
from the saved edit, so committing the edit *is* the update.

The model is `@MainActor` and the only writer of `edits`, the pipeline is
`nonisolated`, and there is exactly one hop home — not `DispatchQueue.main.async`
sprinkled through callbacks.

**11. Quantise anything a finger controls.** Twelve adjustment sliders feeding a cache
key is a memory leak waiting to happen: a continuous `Double` means every pixel of drag
mints an entry that can never be hit again. Every slider snaps to 1/50 of its range, so
a full drag is ~50 renders and every one of them is reusable on the way back.

**12. Persist the document, not the pixels.** Edits are saved to one small JSON file
in Application Support; rendered images are never written to disk. A saved edit is
~200 bytes, the bitmap it produces is 8 MB, and the bitmap can always be rebuilt — so
the cheap, durable, forward-compatible thing is the only thing that gets stored.

Three details that matter more than the file format:

* **Debounced writes.** "Restyle all" changes 96 edits in one frame. Writing per
  mutation is 96 encodes and 96 file writes for one user action; coalescing to a
  single write 400 ms later makes it one. Each new change cancels the pending write
  and re-snapshots, so what lands is always the newest state.
* **Flush on backgrounding.** A debounce timer is a latency optimisation, not a
  durability guarantee — it is no defence against being terminated 200 ms later.
  Leaving the foreground is the last reliable moment to get the document on disk.
* **Atomic writes and tolerant decoding.** `Data.write(options: .atomic)` writes a temp
  file and renames, so being killed mid-write can't truncate the file and lose *every*
  edit. And `Adjustments` has a hand-written `init(from:)` using `decodeIfPresent`,
  because Swift's synthesised `Decodable` throws on a missing key even when the
  property has a default — which would mean adding a thirteenth tool silently
  invalidated everyone's saved edits.

Loading is synchronous at launch, deliberately. The file is a few KB and a single
read; doing it asynchronously would render the feed once with no edits and then
visibly re-render with them — a guaranteed flash of wrong content plus 96 wasted
renders, to avoid a sub-millisecond read. If the file ever grew to megabytes the trade
would flip.

---

## Measured: strict vs. naive

Same gesture both times — one slow drag through the grid, counters reset immediately
before — read off the HUD:

| | all techniques on | all off |
|---|---|---|
| peak simultaneous renders | **6** | **123** |
| average render | **689 ms** | **3691 ms** |
| requests coalesced | 19 | 0 |
| source bytes decoded | 0 MB (cache warm) | 466 MB and climbing |
| what you see | grid fully populated | most tiles still spinners |

The average render time is the interesting column. Nothing got algorithmically slower
with the guards off — there are just twenty times as many renders fighting over the
same GPU, so each one takes five times as long. Unbounded concurrency doesn't buy
throughput, it buys latency and heat. The decode row is the other half of the story:
with the cache on you pay for a decode once, with it off you pay 466 MB and rising for
the same 96 photos.

Separately, on a cold launch with downsampling toggled off, the same 18 visible tiles
decode **116 MB instead of 20 MB**.

---

## Code map

| File | Role |
|---|---|
| `Core/RenderCoordinator.swift` | The front door. Cache, coalescing, refcounted cancellation, admission control. |
| `Core/AsyncSemaphore.swift` | Awaitable counting semaphore, two priority lanes, cancellation-safe. |
| `Core/RenderTaskExecutor.swift` | `TaskExecutor` over a concurrent queue, for the blocking Core Image call. |
| `Core/FilterEngine.swift` | Shared `CIContext`, the preset chain, and the Adjust chain. Deliberately not an actor. |
| `Core/EditStore.swift` | The document on disk: versioned JSON, atomic writes. |
| `Core/Adjustments.swift` | The twelve tools as plain values — `Hashable`, so they're half the cache key. |
| `UI/EditorView.swift` | The edit session: draft state, dirty tracking, Save / Discard. |
| `UI/AdjustTray.swift` | Tool picker and slider. |
| `Core/SourceImageLoader.swift` | Decode tier: downsampling, decode cache, decode coalescing. |
| `Core/Metrics.swift` | Lock-based counters + a `CADisplayLink` that doubles as the stall detector. |
| `UI/RenderedImageView.swift` | The only place an image is requested. `.task(id:)` does the cancellation work. |
| `UI/LabView.swift` | The switches. |

---

## Three bugs worth keeping in the story

**A cold launch was doing 192 renders for 18 visible tiles.** The grid was laid out
inside a `GeometryReader`, whose first pass reports zero width — so every tile started
a render at a nonsense size and immediately restarted at the real one. The bogus pass
also handed `LazyVGrid` an unbounded height proposal, so it instantiated all 96 tiles
instead of the ~24 on screen. Replacing it with `.onGeometryChange` on the ScrollView
and holding the grid back until the width is real took it to **exactly 18, one per
visible tile**. Found by tracing `.task(id:)` firings, not by guessing.

**The film grain was producing blown-out white blobs.** `CIRandomGenerator` emits
**premultiplied** RGBA with a random alpha, so its RGB channels are skewed bright and
clipped — measured mean 0.75, with over 5% of samples at pure white. Sampling one of
them as luminance and forcing alpha to 1 gives sparse blown-out pixels, not grain. The
**alpha channel** is the clean uniform one: mean 0.502, sd 0.290. Sample that instead.

**`CIColorMatrix` with a bias vector returns an image of infinite extent** — the bias
tints the entire plane. Every downstream filter then works on an unbounded image, and
`CIVignette`, which derives its geometry from the extent, produces nonsense. Crop back
after any biased matrix.

---

## Known limits

- Prefetch is never cancelled on a direction change; it relies on the background lane
  and a short 6-tile runway to stay out of the way. A production version would cancel
  on scroll reversal.
- The HUD's "waste %" reads as *better* in naive mode only because cancellation is
  off — the work still happened, it just wasn't accounted as thrown away.
- Adjust radii (clarity, sharpen) are scaled to the rendered size so a thumbnail and
  its export match. Skin Tone and HSL are not implemented — they need per-hue masks,
  which is a different piece of work than the rest of the tray.
- Simulator numbers. The Metal path is CPU-backed there, so absolute render times are
  several times worse than device; the ratios are what matter.
- `FILTR_TRACE=1` logs every `.task(id:)` start; `FILTR_RECIPE=<id>` sets the launch
  filter. Both are how the bugs above were found.
