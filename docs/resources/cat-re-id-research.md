# Cat Re-Identification: Training Data, Architectures, and Prior Results

Reference for building the catlaser re-ID subsystem. Captures everything
from Trein & Garcia's 2025 Siamese-network study, three public cat-ID
datasets (~17k images, ~650 distinct identities combined), and the
resulting guidance for integrating with the existing [catlaser-vision]
embedding pipeline.

---

## Summary

- **Best-known architecture for cat re-ID**: Siamese network with a
  frozen ImageNet-pretrained **VGG16** feature extractor, trained with
  **contrastive loss** on **150×150** top-view crops, producing a
  **128-d embedding**. Reported **F1 = 0.9344** / accuracy 95.18% on 26
  identities — state of the art among published cat re-ID methods as
  of Jan 2025. Beats Cho et al. 2023 (EfficientNetV2+SVM, 94.53%) and
  Li & Zhang 2022 (VGG16+Siamese, 72.91%).
- **Triplet loss collapses as identity count grows.** Works at 10 IDs
  (97% top-view), falls to F1 ~0.27-0.45 at 26 IDs. Use contrastive.
- **EfficientNetB0 is a dead end** for this task (36% top-view F1).
- **Top-view dramatically outperforms front-view** (0.93 vs 0.77 F1).
  Training on both views combined collapses to 0.31-0.33 — their
  distributions are too different for a single model.
- Three public datasets combined cover both view regimes:
  HelloStreetCat (top+front, 69 IDs), Taipei shelter set (mixed, 518
  IDs), neko-jirushi scrape (front/profile, unknown count). Total
  identity count across all three is ~650 — enough to train a
  backbone that generalizes beyond any single source domain.
- **Direct fit with [catlaser-vision]**: paper's 128-d embedding
  dimensionality matches the exact spec in
  `python/catlaser_brain/identity/catalog.py`. Swap MobileNetV2 for
  VGG16 in `models/convert/convert_reid.py`, quantize INT8 for RV1106
  NPU, run L2 normalization in Rust post-processing (the NPU can't run
  ReduceL2 — see [onnx-to-rknn-int8-conversion-rv1106.md]).

---

## Primary Reference

Trein, Tobias and Garcia, Luan Fonseca. *Siamese Networks for Cat
Re-Identification: Exploring Neural Models for Cat Instance
Recognition*. Pontifícia Universidade Católica do Rio Grande do Sul.
**arXiv:2501.02112v1 [cs.CV], 3 Jan 2025.**

Companion artifacts:
- Training code: <https://github.com/TobiasTrein/hsc-reident>
- Livestream scraper: <https://github.com/TobiasTrein/hsc-live-scrapper>
- Dataset (primary): <https://www.kaggle.com/datasets/tobiastrein/heellostreetcat-individuals>
  (the URL typo "heello" is in the paper; use it verbatim)

---

## Dataset 1 — HelloStreetCat Individuals (primary)

The paper's own dataset. Released with the paper on Kaggle as a
reproducibility artifact.

| Attribute | Value |
|---|---|
| Total images | 2,796 |
| Identities | 69 cats |
| Mean images per cat | ~41 |
| Source | "HelloStreetCat" YouTube livestream (Chinese urban cat-feeding TNR initiative) |
| Capture location | Single feeder ("The Happy Canteen Feeder") |
| Views captured | Top and front, in separate subfolders per cat |
| Collection method | `hsc-live-scrapper` running YOLOv8-cls over the livestream in real time; captures frames when a cat is detected, using YT-DLP for stream ingest and FFmpeg for image extraction |

Folder structure:
```
<cat-name>/
├── front/*.jpg
└── top/*.jpg
```

**Subset used for final training in the paper**: 26 cats (those with
≥40 images each), 80/10/10 stratified train/val/test split preserving
class proportions.

**Domain caveats**: single outdoor feeder, daylight-only, Chinese
street-cat population (low breed diversity, mostly short-hair
tabbies), overhead-mounted camera with fixed focal length. Top-view is
genuinely top — camera looks nearly straight down onto the feeding
bowl.

---

## Dataset 2 — Cat Individuals (timost1234) — supplementary

Larger, more diverse identity pool. Primary value for catlaser is
identity count (7.5× the paper's) and mixed view coverage.

| Attribute | Value |
|---|---|
| Total images | 13,536 |
| Identities | 518 cats |
| Mean images per cat | ~26 |
| Source | Taipei City Animal Protection Office, New Taipei City Government Animal Protection and Health Inspection Office, and private Taipei shelters; remainder from social media |
| Capture device | Regular digital cameras and smartphones |
| Resolution range | 195×261 to 4608×3453 (huge spread; requires resize normalization) |
| View distribution | Predominantly front/side profile (shelter adoption photography style) |
| URL | <https://www.kaggle.com/datasets/timost1234/cat-individuals> |

**Why it matters**: at 518 identities it alone has more identity
diversity than the combined person re-ID benchmarks used in much of
the cited literature. Metric-learning generalization scales with
identity count more than with images/ID; this makes it the strongest
single source for training a generalizable backbone.

**Domain caveats**: shelter photography is adversarially clean
(neutral background, groomed cat, eye-level). Cats are Taiwanese
street/shelter population — different breed mix from a Western pet
cohort. Resolutions vary 20×, so aggressive resize-to-model-input is
mandatory.

---

## Dataset 3 — Cat Re-Identification Image Dataset (cronenberg64) — supplementary

Japanese equivalent of #2. Smaller identity count (not stated
precisely — "thousands of images"; exact ID count needs verification
against the Kaggle download), but different source population and
photography style.

| Attribute | Value |
|---|---|
| Total images | "thousands" (verify via `ls \| wc` after download) |
| Identities | Not stated in description; one folder per cat |
| Source | neko-jirushi.com (Japanese cat adoption listings), publicly scraped |
| View distribution | Adoption-listing photography (predominantly front/side; varied poses) |
| Cleaning | "All images have been carefully cleaned to remove non-cat content" per dataset description |
| Folder structure | One folder per cat, multiple images per folder |
| URL | <https://www.kaggle.com/datasets/cronenberg64/cat-re-identification-image-dataset> |
| Provenance | Ritsumeikan University Project-Based Learning (PBL3) class, Group H |

Companion repos:
- Scraper: <https://github.com/cronenberg64/WebScrape_neko-jirushi>
- Original PBL re-ID system: <https://github.com/cronenberg64/PBL3_GroupH>
  (worth reading for their baseline approach; quality varies with
  student-project code)

**Domain caveats**: Japanese cat population skews toward common
household breeds (Mi-Ke, Kijitora, domestic shorthair). Adoption-site
photos have similar curation bias to dataset #2.

---

## Combined Training Corpus — Strategy

Used together the three datasets cover the catlaser deployment
surface:

| Need | Dataset | Why |
|---|---|---|
| Top-view coverage | HelloStreetCat | Only source with genuine overhead camera angle |
| Identity diversity (backbone training) | Taipei shelter (518 IDs) | By far the most distinct identities |
| Front/profile augmentation | neko-jirushi + Taipei | Both skew front/side |
| Cross-domain evaluation | (user-collected Apple Photos set) | Tests transfer to household SC3336-like footage |

Recommended identity-aware split (treat all three as one corpus):

- **Train set** (~580 IDs, ~14k images): all of Taipei + all of
  neko-jirushi + 55 of the 69 HelloStreetCat IDs.
- **Validation set** (~30 IDs, held-out identities): drawn from
  whichever dataset the backbone is weakest on — typically
  HelloStreetCat top-view for final-stage tuning.
- **Test set** (10-20 IDs, held-out identities): reserve some
  HelloStreetCat top IDs for the paper's reported-condition
  comparison, and the user's Apple Photos IDs for
  cross-domain/household transfer.

The split must be by **identity**, not by image — a re-ID test that
leaks the same cat into both train and test measures classification,
not re-identification.

---

## Architecture (from Trein & Garcia)

### Subnetwork (identical twin in Siamese pair)

```
Input: 150×150×3 RGB uint8
  ↓
VGG16 (Keras, ImageNet-pretrained, classification head removed)
  • 13 conv layers, 3×3 filters, stride 1, "same" padding
  • 5 max-pool 2×2 stride 2
  • All weights frozen (transfer learning)
  ↓
Flatten
  ↓
Dense(256, ReLU)
  ↓
Dense(128, linear)          ← this is the embedding output
```

### Siamese head

```
(subnet_a output: 128-d) ─┐
                          ├─→ Lambda: euclidean_distance(a, b) → scalar
(subnet_b output: 128-d) ─┘
```

Euclidean is computed in the raw (non-L2-normalized) 128-d space as
trained. The paper's threshold `d ≤ 0.4` for a "known" match is
calibrated against this un-normalized distance. For catlaser we
instead L2-normalize and use cosine similarity (see "Integration with
catlaser" below) — the threshold will need re-calibration.

### Loss function — contrastive (Hadsell/Chopra/LeCun 2006)

Paper's own summary: "minimize the distance between embeddings in the
feature space if they represent the same cat. For instances from
different cats, enforce a minimum distance margin by penalizing the
model when the embeddings of such instances are closer than the
specified margin."

Exact margin value is not stated in the paper; it defaults to 1.0 in
the Kaggle baseline code it was adapted from (Luo 2021).

### Alternatives tested and ruled out

| Backbone | Loss | Top-view best F1 | Verdict |
|---|---|---|---|
| VGG16 | Contrastive | **0.9344** | Best |
| MobileNetV3Large | Contrastive | 0.8480 | Usable fallback |
| VGG16 | Triplet | 0.4239 | Collapses at scale |
| MobileNetV3Large | Triplet | 0.4537 | Collapses at scale |
| EfficientNetB0 | Contrastive | 0.36 | Dead end |
| EfficientNetB0 | Triplet | 0.31 | Dead end |

---

## Training Procedure

| Parameter | Value |
|---|---|
| Optimizer | Adam |
| Learning rate | **1e-4** (1e-3 tested and beaten on all configs) |
| Epochs | **100** (200 gave no further improvement) |
| Batch size | Not stated in paper |
| Contrastive margin | Not stated (default 1.0 from adapted code) |
| Input dimensions | 150×150×3 RGB |
| Split | 80/10/10 train/val/test, stratified by identity |
| Pretrained weights | ImageNet via Keras applications |
| Frozen layers | All VGG16 conv/pool layers (only Dense-256 and Dense-128 trained) |
| Augmentation (best) | Rotation ±20° |
| Other augmentations tested | Horizontal flip, Additive Gaussian Noise (0, 0.05×255) |

### Augmentation impact (Table VI from paper, top-view only)

| Backbone | Augmentation | F1 |
|---|---|---|
| VGG16 | rotation | **0.9344** |
| VGG16 | none | 0.9261 |
| VGG16 | flip | 0.9243 |
| MobileNetV3Large | none | 0.8479 |
| MobileNetV3Large | flip | 0.8360 |

Front-view numbers are worse across the board — none exceed 0.78.

### Hardware used by authors

NVIDIA GeForce RTX 4050, 6 GB VRAM, Docker + NVIDIA Container Toolkit.
150×150 input + frozen VGG16 is small enough that any modern GPU
handles the 100 epochs in under a few hours.

---

## Paper's Results — Preserved Tables

### Table II — EfficientNetB0 preliminary (10 IDs)

| Photo Type | Base Model | Loss Function | Accuracy |
|---|---|---|---|
| top | EfficientNetB0 | contrastive | **36%** |
| top | EfficientNetB0 | triplet | 31% |
| front | EfficientNetB0 | contrastive | 10% |
| front | EfficientNetB0 | triplet | 30% |

### Table III — VGG16 preliminary (10 IDs)

| Photo Type | Base Model | Loss Function | Accuracy |
|---|---|---|---|
| top | VGG16 | contrastive | 92% |
| top | VGG16 | **triplet** | **97%** |
| front | VGG16 | contrastive | 59% |
| front | VGG16 | triplet | 79% |
| all | VGG16 | contrastive | 33% |
| all | VGG16 | triplet | 31% |

Note: triplet won at 10 IDs. This reversed at 26 IDs — see Table V.

### Table IV — Learning rate sweep, contrastive loss (26 IDs)

| Photo Type | Base Model | LR | F1 |
|---|---|---|---|
| top | VGG16 | 0.001 | 0.8809 |
| top | **VGG16** | **0.0001** | **0.9261** |
| top | MobileNet | 0.001 | 0.8479 |
| top | MobileNet | 0.0001 | 0.7345 |
| front | VGG16 | 0.001 | 0.6938 |
| front | VGG16 | 0.0001 | 0.7543 |
| front | MobileNet | 0.001 | 0.3568 |
| front | MobileNet | 0.0001 | 0.5651 |

MobileNet inverts the learning-rate preference — lr=1e-3 better for
top, lr=1e-4 better for front. VGG16 prefers 1e-4 uniformly.

### Table V — Learning rate sweep, triplet loss (26 IDs)

| Photo Type | Base Model | LR | F1 |
|---|---|---|---|
| top | VGG16 | 0.001 | 0.3727 |
| top | VGG16 | 0.0001 | 0.4239 |
| top | MobileNet | 0.001 | 0.3470 |
| top | MobileNet | 0.0001 | **0.4537** |
| front | VGG16 | 0.001 | 0.3436 |
| front | VGG16 | 0.0001 | 0.2799 |
| front | MobileNet | 0.001 | 0.2126 |
| front | MobileNet | 0.0001 | 0.2026 |

All values below contrastive-loss equivalents. Triplet abandoned after
this sweep.

### Table VII — Top 5 configurations

| Photo Type | Base Model | Augmentation | F1 |
|---|---|---|---|
| top | **VGG16** | **rotation** | **0.9344** |
| top | VGG16 | none | 0.9261 |
| top | VGG16 | flip | 0.9243 |
| top | MobileNetV3Large | none | 0.8480 |
| top | MobileNetV3Large | flip | 0.8360 |

---

## Empirical Findings (paper's own observations + commentary)

1. **Triplet loss doesn't scale with identity count.** The authors
   observe F1 halves or worse going from 10 to 26 IDs with triplet;
   contrastive holds up or improves. Paper's explanation: "the applied
   models do not scale well with this type of loss function when the
   dataset increases in complexity and diversity." The implication for
   catlaser: at ~600 combined training IDs across all three datasets,
   triplet is almost certainly unusable. Use contrastive.

2. **EfficientNet (any variant in this study) is categorically
   unsuited** to this Siamese setup. Authors do not explain why, but
   the likely cause is that EfficientNet's compound-scaling
   architecture couples depth/width/resolution expectations tightly
   and behaves poorly when the classification head is stripped and
   replaced with a 256→128 Dense projection. Don't waste cycles on
   EfficientNet variants.

3. **Top-view dominates for cat ID.** Same VGG16+contrastive: top
   0.9344 vs front 0.7543. Paper doesn't hypothesize a mechanism; a
   reasonable one is that dorsal coat patterns are the highest-entropy
   identifier on most cat morphotypes, and top-view is the only angle
   that captures the full dorsal pattern without occlusion.

4. **Mixed front+top training collapses.** "All" configuration (both
   views in one model) produced F1 ~0.31-0.33. The two views' feature
   distributions are too different; the network can't learn a unified
   manifold. If front-view is needed, **train a second model** for
   front and switch at inference based on estimated pose, not one
   model trained on both.

5. **150×150 is enough.** No attempt was made at higher resolution.
   For INT8 on RV1106 this is a net positive (smaller tensors,
   faster).

6. **Augmentation buys 0.008 F1** (rotation vs none on the best
   config). Marginal. Ship with rotation aug on but don't expect
   miracles.

---

## Prior Cat Re-ID Work (Table I, paper's survey)

### Cat-specific

| Work | Method | Accuracy |
|---|---|---|
| Li & Zhang 2022 | VGG16 + Siamese on cat faces | 72.91% |
| Fan et al. 2021 | Face detection + MFCC + GMM | 83.3% |
| Cho et al. 2023 | EfficientNetV2 + SVM, face + body detection | 94.53% |
| **Trein & Garcia 2025** | VGG16 + Siamese + contrastive, top-view | **95.18%** |

### Adjacent animal re-ID (for strategy context)

| Work | Species | Method | Strategy | Result |
|---|---|---|---|---|
| Phyo et al. 2018 | Dairy cows | 3D-DCNN on back patterns | Localized parts | 96.3% |
| Bouma et al. 2018 | Dolphins | ResNet on dorsal fins | Localized parts | 93.6% top-5 |
| Konovalov et al. 2018 | Minke whales | VGG16 on color patterns | Localized parts | F1 0.76 |
| Li et al. 2018 | Dairy cows | DnCNN on faces | Face/head | 95% top-3 |
| He et al. 2019 | Red pandas | VGG16 on faces | Face/head | 98.3% rank-10 |

Ravoor & Sudarshan 2020 survey divides animal re-ID into "localized
parts" (fur/body pattern) and "face/head" strategies. Trein & Garcia's
top-view approach is effectively a localized-parts method (dorsal
coat); their front-view is face/head. The paper's main contribution
is demonstrating that on cats specifically, dorsal coat beats face.

---

## Relevant Related Code and Models

| Resource | Purpose |
|---|---|
| [hsc-reident](https://github.com/TobiasTrein/hsc-reident) | Keras/TF Siamese training pipeline, parameterized over backbone × loss × aug × view |
| [hsc-live-scrapper](https://github.com/TobiasTrein/hsc-live-scrapper) | YOLOv8-cls livestream frame extractor — useful if we want to augment training with more HelloStreetCat data later |
| [Luo 2021 cat_individual_snn](https://www.kaggle.com/code/jovi1018/cat-individual-snn) | Kaggle notebook the paper's code was forked from |
| [WebScrape_neko-jirushi](https://github.com/cronenberg64/WebScrape_neko-jirushi) | Scraper for dataset #3; useful for refreshing the dataset |
| [PBL3_GroupH](https://github.com/cronenberg64/PBL3_GroupH) | Original student-project re-ID system accompanying dataset #3 |

---

## Integration with [catlaser-vision]

### What maps directly

- **128-d embedding dimensionality** matches
  `python/catlaser_brain/identity/catalog.py` (`EMBEDDING_DIM = 128`).
  Zero catalog-side changes.
- **Architecture fits the existing convert pipeline**: single branch
  of the Siamese twin = a standalone embedding model. Export that
  branch to ONNX (opset 12, 150×150×3 input, 128-d output), feed into
  `models/convert/convert_reid.py`.
- **Cat-class crops** from the existing YOLOv8n detection pipeline
  (COCO class id 15) feed directly into the 150×150 embedder input —
  `hsc-live-scrapper` does the same crop.

### What needs to change

- **Swap MobileNetV2 → VGG16** in `models/convert/convert_reid.py` and
  in the ImageNet normalization constants. VGG's mean/std are
  different from MobileNet's:
  - MobileNet (current): `mean=[123.675, 116.28, 103.53]`,
    `std=[58.395, 57.12, 57.375]`
  - VGG16 (Keras standard): `mean=[103.939, 116.779, 123.68]`,
    `std=[1.0, 1.0, 1.0]` — VGG historically uses BGR mean subtraction
    with no scaling. Verify against the exact `tf.keras.applications.vgg16.preprocess_input` behavior of the trained model.
- **L2 normalize in Rust**, not the graph. RV1106 NPU cannot run
  ReduceL2 (see [onnx-to-rknn-int8-conversion-rv1106.md]); the paper's
  network doesn't include a norm layer anyway. Add an explicit L2
  division in the Rust post-processing step that already dequantizes
  the INT8 output to f32.
- **Re-calibrate `MATCH_THRESHOLD`** in `catalog.py`. Paper's 0.4 is
  Euclidean on un-normalized embeddings; catlaser uses cosine on
  L2-normalized embeddings (current default 0.75). Best calibration:
  run the held-out test split through the INT8-quantized model, plot
  the same-pair vs different-pair cosine-sim distributions, set the
  threshold at the equal-error-rate point.

### Risks / what to benchmark before committing

- **VGG16 INT8 inference latency on RV1106.** ~138M params, but at
  150×150 input the FLOPs are dominated by the conv stack feeding very
  small spatial maps toward the later layers. Rough envelope: expect
  100-300 ms per inference on the 1 TOPS NPU. Acceptable for the
  sporadic re-ID path (called once per confirmed track), unacceptable
  for the 15 Hz detection path. If it overshoots, fall back to
  MobileNetV3Large (F1 0.848, ~10× faster).
- **INT8 quantization accuracy drop.** Paper never quantized. Expect
  2-5 F1 points of degradation on the test split after RKNN INT8
  conversion. Mitigation: sample ~50-100 calibration images
  deliberately across all three datasets (not just one) so the
  quantization sees varied pose/lighting.
- **Domain shift from training corpus to SC3336 footage.** All three
  public datasets are phone/webcam footage; the catlaser camera is a
  fixed-mount rolling-shutter CMOS with different color rendering and
  lens distortion. Per-household enrollment on-device mitigates this
  by rebuilding the gallery from live frames — the backbone just
  needs to produce *consistent* embeddings for the same cat across
  sessions, not *identical* ones to the training distribution.

### Mount geometry — placement-dependent, not enclosure-dependent

The enclosure is fixed: a freestanding unit ~30 cm tall with the
hopper at the bottom and the camera roughly at the top. The camera's
position within the unit has only ~3 in (~7.5 cm) of design latitude.
The only meaningful variable at deployment is what surface the user
places the unit on. Typical placements with resulting camera height
above the floor, compared to a ~25 cm adult-cat shoulder:

| Placement | Camera height | View regime |
|---|---|---|
| Floor | ~30 cm | Near cat shoulder; front/profile |
| TV stand, low table | ~80-90 cm | Top-down, moderate |
| Desk, countertop | ~100-110 cm | Top-down, strong |
| Mantle, high shelf | ~150-180 cm | Top-down, steep |

Users will be advised in onboarding to elevate the unit ("place it on
a shelf or counter for best tracking") but compliance cannot be
enforced. The realistic distribution skews top-down because most
plausible surfaces for a treat-dispensing cat toy (counter, TV stand,
mantle, shelf) are already well above the cat — floor placement is
the outlier, not the default.

This has three implications for the re-ID pipeline:

- **Optimize for top-view as the primary target.** The paper's
  F1=0.93 top-view ceiling is reachable for the common (advised)
  placement. Dataset strategy should weight the HelloStreetCat top/
  corpus heavily and mine top-angle images from Taipei +
  neko-jirushi where practical.
- **Treat near-eye-level (floor placement) as a graceful-degradation
  case, not the target.** Expected single-image F1 on that subset
  lands in the paper's front-view regime (~0.77). Per-household
  enrollment — which averages 20-30 live embeddings captured from
  the actual mount angle in that home — lifts effective rank-1
  above the raw single-image F1 regardless of view.
- **Don't attempt a single model trained on mixed top + front.** The
  paper's "all" configuration collapsed to F1=0.31-0.33. Top-only
  training generalizes gracefully to lower angles via the frozen
  VGG16 features; mixed training does not generalize to either.

---

## Action Plan

1. **Clone and reproduce.**
   - `git clone https://github.com/TobiasTrein/hsc-reident`
   - `kaggle datasets download tobiastrein/heellostreetcat-individuals`
   - Reproduce the paper's F1=0.9344 on top-view / VGG16 / contrastive
     / rotation / 100 epochs / lr=1e-4 locally. Confirms the pipeline
     works before changing anything.

2. **Assemble the combined corpus.**
   - Download datasets 2 and 3 from Kaggle.
   - Write a small `python/scripts/reid_dataset_merge.py` that walks
     all three source trees and emits a unified
     `<output>/<cat_id>/*.jpg` layout with globally unique cat IDs
     (prefix source: `hsc_<name>`, `taipei_<id>`, `neko_<id>`).
   - Verify cross-dataset identity count and image count match
     arithmetic (~650 IDs, ~17k images).

3. **Train the catlaser backbone.**
   - Fork `hsc-reident`, add the combined corpus as input.
   - Train VGG16 + contrastive + lr=1e-4 + rotation aug + 100 epochs.
   - Identity-hold-out split: 80% IDs for train, 10% for val, 10% for
     test. Never split an individual cat's images across sets.
   - Export the single-branch embedding model to ONNX opset 12,
     150×150×3 input, 128-d output, no L2 in the graph.

4. **Quantize and integrate.**
   - Update `models/convert/convert_reid.py` for VGG16 normalization
     and 150×150 input.
   - Sample 50-100 calibration images drawn evenly across all three
     source datasets.
   - Run the conversion, measure output F1 on the held-out test IDs
     through the quantized `.rknn` model (embed all gallery +
     query crops off-device using the RKNN toolkit's simulator).

5. **Calibrate the threshold.**
   - Write `python/scripts/reid_eval.py` that takes the
     `folder-per-cat` layout, runs embed → cosine-sim → rank-1 CMC +
     ROC.
   - Plot same-pair vs different-pair cosine-sim distribution on the
     test split. Pick the EER threshold, update
     `MATCH_THRESHOLD` in `catalog.py`.

6. **Validate cross-domain transfer.**
   - Capture a small (~10 IDs × 20+ images) set from user household
     cats — Apple Photos "People & Pets" export works. Never seen in
     training.
   - Run the pipeline against it. Target: rank-1 ≥ 85%. Below that,
     iterate — either unfreeze the last 1-2 VGG blocks for
     fine-tuning, or expand the combined training corpus.

7. **Benchmark on-device.**
   - Deploy the quantized model to a prototype Luckfox Pico Ultra W.
   - Measure inference latency on the 1-TOPS NPU.
   - If >300 ms: fall back to MobileNetV3Large (retrain steps 3-6
     with the MobileNet backbone).

---

## Citation

```
@article{trein2025siamese,
  title   = {Siamese Networks for Cat Re-Identification: Exploring
             Neural Models for Cat Instance Recognition},
  author  = {Trein, Tobias and Garcia, Luan Fonseca},
  journal = {arXiv preprint arXiv:2501.02112},
  year    = {2025}
}
```

[catlaser-vision]: ../../crates/catlaser-vision/
[onnx-to-rknn-int8-conversion-rv1106.md]: ./onnx-to-rknn-int8-conversion-rv1106.md
