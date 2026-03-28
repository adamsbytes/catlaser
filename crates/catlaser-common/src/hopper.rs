//! Hopper IR break-beam sensor debounce logic.
//!
//! The [`HopperDebouncer`] implements asymmetric debouncing for the treat
//! hopper level sensor:
//!
//! - **Empty requires confirmation:** N consecutive "empty" readings
//!   (configurable via threshold) before reporting empty. This prevents
//!   momentary beam-clear events (treat bouncing, shifting) from falsely
//!   blocking autonomous sessions.
//!
//! - **Present is immediate:** A single "present" reading resets the
//!   counter and reports present. False-present only causes a dry dispense
//!   cycle, which is tolerable compared to false-empty blocking play.
//!
//! This module lives in `catlaser-common` so the debounce state machine is
//! fully testable on the host without embedded hardware.

/// Debounces the hopper IR break-beam sensor.
///
/// Tracks consecutive "empty" readings and only transitions to the empty
/// state after the configured threshold is reached. Any "present" reading
/// immediately resets to present.
///
/// # Sensor convention
///
/// The IR break-beam sensor at the hopper base:
/// - **Beam blocked** (treats present) → sensor GPIO reads LOW
/// - **Beam clear** (hopper empty) → sensor GPIO reads HIGH
///
/// Callers translate the GPIO level to `beam_clear: bool` before calling
/// [`update`](Self::update).
#[derive(Debug)]
pub struct HopperDebouncer {
    /// Number of consecutive "empty" (beam clear) readings observed.
    empty_count: u8,
    /// Required consecutive empty readings before reporting empty.
    threshold: u8,
    /// Current debounced state: `true` = hopper empty.
    is_empty: bool,
}

impl HopperDebouncer {
    /// Creates a new debouncer.
    ///
    /// Starts in the "present" (not empty) state. The hopper is assumed to
    /// have treats until proven otherwise by sustained sensor readings.
    #[must_use]
    pub const fn new(threshold: u8) -> Self {
        Self {
            empty_count: 0_u8,
            threshold,
            is_empty: false,
        }
    }

    /// Feeds a new sensor reading and returns the debounced hopper state.
    ///
    /// - `beam_clear`: `true` if the IR beam is unobstructed (hopper empty
    ///   at sensor level), `false` if blocked (treats present).
    ///
    /// Returns `true` if the hopper is considered empty after this reading.
    pub const fn update(&mut self, beam_clear: bool) -> bool {
        if beam_clear {
            self.empty_count = self.empty_count.saturating_add(1_u8);
            if self.empty_count >= self.threshold {
                self.is_empty = true;
            }
        } else {
            self.empty_count = 0_u8;
            self.is_empty = false;
        }

        self.is_empty
    }

    /// Returns the current debounced state without feeding a new reading.
    ///
    /// `true` = hopper empty, `false` = treats present.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.is_empty
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::constants::HOPPER_DEBOUNCE_THRESHOLD;
    use proptest::prelude::*;

    // --- initial state ---

    #[test]
    fn test_new_starts_as_present() {
        let debouncer = HopperDebouncer::new(4_u8);
        assert!(
            !debouncer.is_empty(),
            "new debouncer must start as present (not empty)"
        );
    }

    // --- transition to empty ---

    #[test]
    fn test_single_empty_reading_does_not_trigger() {
        let mut debouncer = HopperDebouncer::new(4_u8);
        let result = debouncer.update(true);
        assert!(!result, "single empty reading must not trigger empty state");
        assert!(
            !debouncer.is_empty(),
            "is_empty must agree with update return value"
        );
    }

    #[test]
    fn test_one_below_threshold_does_not_trigger() {
        let mut debouncer = HopperDebouncer::new(4_u8);
        for _ in 0_u8..3_u8 {
            debouncer.update(true);
        }
        assert!(
            !debouncer.is_empty(),
            "threshold-1 consecutive empty readings must not trigger empty"
        );
    }

    #[test]
    fn test_exact_threshold_triggers_empty() {
        let mut debouncer = HopperDebouncer::new(4_u8);
        for i in 0_u8..4_u8 {
            let result = debouncer.update(true);
            if i < 3_u8 {
                assert!(!result, "reading {i} must not yet trigger empty");
            } else {
                assert!(result, "reading at threshold must trigger empty");
            }
        }
        assert!(
            debouncer.is_empty(),
            "must be empty after threshold consecutive readings"
        );
    }

    #[test]
    fn test_above_threshold_stays_empty() {
        let mut debouncer = HopperDebouncer::new(4_u8);
        for _ in 0_u8..10_u8 {
            debouncer.update(true);
        }
        assert!(
            debouncer.is_empty(),
            "must remain empty with continued empty readings"
        );
    }

    // --- transition back to present ---

    #[test]
    fn test_single_present_resets_from_empty() {
        let mut debouncer = HopperDebouncer::new(4_u8);
        // Drive to empty.
        for _ in 0_u8..4_u8 {
            debouncer.update(true);
        }
        assert!(debouncer.is_empty(), "precondition: must be empty");

        // Single present reading resets.
        let result = debouncer.update(false);
        assert!(!result, "single present reading must reset to present");
        assert!(
            !debouncer.is_empty(),
            "is_empty must be false after present reading"
        );
    }

    #[test]
    fn test_present_mid_debounce_resets_count() {
        let mut debouncer = HopperDebouncer::new(4_u8);
        // 3 empty readings (one below threshold).
        for _ in 0_u8..3_u8 {
            debouncer.update(true);
        }
        // Interrupt with a present reading.
        debouncer.update(false);

        // 3 more empty readings — still below threshold because count reset.
        for _ in 0_u8..3_u8 {
            debouncer.update(true);
        }
        assert!(
            !debouncer.is_empty(),
            "present reading mid-debounce must reset the counter"
        );
    }

    // --- threshold of 1 (edge case) ---

    #[test]
    fn test_threshold_one_triggers_immediately() {
        let mut debouncer = HopperDebouncer::new(1_u8);
        let result = debouncer.update(true);
        assert!(
            result,
            "threshold=1 must trigger empty on first empty reading"
        );
    }

    #[test]
    fn test_threshold_one_resets_on_present() {
        let mut debouncer = HopperDebouncer::new(1_u8);
        debouncer.update(true);
        assert!(debouncer.is_empty(), "precondition: must be empty");

        debouncer.update(false);
        assert!(
            !debouncer.is_empty(),
            "threshold=1 must reset on present reading"
        );
    }

    // --- saturating count (no overflow) ---

    #[test]
    fn test_empty_count_saturates_at_u8_max() {
        let mut debouncer = HopperDebouncer::new(4_u8);
        // Feed 300 consecutive empty readings — must not overflow.
        for _ in 0_u16..300_u16 {
            debouncer.update(true);
        }
        assert!(debouncer.is_empty(), "must remain empty without overflow");
    }

    // --- project constant ---

    #[test]
    fn test_project_threshold_triggers_correctly() {
        let mut debouncer = HopperDebouncer::new(HOPPER_DEBOUNCE_THRESHOLD);

        // One below threshold: still present.
        for _ in 1_u8..HOPPER_DEBOUNCE_THRESHOLD {
            debouncer.update(true);
        }
        assert!(
            !debouncer.is_empty(),
            "threshold-1 readings with project constant must not trigger"
        );

        // Exactly at threshold: empty.
        debouncer.update(true);
        assert!(
            debouncer.is_empty(),
            "threshold readings with project constant must trigger empty"
        );
    }

    // --- proptest ---

    proptest! {
        #[test]
        fn test_alternating_never_triggers_empty(
            threshold in 2_u8..=255_u8,
            cycles in 1_usize..200_usize,
        ) {
            let mut debouncer = HopperDebouncer::new(threshold);
            for _ in 0_usize..cycles {
                debouncer.update(true);
                debouncer.update(false);
            }
            prop_assert!(
                !debouncer.is_empty(),
                "alternating readings must never trigger empty (threshold={})",
                threshold,
            );
        }

        #[test]
        fn test_consecutive_empty_always_triggers(
            threshold in 1_u8..=100_u8,
            extra in 0_u8..=50_u8,
        ) {
            let mut debouncer = HopperDebouncer::new(threshold);
            let total = u16::from(threshold).saturating_add(u16::from(extra));
            for _ in 0_u16..total {
                debouncer.update(true);
            }
            prop_assert!(
                debouncer.is_empty(),
                "{}+ consecutive empty readings must trigger empty (threshold={})",
                total, threshold,
            );
        }

        #[test]
        fn test_present_always_resets(
            threshold in 1_u8..=100_u8,
            empty_before in 0_u8..=200_u8,
        ) {
            let mut debouncer = HopperDebouncer::new(threshold);
            for _ in 0_u16..u16::from(empty_before) {
                debouncer.update(true);
            }
            debouncer.update(false);
            prop_assert!(
                !debouncer.is_empty(),
                "present reading must always reset to present (threshold={}, empty_before={})",
                threshold, empty_before,
            );
        }

        #[test]
        fn test_update_return_matches_is_empty(
            threshold in 1_u8..=50_u8,
            readings in proptest::collection::vec(any::<bool>(), 1..100),
        ) {
            let mut debouncer = HopperDebouncer::new(threshold);
            for &beam_clear in &readings {
                let returned = debouncer.update(beam_clear);
                prop_assert_eq!(
                    returned,
                    debouncer.is_empty(),
                    "update() return must match is_empty()",
                );
            }
        }
    }
}
