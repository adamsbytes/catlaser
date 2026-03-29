//! Person detection filtering and safety ceiling computation.
//!
//! The YOLO model detects both cats and people in a single pass. This module
//! separates person detections from cat detections and computes a single
//! normalized `safety_ceiling_y` value from person bounding boxes.
//!
//! The safety ceiling is the lowest point where the laser may operate when
//! people are in frame. It is computed as 75% of the lowest detected person's
//! bounding box height — allowing floor-level play to continue with humans
//! present while keeping the laser well below eye height.
//!
//! Python never sees individual person bounding boxes — only the pre-computed
//! ceiling value and a boolean flag.

use crate::detect::Detection;

// ---------------------------------------------------------------------------
// COCO class IDs
// ---------------------------------------------------------------------------

/// COCO class ID for "person" (class 0).
const COCO_PERSON: u16 = 0_u16;

/// COCO class ID for "cat" (class 15).
const COCO_CAT: u16 = 15_u16;

/// Sentinel value for `safety_ceiling_y` when no person is detected.
///
/// Negative value signals "no constraint" to downstream consumers.
/// Matches the proto contract: "Negative if no person detected."
const NO_PERSON_CEILING: f32 = -1.0_f32;

/// Fraction of person bbox height at which the safety ceiling is placed.
///
/// 0.75 means the ceiling line sits 75% of the way down from the top of
/// the person's bounding box — well below the head/eye region.
const CEILING_HEIGHT_FRACTION: f32 = 0.75_f32;

/// Number of frames to hold the safety ceiling after the last person detection.
///
/// At ~15 FPS, 30 frames ≈ 2 seconds of hold time. This prevents the ceiling
/// from dropping on single-frame detection misses (common with INT8 quantized
/// inference) — a one-frame gap in person detection must not release the
/// safety constraint.
const CEILING_HOLD_FRAMES: u32 = 30_u32;

// ---------------------------------------------------------------------------
// Safety result
// ---------------------------------------------------------------------------

/// Output of per-frame safety ceiling computation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct SafetyResult {
    /// Normalized y-coordinate of the safety ceiling (0.0 = top, 1.0 = bottom).
    ///
    /// The laser must stay below (greater y than) this line. Negative (-1.0)
    /// when no person is detected — meaning no ceiling constraint.
    pub ceiling_y: f32,
    /// Whether at least one person was detected in this frame.
    pub person_in_frame: bool,
}

// ---------------------------------------------------------------------------
// Safety computer
// ---------------------------------------------------------------------------

/// Filters detections by class and computes the per-frame safety ceiling.
///
/// Computes the ceiling for every detected person and takes the most
/// restrictive (highest y) value. This guarantees the laser stays below
/// the 75% line of *all* detected persons — a close, tall person cannot
/// mask a smaller person sitting on the floor further away.
///
/// Maintains a temporal hold-off so the ceiling persists for
/// [`CEILING_HOLD_FRAMES`] after the last person detection, preventing
/// single-frame detection misses from momentarily releasing the safety
/// constraint. The `person_in_frame` flag shares the same hold-off so
/// the MCU's tightened tilt limit stays engaged for the full hold
/// duration.
#[derive(Debug)]
pub(crate) struct SafetyComputer {
    cat_detections: Vec<Detection>,
    /// Most restrictive ceiling value across all detected persons.
    held_ceiling_y: f32,
    /// Frames remaining before the held ceiling expires.
    hold_remaining: u32,
    /// Whether the ceiling constraint is currently active (fresh or held).
    ceiling_active: bool,
}

impl SafetyComputer {
    /// Creates a new safety computer with empty buffers.
    pub(crate) const fn new() -> Self {
        Self {
            cat_detections: Vec::new(),
            held_ceiling_y: NO_PERSON_CEILING,
            hold_remaining: 0_u32,
            ceiling_active: false,
        }
    }

    /// Processes a frame's detections, separating cats from persons.
    ///
    /// Returns the safety ceiling result. After calling this, use
    /// [`cat_detections()`](Self::cat_detections) to get the cat-only
    /// detection slice for the tracker.
    ///
    /// The ceiling is the most restrictive (highest y) value across all
    /// detected persons. This ensures the laser stays below the 75% line
    /// of every person in the frame — not just the one closest to the
    /// floor. When no person is detected, the previously computed ceiling
    /// and `person_in_frame` flag are held for up to
    /// [`CEILING_HOLD_FRAMES`] before relaxing.
    pub(crate) fn process(&mut self, detections: &[Detection], model_height: f32) -> SafetyResult {
        self.cat_detections.clear();

        // Compute ceiling for every person and take the maximum (most
        // restrictive). A close tall person must not mask a smaller person
        // sitting on the floor further away.
        let mut max_ceiling: Option<f32> = None;

        for det in detections {
            match det.class_id {
                COCO_CAT => {
                    self.cat_detections.push(*det);
                }
                COCO_PERSON => {
                    let ceiling = person_ceiling_y(&det.bbox, model_height);
                    max_ceiling = Some(max_ceiling.map_or(ceiling, |prev| prev.max(ceiling)));
                }
                _ => {}
            }
        }

        if let Some(ceiling_y) = max_ceiling {
            // Person detected — update held ceiling and reset hold timer.
            self.held_ceiling_y = ceiling_y;
            self.hold_remaining = CEILING_HOLD_FRAMES;
            self.ceiling_active = true;
        } else if self.hold_remaining > 0 {
            // No person this frame but hold-off is active — keep the
            // previous ceiling to ride through detection gaps.
            self.hold_remaining = self.hold_remaining.saturating_sub(1_u32);
        } else {
            // Hold-off expired — release constraint.
            self.held_ceiling_y = NO_PERSON_CEILING;
            self.ceiling_active = false;
        }

        // person_in_frame tracks ceiling_active: true whenever the
        // ceiling constraint is engaged (fresh detection or held from
        // a recent one). This prevents the MCU's tightened tilt limit
        // from flickering on/off during INT8 detection gaps while the
        // ceiling stays engaged.
        SafetyResult {
            ceiling_y: self.held_ceiling_y,
            person_in_frame: self.ceiling_active,
        }
    }

    /// Returns the cat-only detections from the most recent [`process()`](Self::process) call.
    ///
    /// This slice is valid until the next call to `process()`.
    pub(crate) fn cat_detections(&self) -> &[Detection] {
        &self.cat_detections
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Computes the normalized safety ceiling y-coordinate for a single person bbox.
///
/// The ceiling sits at `CEILING_HEIGHT_FRACTION` (75%) of the way down from
/// the top of the person's bounding box. This places the laser cutoff well
/// below head height while allowing floor-level play.
///
/// Returns a value in 0.0–1.0 (normalized by model height).
fn person_ceiling_y(bbox: &crate::detect::BoundingBox, model_height: f32) -> f32 {
    let bbox_height = bbox.y2 - bbox.y1;
    CEILING_HEIGHT_FRACTION.mul_add(bbox_height, bbox.y1) / model_height
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[expect(
    clippy::indexing_slicing,
    clippy::float_cmp,
    clippy::suboptimal_flops,
    reason = "test code: indexing on known-size arrays, \
              float_cmp on exact sentinel values (-1.0) perfectly representable in IEEE 754, \
              suboptimal_flops in expected-value computation mirrors the formula for readability"
)]
mod tests {
    use super::*;
    use crate::detect::BoundingBox;
    use proptest::prelude::*;

    const MODEL_H: f32 = 480.0_f32;

    fn make_bbox(x1: f32, y1: f32, x2: f32, y2: f32) -> BoundingBox {
        BoundingBox { x1, y1, x2, y2 }
    }

    fn person(x1: f32, y1: f32, x2: f32, y2: f32) -> Detection {
        Detection {
            bbox: make_bbox(x1, y1, x2, y2),
            class_id: COCO_PERSON,
            confidence: 0.9_f32,
        }
    }

    fn cat(x1: f32, y1: f32, x2: f32, y2: f32) -> Detection {
        Detection {
            bbox: make_bbox(x1, y1, x2, y2),
            class_id: COCO_CAT,
            confidence: 0.85_f32,
        }
    }

    fn dog(x1: f32, y1: f32, x2: f32, y2: f32) -> Detection {
        Detection {
            bbox: make_bbox(x1, y1, x2, y2),
            class_id: 16_u16,
            confidence: 0.7_f32,
        }
    }

    // -------------------------------------------------------------------
    // No persons
    // -------------------------------------------------------------------

    #[test]
    fn test_no_detections_returns_no_ceiling() {
        let mut sc = SafetyComputer::new();
        let result = sc.process(&[], MODEL_H);

        assert_eq!(
            result.ceiling_y, NO_PERSON_CEILING,
            "no detections should produce sentinel ceiling"
        );
        assert!(
            !result.person_in_frame,
            "no detections should have person_in_frame false"
        );
        assert!(
            sc.cat_detections().is_empty(),
            "no detections should produce empty cat list"
        );
    }

    #[test]
    fn test_cats_only_returns_no_ceiling() {
        let mut sc = SafetyComputer::new();
        let dets = [
            cat(100.0_f32, 200.0_f32, 200.0_f32, 300.0_f32),
            cat(300.0_f32, 100.0_f32, 400.0_f32, 250.0_f32),
        ];
        let result = sc.process(&dets, MODEL_H);

        assert_eq!(
            result.ceiling_y, NO_PERSON_CEILING,
            "cats only should produce sentinel ceiling"
        );
        assert!(
            !result.person_in_frame,
            "cats only should have person_in_frame false"
        );
        assert_eq!(
            sc.cat_detections().len(),
            2,
            "both cat detections should pass through"
        );
    }

    #[test]
    fn test_other_classes_ignored() {
        let mut sc = SafetyComputer::new();
        let dets = [dog(50.0_f32, 50.0_f32, 150.0_f32, 150.0_f32)];
        let result = sc.process(&dets, MODEL_H);

        assert_eq!(
            result.ceiling_y, NO_PERSON_CEILING,
            "non-person non-cat class should produce sentinel ceiling"
        );
        assert!(
            !result.person_in_frame,
            "non-person class should not set person_in_frame"
        );
        assert!(
            sc.cat_detections().is_empty(),
            "non-cat class should not appear in cat detections"
        );
    }

    // -------------------------------------------------------------------
    // Single person
    // -------------------------------------------------------------------

    #[test]
    fn test_single_person_ceiling_at_75_percent() {
        let mut sc = SafetyComputer::new();
        // Person bbox: y1=100, y2=300 → height=200, ceiling at 100 + 0.75*200 = 250
        // Normalized: 250 / 480
        let dets = [person(100.0_f32, 100.0_f32, 300.0_f32, 300.0_f32)];
        let result = sc.process(&dets, MODEL_H);

        let expected = 250.0_f32 / MODEL_H;
        assert!(
            (result.ceiling_y - expected).abs() < 1e-6_f32,
            "ceiling should be at 75% of person bbox, expected {expected}, got {}",
            result.ceiling_y
        );
        assert!(
            result.person_in_frame,
            "person detection should set person_in_frame true"
        );
    }

    #[test]
    fn test_single_person_no_cats_returned() {
        let mut sc = SafetyComputer::new();
        let dets = [person(50.0_f32, 50.0_f32, 200.0_f32, 400.0_f32)];
        let _ = sc.process(&dets, MODEL_H);

        assert!(
            sc.cat_detections().is_empty(),
            "person detection should not appear in cat detections"
        );
    }

    // -------------------------------------------------------------------
    // Multiple persons — most restrictive ceiling wins
    // -------------------------------------------------------------------

    #[test]
    fn test_multiple_persons_most_restrictive_ceiling_wins() {
        let mut sc = SafetyComputer::new();
        // Person A: y1=200, y2=400 → lowest in frame (highest y2)
        //   ceiling at 200 + 0.75*200 = 350 → 350/480 = 0.729
        // Person B: y1=50, y2=300 → higher in frame
        //   ceiling at 50 + 0.75*250 = 237.5 → 237.5/480 = 0.495
        // Person A's ceiling (0.729) is more restrictive, so it is used.
        let dets = [
            person(100.0_f32, 200.0_f32, 300.0_f32, 400.0_f32),
            person(400.0_f32, 50.0_f32, 550.0_f32, 300.0_f32),
        ];
        let result = sc.process(&dets, MODEL_H);

        let expected = 350.0_f32 / MODEL_H;
        assert!(
            (result.ceiling_y - expected).abs() < 1e-6_f32,
            "ceiling should use the most restrictive person, expected {expected}, got {}",
            result.ceiling_y
        );
    }

    #[test]
    fn test_multiple_persons_small_floor_person_dominates_tall_close_person() {
        let mut sc = SafetyComputer::new();
        // Person B: adult standing close to camera, nearly full frame
        //   y1=0, y2=460 → ceiling at 0 + 0.75*460 = 345 → 345/480 = 0.719
        // Person A: child sitting on floor further away, small bbox near bottom
        //   y1=400, y2=450 → ceiling at 400 + 0.75*50 = 437.5 → 437.5/480 = 0.911
        //
        // Person A's ceiling (0.911) is more restrictive despite having a
        // lower y2 than Person B. The laser must be below both persons'
        // 75% lines.
        let dets = [
            person(50.0_f32, 0.0_f32, 600.0_f32, 460.0_f32),
            person(300.0_f32, 400.0_f32, 400.0_f32, 450.0_f32),
        ];
        let result = sc.process(&dets, MODEL_H);

        let expected = 437.5_f32 / MODEL_H;
        assert!(
            (result.ceiling_y - expected).abs() < 1e-5_f32,
            "ceiling should use the small floor person (higher ceiling), expected {expected}, got {}",
            result.ceiling_y
        );
    }

    // -------------------------------------------------------------------
    // Mixed cats + persons
    // -------------------------------------------------------------------

    #[test]
    fn test_mixed_cats_and_persons_filtered_correctly() {
        let mut sc = SafetyComputer::new();
        let cat_det = cat(300.0_f32, 350.0_f32, 400.0_f32, 450.0_f32);
        let dets = [
            person(50.0_f32, 50.0_f32, 200.0_f32, 350.0_f32),
            cat_det,
            person(400.0_f32, 100.0_f32, 550.0_f32, 400.0_f32),
        ];
        let result = sc.process(&dets, MODEL_H);

        assert!(
            result.person_in_frame,
            "persons present should set person_in_frame"
        );
        assert_eq!(
            sc.cat_detections().len(),
            1,
            "only cat detections should be in cat list"
        );
        assert_eq!(
            sc.cat_detections()[0].class_id,
            COCO_CAT,
            "filtered detection should be a cat"
        );
        assert!(
            result.ceiling_y > 0.0_f32,
            "ceiling should be positive when persons are present"
        );
    }

    // -------------------------------------------------------------------
    // Boundary cases: person at frame edges
    // -------------------------------------------------------------------

    #[test]
    fn test_person_at_top_of_frame() {
        let mut sc = SafetyComputer::new();
        // Person at very top: y1=0, y2=100 → ceiling at 0 + 0.75*100 = 75 → 75/480
        let dets = [person(100.0_f32, 0.0_f32, 300.0_f32, 100.0_f32)];
        let result = sc.process(&dets, MODEL_H);

        let expected = 75.0_f32 / MODEL_H;
        assert!(
            (result.ceiling_y - expected).abs() < 1e-6_f32,
            "person at top should produce low ceiling, expected {expected}, got {}",
            result.ceiling_y
        );
    }

    #[test]
    fn test_person_at_bottom_of_frame() {
        let mut sc = SafetyComputer::new();
        // Person at bottom: y1=380, y2=480 → ceiling at 380 + 0.75*100 = 455 → 455/480
        let dets = [person(100.0_f32, 380.0_f32, 300.0_f32, 480.0_f32)];
        let result = sc.process(&dets, MODEL_H);

        let expected = 455.0_f32 / MODEL_H;
        assert!(
            (result.ceiling_y - expected).abs() < 1e-6_f32,
            "person at bottom should produce high ceiling, expected {expected}, got {}",
            result.ceiling_y
        );
        assert!(result.ceiling_y <= 1.0_f32, "ceiling should not exceed 1.0");
    }

    #[test]
    fn test_person_spanning_full_frame() {
        let mut sc = SafetyComputer::new();
        // Person fills entire frame: y1=0, y2=480 → ceiling at 0 + 0.75*480 = 360 → 360/480 = 0.75
        let dets = [person(0.0_f32, 0.0_f32, 640.0_f32, 480.0_f32)];
        let result = sc.process(&dets, MODEL_H);

        assert!(
            (result.ceiling_y - CEILING_HEIGHT_FRACTION).abs() < 1e-6_f32,
            "full-frame person should produce ceiling at exactly the height fraction, got {}",
            result.ceiling_y
        );
    }

    // -------------------------------------------------------------------
    // Degenerate cases
    // -------------------------------------------------------------------

    #[test]
    fn test_tiny_person_bbox() {
        let mut sc = SafetyComputer::new();
        // Very small person: y1=200, y2=201 → height=1, ceiling at 200 + 0.75 = 200.75
        let dets = [person(300.0_f32, 200.0_f32, 305.0_f32, 201.0_f32)];
        let result = sc.process(&dets, MODEL_H);

        let expected = 200.75_f32 / MODEL_H;
        assert!(
            (result.ceiling_y - expected).abs() < 1e-5_f32,
            "tiny person should still produce valid ceiling, expected {expected}, got {}",
            result.ceiling_y
        );
        assert!(
            result.person_in_frame,
            "tiny person should still count as person_in_frame"
        );
    }

    #[test]
    fn test_zero_height_person_bbox() {
        let mut sc = SafetyComputer::new();
        // Degenerate zero-height bbox: y1=200, y2=200 → height=0, ceiling at 200/480
        let dets = [person(300.0_f32, 200.0_f32, 350.0_f32, 200.0_f32)];
        let result = sc.process(&dets, MODEL_H);

        let expected = 200.0_f32 / MODEL_H;
        assert!(
            (result.ceiling_y - expected).abs() < 1e-6_f32,
            "zero-height person should produce ceiling at bbox y position, expected {expected}, got {}",
            result.ceiling_y
        );
    }

    // -------------------------------------------------------------------
    // Temporal hold-off
    // -------------------------------------------------------------------

    #[test]
    fn test_ceiling_held_after_person_disappears() {
        let mut sc = SafetyComputer::new();
        let person_det = [person(100.0_f32, 100.0_f32, 300.0_f32, 400.0_f32)];
        let ceiling_with_person = sc.process(&person_det, MODEL_H).ceiling_y;

        // One frame without person — ceiling and person_in_frame should
        // both be held so the MCU's tightened limit stays engaged.
        let r = sc.process(&[], MODEL_H);
        assert!(
            r.person_in_frame,
            "person_in_frame should be held during hold-off"
        );
        assert_eq!(
            r.ceiling_y, ceiling_with_person,
            "ceiling should be held on the frame after person disappears"
        );
    }

    #[test]
    fn test_ceiling_held_for_full_hold_period() {
        let mut sc = SafetyComputer::new();
        let person_det = [person(100.0_f32, 100.0_f32, 300.0_f32, 400.0_f32)];
        let ceiling_with_person = sc.process(&person_det, MODEL_H).ceiling_y;

        // Run exactly CEILING_HOLD_FRAMES empty frames — both ceiling and
        // person_in_frame should be held on every one.
        for i in 0..CEILING_HOLD_FRAMES {
            let r = sc.process(&[], MODEL_H);
            assert_eq!(
                r.ceiling_y, ceiling_with_person,
                "ceiling should be held during hold frame {i}"
            );
            assert!(
                r.person_in_frame,
                "person_in_frame should be held during hold frame {i}"
            );
        }
    }

    #[test]
    fn test_ceiling_released_after_hold_expires() {
        let mut sc = SafetyComputer::new();
        let person_det = [person(100.0_f32, 100.0_f32, 300.0_f32, 400.0_f32)];
        let _ = sc.process(&person_det, MODEL_H);

        // Exhaust the hold period.
        for _ in 0..CEILING_HOLD_FRAMES {
            let _ = sc.process(&[], MODEL_H);
        }

        // One more frame — hold expired, ceiling should release.
        let r = sc.process(&[], MODEL_H);
        assert_eq!(
            r.ceiling_y, NO_PERSON_CEILING,
            "ceiling should release to sentinel after hold expires"
        );
        assert!(
            !r.person_in_frame,
            "person_in_frame should be false after hold expires"
        );
    }

    #[test]
    fn test_person_redetection_resets_hold_timer() {
        let mut sc = SafetyComputer::new();
        let person_det = [person(100.0_f32, 100.0_f32, 300.0_f32, 400.0_f32)];
        let ceiling_with_person = sc.process(&person_det, MODEL_H).ceiling_y;

        // Drain most of the hold period.
        for _ in 0..(CEILING_HOLD_FRAMES.saturating_sub(2_u32)) {
            let _ = sc.process(&[], MODEL_H);
        }

        // Re-detect person — should reset the timer.
        let _ = sc.process(&person_det, MODEL_H);

        // Full hold period again from the re-detection.
        for i in 0..CEILING_HOLD_FRAMES {
            let r = sc.process(&[], MODEL_H);
            assert_eq!(
                r.ceiling_y, ceiling_with_person,
                "ceiling should be held after re-detection, frame {i}"
            );
        }

        // Now it should expire.
        let r = sc.process(&[], MODEL_H);
        assert_eq!(
            r.ceiling_y, NO_PERSON_CEILING,
            "ceiling should release after full hold from re-detection"
        );
    }

    #[test]
    fn test_cat_detections_reset_during_hold() {
        let mut sc = SafetyComputer::new();
        // Frame 1: cat + person.
        let dets1 = [
            cat(100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32),
            person(300.0_f32, 50.0_f32, 450.0_f32, 300.0_f32),
        ];
        let r1 = sc.process(&dets1, MODEL_H);
        assert!(r1.person_in_frame, "frame 1 should detect person");
        assert_eq!(sc.cat_detections().len(), 1, "frame 1 should have 1 cat");

        // Frame 2: two different cats, no person (ceiling and person_in_frame held).
        let dets2 = [
            cat(100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32),
            cat(400.0_f32, 300.0_f32, 500.0_f32, 400.0_f32),
        ];
        let r2 = sc.process(&dets2, MODEL_H);
        assert!(
            r2.person_in_frame,
            "frame 2 should hold person_in_frame during hold-off"
        );
        assert!(
            r2.ceiling_y > 0.0_f32,
            "frame 2 ceiling should still be active from hold-off"
        );
        assert_eq!(
            sc.cat_detections().len(),
            2,
            "frame 2 should have 2 cats, not carry over from frame 1"
        );
    }

    // -------------------------------------------------------------------
    // Ceiling computation unit tests
    // -------------------------------------------------------------------

    #[test]
    fn test_person_ceiling_y_basic() {
        let bbox = make_bbox(0.0_f32, 100.0_f32, 200.0_f32, 500.0_f32);
        // height = 400, ceiling at 100 + 0.75*400 = 400, normalized = 400/480
        let result = person_ceiling_y(&bbox, MODEL_H);
        let expected = 400.0_f32 / MODEL_H;
        assert!(
            (result - expected).abs() < 1e-6_f32,
            "expected {expected}, got {result}"
        );
    }

    // -------------------------------------------------------------------
    // Property tests
    // -------------------------------------------------------------------

    proptest! {
        /// The ceiling y equals the 75% point of the person bbox.
        #[test]
        fn test_ceiling_within_person_bbox(
            y1 in 0.0_f32..400.0_f32,
            height in 1.0_f32..480.0_f32,
        ) {
            let y2 = (y1 + height).min(480.0_f32);
            let actual_height = y2 - y1;
            let det = person(100.0_f32, y1, 300.0_f32, y2);
            let mut sc = SafetyComputer::new();
            let result = sc.process(&[det], MODEL_H);

            let expected = (y1 + CEILING_HEIGHT_FRACTION * actual_height) / MODEL_H;
            prop_assert!(
                (result.ceiling_y - expected).abs() < 1e-5_f32,
                "ceiling {} should equal 75% point {} for y1={}, y2={}",
                result.ceiling_y, expected, y1, y2,
            );
        }

        /// With persons present, ceiling is always non-negative.
        #[test]
        fn test_ceiling_non_negative_with_persons(
            y1 in 0.0_f32..479.0_f32,
            y2_offset in 1.0_f32..480.0_f32,
        ) {
            let y2 = (y1 + y2_offset).min(480.0_f32);
            let det = person(0.0_f32, y1, 640.0_f32, y2);
            let mut sc = SafetyComputer::new();
            let result = sc.process(&[det], MODEL_H);

            prop_assert!(
                result.ceiling_y >= 0.0_f32,
                "ceiling must be non-negative when person present, got {}",
                result.ceiling_y,
            );
            prop_assert!(
                result.person_in_frame,
                "person_in_frame must be true when person detection present",
            );
        }

        /// Without persons (fresh computer, no hold-off), ceiling is sentinel.
        #[test]
        fn test_no_person_always_sentinel(
            x1 in 0.0_f32..500.0_f32,
            y1 in 0.0_f32..400.0_f32,
            w in 10.0_f32..140.0_f32,
            h in 10.0_f32..80.0_f32,
            n_cats in 0_usize..5_usize,
        ) {
            let dets: Vec<Detection> = (0..n_cats)
                .map(|_| cat(x1, y1, x1 + w, y1 + h))
                .collect();
            let mut sc = SafetyComputer::new();
            let result = sc.process(&dets, MODEL_H);

            prop_assert_eq!(
                result.ceiling_y, NO_PERSON_CEILING,
                "no persons should always produce sentinel ceiling",
            );
            prop_assert!(
                !result.person_in_frame,
                "no persons should have person_in_frame false",
            );
            prop_assert_eq!(
                sc.cat_detections().len(), n_cats,
                "all cat detections should pass through",
            );
        }

        /// With multiple persons, the ceiling is the most restrictive (highest y).
        #[test]
        fn test_multi_person_ceiling_uses_most_restrictive(
            y1a in 0.0_f32..300.0_f32,
            ha in 50.0_f32..180.0_f32,
            y1b in 0.0_f32..300.0_f32,
            hb in 50.0_f32..180.0_f32,
        ) {
            let y2a = (y1a + ha).min(480.0_f32);
            let y2b = (y1b + hb).min(480.0_f32);
            let dets = [
                person(50.0_f32, y1a, 200.0_f32, y2a),
                person(300.0_f32, y1b, 450.0_f32, y2b),
            ];
            let mut sc = SafetyComputer::new();
            let result = sc.process(&dets, MODEL_H);

            let ceiling_a = (y1a + CEILING_HEIGHT_FRACTION * (y2a - y1a)) / MODEL_H;
            let ceiling_b = (y1b + CEILING_HEIGHT_FRACTION * (y2b - y1b)) / MODEL_H;
            let expected = ceiling_a.max(ceiling_b);

            prop_assert!(
                (result.ceiling_y - expected).abs() < 1e-5_f32,
                "ceiling {} should match most restrictive person's ceiling {}",
                result.ceiling_y, expected,
            );
        }

        /// Ceiling is bounded to [0.0, 1.0] for any valid bbox within frame.
        #[test]
        fn test_ceiling_bounded_zero_to_one(
            y1 in 0.0_f32..480.0_f32,
            h in 0.0_f32..480.0_f32,
        ) {
            let y2 = (y1 + h).min(480.0_f32);
            let det = person(0.0_f32, y1, 640.0_f32, y2);
            let mut sc = SafetyComputer::new();
            let result = sc.process(&[det], MODEL_H);

            prop_assert!(
                result.ceiling_y >= 0.0_f32 && result.ceiling_y <= 1.0_f32,
                "ceiling must be in [0, 1] for in-frame bbox, got {}",
                result.ceiling_y,
            );
        }
    }
}
