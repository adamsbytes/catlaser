# ADR-007: View-Routed Cat Re-Identification with Per-View VGG16 Models

## Status

Accepted

## Context

Cat re-identification on catlaser has to work across two camera-to-subject view regimes that published research shows are mutually incompatible within a single model. The forces are:

**Mount geometry varies across deployments, by design.** The catlaser unit is a ~30 cm freestanding form factor with the camera fixed at the top. The user decides what surface it sits on. Advised placements (shelves, TV stand, countertop, mantle) put the camera well above any cat's shoulder, producing top-down imagery. A floor placement — the outlier but not rare enough to ignore — puts the camera near cat eye-level, producing front/profile imagery. Both regimes have to produce usable re-ID; neither can be engineered away.

**Per-view F1 is regime-dependent and both regimes are shippable.** Trein & Garcia 2025 report VGG16+contrastive F1 of 0.9344 on top-view and 0.7724 on front-view. Both sit inside the band where per-household gallery averaging (20-30 embeddings per cat) lifts effective rank-1 match accuracy to product-acceptable levels on a 1-3-cat closed set. The product has to serve both; neither is a throwaway case.

**Single-model mixed-view training empirically collapses.** The same paper's "all" configuration — one model trained on the union of top and front images — dropped F1 to 0.31-0.33. The authors attribute this to incompatible feature distributions across the two views. A shared-weights path across both regimes is ruled out by direct evidence, not theory.

**Backbone capacity matters more on the weak regime.** VGG16 → MobileNetV3Large costs −0.09 F1 on top-view (cheap: 0.93 → 0.85) but −0.20 F1 on front-view (expensive: 0.77 → 0.57). Saving RAM by using the smaller backbone specifically on the front-view model is the worst possible allocation — it degrades the already-weakest regime hardest.

**The RV1106 RAM budget cannot hold both VGG16 contexts resident.** Two INT8 VGG16 RKNN contexts are ~280 MB; the device has 256 MB shared across OS, RKAIQ ISP, YOLO detector, Python behavior brain, Rust vision daemon, and libs. At most one embedder fits at a time.

**Re-ID is a sporadic per-track event, not a per-frame operation.** Embedding inference is triggered when a track transitions from tentative to confirmed, and again periodically to refresh the gallery — not every frame. Within a placed unit, view regime stays constant across all sessions: a high unit stays top-view forever, a floor unit stays front-view forever, and a mid-height unit may cross the boundary only occasionally under unusual circumstances (cat approaches from a distance vs. crouches right against the base). View transitions are expected to be dominated by zero across the fleet and rare within the minority of sessions that have any.

These forces resolve to a single architectural shape: per-view specialist models with a shared output space, loaded one at a time.

## Decision

**Two separately-trained VGG16 re-ID models** — one top-view expert, one front-view expert. Both output 128-d embeddings in a shared metric space. The embedding dimensionality and L2-normalized cosine comparison match the contract in `catlaser_brain.identity.catalog` unchanged.

**Shared output space via teacher-student distillation.** The top-view model is trained first on its native regime (HelloStreetCat top/ plus any top-angle images minable from the other datasets). The front-view model is then trained with the top model frozen as teacher, using same-cat-cross-view pairs from HelloStreetCat as supervision: for each `(top_cat_A, front_cat_A)` pair, the front student minimizes distance between its front embedding and the teacher's top embedding. This projects front-view features into the top-view manifold rather than producing a parallel manifold the gallery can't traverse.

**Lightweight view classifier on track confirmation.** A small classifier emits top/side/none once per confirmed track, not per frame. "none" is reserved for crops too ambiguous to route; these are skipped by the re-ID pipeline and retried on the next track-refresh tick.

**Swap the active RKNN context on classification change.** Only one embedder is resident; view transitions trigger an `rknn_destroy` → `rknn_init` cycle. The cost is paid by the track that crossed the boundary, not by the steady-state inference path.

**View-agnostic gallery storage.** Embeddings stored in the per-cat SQLite reservoir carry no view tag. The shared output space means top-view and front-view embeddings of the same cat belong in the same reservoir, and cross-view nearest-neighbor lookup at match time is the normal cosine-similarity operation.

## Consequences

- Each placement regime gets the paper-best backbone (VGG16) for its view. No backbone compromise was forced by RAM pressure; it was deferred into a swap cost instead.
- The single-model mixed-view failure mode from the published literature is sidestepped without bifurcating the gallery representation or adding a view field to the stored embedding schema.
- Swap cost is ~100 ms of RKNN re-init per view transition. In the expected deployment distribution — most units never transition because they stay in their placement regime for the life of the install — this cost is paid zero times per session for the majority of users, rarely even among the minority it affects, and never back-to-back within a single track. Amortized against a session that includes tens to hundreds of track confirmations, it is invisible.
- The training pipeline gains a teacher-student distillation stage that depends on HelloStreetCat's cross-view pairs. No other public dataset provides genuine same-cat-in-both-views supervision at scale; the front-view model's alignment quality is therefore bounded by HelloStreetCat's 69 identities, even if the backbone trains on a larger combined corpus.
- Cross-view match quality is bounded by distillation alignment, which is not yet empirically verified on this dataset combination. The fallback if alignment fails is shipping the top-view model alone and accepting degraded floor-placement performance. This decision is reversible without schema or gallery changes.
- On-disk model weight budget roughly doubles (~280 MB of `.rknn` across both embedders). Fits within the OEM partition already sized for firmware + models.
- One additional trained artifact — the view classifier — enters the inference graph. Compute is negligible (<5 ms per track start, run once per track not per frame). It is a third model that has to be trained, quantized, versioned, and shipped alongside the two embedders.
- Shared 128-d output space means the gallery is portable across a model-version upgrade only if both new models are trained to produce embeddings compatible with the stored ones. Gallery re-enrollment is required on any backbone swap or retraining that breaks output-space compatibility; the device flow already supports this because enrollment is driven by live capture, not by a pre-seeded dataset.
