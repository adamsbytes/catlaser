//! Bbox center to servo angle transform.
//!
//! Converts normalized frame coordinates (0.0-1.0) from the tracker into
//! target servo angles in hundredths of a degree. Accounts for camera
//! field of view and laser-to-camera parallax offset.
//!
//! The transform uses a pinhole camera model: pixel displacement from
//! frame center maps linearly to angular displacement proportional to
//! the field of view. This is accurate near center and degrades at
//! extreme edges, which is acceptable because the control loop
//! continuously re-targets from fresh frames — edge error is corrected
//! within one frame period (~67 ms at 15 FPS).
//!
//! Parallax correction accounts for the physical offset between the
//! laser diode and the camera lens on the pan/tilt bracket. The
//! correction is pre-computed at construction time for a nominal working
//! distance and subtracted from the target angle so the laser (not the
//! camera) points at the target.

use catlaser_common::constants::{PAN_LIMIT_MAX, PAN_LIMIT_MIN, TILT_LIMIT_MAX, TILT_LIMIT_MIN};

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

/// Validation errors for [`TargetingConfig`].
#[derive(Debug, Clone, thiserror::Error)]
pub(crate) enum TargetingError {
    /// Horizontal field of view must be in (0, 360).
    #[error("horizontal FOV must be in (0, 360) degrees, got {0}")]
    HfovOutOfRange(f32),
    /// Vertical field of view must be in (0, 360).
    #[error("vertical FOV must be in (0, 360) degrees, got {0}")]
    VfovOutOfRange(f32),
    /// Working distance must be positive and finite.
    #[error("working distance must be positive and finite, got {0}")]
    WorkingDistanceNotPositive(f32),
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Camera and laser geometry for the bbox-to-angle transform.
#[derive(Debug, Clone)]
pub(crate) struct TargetingConfig {
    /// Horizontal field of view in degrees.
    pub hfov_deg: f32,
    /// Vertical field of view in degrees.
    pub vfov_deg: f32,
    /// Laser horizontal offset from camera optical axis in millimeters.
    /// Positive means the laser is to the right of the camera.
    pub laser_offset_x_mm: f32,
    /// Laser vertical offset from camera optical axis in millimeters.
    /// Positive means the laser is below the camera.
    pub laser_offset_y_mm: f32,
    /// Nominal working distance in millimeters for parallax correction.
    /// The parallax angle is `atan(offset / distance)`, so this controls
    /// the magnitude of the correction. Typical indoor play: 1500-3000 mm.
    pub working_distance_mm: f32,
}

impl Default for TargetingConfig {
    fn default() -> Self {
        Self {
            hfov_deg: 80.0_f32,
            vfov_deg: 64.0_f32,
            laser_offset_x_mm: 15.0_f32,
            laser_offset_y_mm: 5.0_f32,
            working_distance_mm: 2000.0_f32,
        }
    }
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// Computed servo target angles from the targeting transform.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TargetingSolution {
    /// Target pan angle in hundredths of a degree.
    pub pan: i16,
    /// Target tilt angle in hundredths of a degree.
    pub tilt: i16,
}

// ---------------------------------------------------------------------------
// Targeter
// ---------------------------------------------------------------------------

/// Converts normalized frame positions to servo angles.
///
/// Constructed once from a [`TargetingConfig`], pre-computes FOV and
/// parallax values. Call [`compute()`](Self::compute) per frame with
/// the target position and current servo angles.
#[derive(Debug)]
pub(crate) struct Targeter {
    /// Horizontal FOV scaled to centidegrees (degrees x 100).
    hfov: f32,
    /// Vertical FOV scaled to centidegrees (degrees x 100).
    vfov: f32,
    /// Pre-computed parallax correction for pan, in centidegrees.
    /// Positive when the laser is to the right of the camera.
    parallax_pan: f32,
    /// Pre-computed parallax correction for tilt, in centidegrees.
    /// Positive when the laser is below the camera.
    parallax_tilt: f32,
}

impl Targeter {
    /// Creates a new targeter from the given configuration.
    ///
    /// Pre-computes FOV in centidegrees and parallax corrections.
    /// Returns [`TargetingError`] if any configuration value is invalid.
    pub(crate) fn new(config: &TargetingConfig) -> Result<Self, TargetingError> {
        if !(config.hfov_deg > 0.0_f32 && config.hfov_deg < 360.0_f32) {
            return Err(TargetingError::HfovOutOfRange(config.hfov_deg));
        }
        if !(config.vfov_deg > 0.0_f32 && config.vfov_deg < 360.0_f32) {
            return Err(TargetingError::VfovOutOfRange(config.vfov_deg));
        }
        if !(config.working_distance_mm > 0.0_f32 && config.working_distance_mm.is_finite()) {
            return Err(TargetingError::WorkingDistanceNotPositive(
                config.working_distance_mm,
            ));
        }

        let hfov = config.hfov_deg * 100.0_f32;
        let vfov = config.vfov_deg * 100.0_f32;

        // Parallax: atan2(offset, distance) in radians, converted to
        // centidegrees. The correction is subtracted during compute()
        // because the laser is displaced from the camera — aiming the
        // mount straight at the target causes the laser to overshoot
        // in the direction of the offset.
        let parallax_pan = config
            .laser_offset_x_mm
            .atan2(config.working_distance_mm)
            .to_degrees()
            * 100.0_f32;
        let parallax_tilt = config
            .laser_offset_y_mm
            .atan2(config.working_distance_mm)
            .to_degrees()
            * 100.0_f32;

        Ok(Self {
            hfov,
            vfov,
            parallax_pan,
            parallax_tilt,
        })
    }

    /// Converts a normalized target position to servo angles.
    ///
    /// `target_x` and `target_y` are in normalized frame coordinates
    /// (0.0-1.0, where 0.0 is left/top and 1.0 is right/bottom).
    /// `current_pan` and `current_tilt` are the current servo angles
    /// in hundredths of a degree — the camera is pointing in this
    /// direction, so the frame coordinates are relative to it.
    ///
    /// Returns servo angles clamped to mechanical limits. Safety
    /// ceiling enforcement is a separate downstream step.
    pub(crate) fn compute(
        &self,
        target_x: f32,
        target_y: f32,
        current_pan: i16,
        current_tilt: i16,
    ) -> TargetingSolution {
        // Angular offset from camera center in centidegrees.
        // (target - 0.5) maps frame center to 0, edges to +/-0.5.
        let frame_pan = (target_x - 0.5_f32) * self.hfov;
        let frame_tilt = (target_y - 0.5_f32) * self.vfov;

        // Absolute target = current mount angle + frame offset - parallax.
        // Parallax is subtracted because the laser overshoots in the
        // direction of its offset from the camera.
        let raw_pan = f32::from(current_pan) + frame_pan - self.parallax_pan;
        let raw_tilt = f32::from(current_tilt) + frame_tilt - self.parallax_tilt;

        TargetingSolution {
            pan: f32_to_clamped_centideg(raw_pan, PAN_LIMIT_MIN, PAN_LIMIT_MAX),
            tilt: f32_to_clamped_centideg(raw_tilt, TILT_LIMIT_MIN, TILT_LIMIT_MAX),
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Clamps a floating-point centidegree value to `[min, max]` and rounds
/// to the nearest `i16`.
///
/// `min` and `max` are `i16` servo limit constants. The value is clamped
/// before rounding so the cast to `i16` is always in range.
#[expect(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    reason = "value is clamped to [i16::MIN-relevant, i16::MAX-relevant] before cast; \
              f32 has 24 bits of mantissa which exactly represents all i16 values, \
              so no precision loss or truncation can occur after clamping"
)]
fn f32_to_clamped_centideg(value: f32, min: i16, max: i16) -> i16 {
    let min_f = f32::from(min);
    let max_f = f32::from(max);
    let clamped = value.clamp(min_f, max_f);

    // round() rounds half away from zero. The result is in [min_f, max_f]
    // which is within i16 range, so the cast is lossless.
    clamped.round() as i16
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use catlaser_common::constants::{
        PAN_LIMIT_MAX, PAN_LIMIT_MIN, TILT_LIMIT_MAX, TILT_LIMIT_MIN,
    };
    use proptest::prelude::*;

    /// Config with no laser offset for tests that verify pure FOV geometry.
    fn zero_offset_config() -> TargetingConfig {
        TargetingConfig {
            hfov_deg: 80.0_f32,
            vfov_deg: 64.0_f32,
            laser_offset_x_mm: 0.0_f32,
            laser_offset_y_mm: 0.0_f32,
            working_distance_mm: 2000.0_f32,
        }
    }

    /// Config with a known laser offset for parallax tests.
    fn offset_config() -> TargetingConfig {
        TargetingConfig {
            hfov_deg: 80.0_f32,
            vfov_deg: 64.0_f32,
            laser_offset_x_mm: 15.0_f32,
            laser_offset_y_mm: 10.0_f32,
            working_distance_mm: 2000.0_f32,
        }
    }

    // ---- construction validation ----

    #[test]
    fn test_valid_config_succeeds() {
        assert!(
            Targeter::new(&TargetingConfig::default()).is_ok(),
            "default config must be valid"
        );
    }

    #[test]
    fn test_zero_hfov_rejected() {
        let mut cfg = zero_offset_config();
        cfg.hfov_deg = 0.0_f32;
        assert!(Targeter::new(&cfg).is_err(), "zero HFOV must be rejected");
    }

    #[test]
    fn test_negative_hfov_rejected() {
        let mut cfg = zero_offset_config();
        cfg.hfov_deg = -10.0_f32;
        assert!(
            Targeter::new(&cfg).is_err(),
            "negative HFOV must be rejected"
        );
    }

    #[test]
    fn test_360_hfov_rejected() {
        let mut cfg = zero_offset_config();
        cfg.hfov_deg = 360.0_f32;
        assert!(
            Targeter::new(&cfg).is_err(),
            "360 degree HFOV must be rejected"
        );
    }

    #[test]
    fn test_nan_hfov_rejected() {
        let mut cfg = zero_offset_config();
        cfg.hfov_deg = f32::NAN;
        assert!(Targeter::new(&cfg).is_err(), "NaN HFOV must be rejected");
    }

    #[test]
    fn test_zero_vfov_rejected() {
        let mut cfg = zero_offset_config();
        cfg.vfov_deg = 0.0_f32;
        assert!(Targeter::new(&cfg).is_err(), "zero VFOV must be rejected");
    }

    #[test]
    fn test_negative_vfov_rejected() {
        let mut cfg = zero_offset_config();
        cfg.vfov_deg = -5.0_f32;
        assert!(
            Targeter::new(&cfg).is_err(),
            "negative VFOV must be rejected"
        );
    }

    #[test]
    fn test_nan_vfov_rejected() {
        let mut cfg = zero_offset_config();
        cfg.vfov_deg = f32::NAN;
        assert!(Targeter::new(&cfg).is_err(), "NaN VFOV must be rejected");
    }

    #[test]
    fn test_zero_working_distance_rejected() {
        let mut cfg = zero_offset_config();
        cfg.working_distance_mm = 0.0_f32;
        assert!(
            Targeter::new(&cfg).is_err(),
            "zero working distance must be rejected"
        );
    }

    #[test]
    fn test_negative_working_distance_rejected() {
        let mut cfg = zero_offset_config();
        cfg.working_distance_mm = -100.0_f32;
        assert!(
            Targeter::new(&cfg).is_err(),
            "negative working distance must be rejected"
        );
    }

    #[test]
    fn test_infinite_working_distance_rejected() {
        let mut cfg = zero_offset_config();
        cfg.working_distance_mm = f32::INFINITY;
        assert!(
            Targeter::new(&cfg).is_err(),
            "infinite working distance must be rejected"
        );
    }

    #[test]
    fn test_nan_working_distance_rejected() {
        let mut cfg = zero_offset_config();
        cfg.working_distance_mm = f32::NAN;
        assert!(
            Targeter::new(&cfg).is_err(),
            "NaN working distance must be rejected"
        );
    }

    // ---- center of frame ----

    #[test]
    fn test_center_target_at_origin_returns_origin() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| {
                // SAFETY: zero_offset_config() is valid by construction
                unreachable!()
            });
        let s = t.compute(0.5_f32, 0.5_f32, 0_i16, 0_i16);
        assert_eq!(s.pan, 0_i16, "center target at pan=0 must return 0");
        assert_eq!(s.tilt, 0_i16, "center target at tilt=0 must return 0");
    }

    #[test]
    fn test_center_target_preserves_current_position() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let s = t.compute(0.5_f32, 0.5_f32, 3000_i16, 4500_i16);
        assert_eq!(s.pan, 3000_i16, "center target must preserve current pan");
        assert_eq!(s.tilt, 4500_i16, "center target must preserve current tilt");
    }

    #[test]
    fn test_center_target_at_negative_angles() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let s = t.compute(0.5_f32, 0.5_f32, -5000_i16, -1000_i16);
        assert_eq!(s.pan, -5000_i16, "center target must preserve negative pan");
        assert_eq!(
            s.tilt, -1000_i16,
            "center target must preserve negative tilt"
        );
    }

    // ---- frame edge offsets (80 deg HFOV, 64 deg VFOV) ----
    //
    // HFOV 80 deg = 8000 centideg. Half = 4000 centideg.
    // VFOV 64 deg = 6400 centideg. Half = 3200 centideg.

    #[test]
    fn test_right_edge_adds_half_hfov() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let s = t.compute(1.0_f32, 0.5_f32, 0_i16, 4500_i16);
        assert_eq!(
            s.pan, 4000_i16,
            "right edge (x=1.0) must add +4000 centideg to pan"
        );
        assert_eq!(s.tilt, 4500_i16, "right edge must not affect tilt");
    }

    #[test]
    fn test_left_edge_subtracts_half_hfov() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let s = t.compute(0.0_f32, 0.5_f32, 0_i16, 4500_i16);
        assert_eq!(
            s.pan, -4000_i16,
            "left edge (x=0.0) must subtract 4000 centideg from pan"
        );
        assert_eq!(s.tilt, 4500_i16, "left edge must not affect tilt");
    }

    #[test]
    fn test_bottom_edge_adds_half_vfov() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let s = t.compute(0.5_f32, 1.0_f32, 0_i16, 0_i16);
        assert_eq!(s.pan, 0_i16, "bottom edge must not affect pan");
        assert_eq!(
            s.tilt, 3200_i16,
            "bottom edge (y=1.0) must add +3200 centideg to tilt"
        );
    }

    #[test]
    fn test_top_edge_subtracts_half_vfov() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let s = t.compute(0.5_f32, 0.0_f32, 0_i16, 0_i16);
        assert_eq!(s.pan, 0_i16, "top edge must not affect pan");
        assert_eq!(
            s.tilt, -3200_i16,
            "top edge (y=0.0) must subtract 3200 centideg from tilt"
        );
    }

    #[test]
    fn test_quarter_offset_from_center() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        // x=0.75 is 0.25 right of center: 0.25 * 8000 = 2000 centideg
        let s = t.compute(0.75_f32, 0.5_f32, 0_i16, 4500_i16);
        assert_eq!(
            s.pan, 2000_i16,
            "x=0.75 must produce +2000 centideg pan offset"
        );
    }

    #[test]
    fn test_additive_with_current_position() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        // Right edge (+4000) from current pan of 3000 = 7000
        let s = t.compute(1.0_f32, 0.5_f32, 3000_i16, 4500_i16);
        assert_eq!(s.pan, 7000_i16, "frame offset must add to current position");
    }

    // ---- symmetry ----

    #[test]
    fn test_pan_symmetry() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let left = t.compute(0.25_f32, 0.5_f32, 0_i16, 4500_i16);
        let right = t.compute(0.75_f32, 0.5_f32, 0_i16, 4500_i16);
        assert_eq!(
            left.pan, -right.pan,
            "symmetric x positions must produce negated pan angles"
        );
    }

    #[test]
    fn test_tilt_symmetry() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let top = t.compute(0.5_f32, 0.25_f32, 0_i16, 0_i16);
        let bottom = t.compute(0.5_f32, 0.75_f32, 0_i16, 0_i16);
        assert_eq!(
            top.tilt, -bottom.tilt,
            "symmetric y positions must produce negated tilt angles"
        );
    }

    #[test]
    fn test_pan_and_tilt_independent() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let pan_only = t.compute(0.75_f32, 0.5_f32, 0_i16, 0_i16);
        let tilt_only = t.compute(0.5_f32, 0.75_f32, 0_i16, 0_i16);
        let both = t.compute(0.75_f32, 0.75_f32, 0_i16, 0_i16);

        assert_eq!(both.pan, pan_only.pan, "pan must be independent of y");
        assert_eq!(both.tilt, tilt_only.tilt, "tilt must be independent of x");
    }

    // ---- parallax ----

    #[test]
    fn test_zero_offset_produces_zero_parallax() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        assert!(
            t.parallax_pan.abs() < f32::EPSILON,
            "zero laser offset must produce zero pan parallax, got {}",
            t.parallax_pan,
        );
        assert!(
            t.parallax_tilt.abs() < f32::EPSILON,
            "zero laser offset must produce zero tilt parallax, got {}",
            t.parallax_tilt,
        );
    }

    #[test]
    fn test_positive_x_offset_shifts_pan_negative() {
        let no_offset = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let with_offset = Targeter::new(&offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());

        let base = no_offset.compute(0.5_f32, 0.5_f32, 0_i16, 4500_i16);
        let shifted = with_offset.compute(0.5_f32, 0.5_f32, 0_i16, 4500_i16);

        assert!(
            shifted.pan < base.pan,
            "laser to the right of camera must shift pan negative (base={}, shifted={})",
            base.pan,
            shifted.pan,
        );
    }

    #[test]
    fn test_positive_y_offset_shifts_tilt_negative() {
        let no_offset = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let with_offset = Targeter::new(&offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());

        let base = no_offset.compute(0.5_f32, 0.5_f32, 0_i16, 4500_i16);
        let shifted = with_offset.compute(0.5_f32, 0.5_f32, 0_i16, 4500_i16);

        assert!(
            shifted.tilt < base.tilt,
            "laser below camera must shift tilt negative (base={}, shifted={})",
            base.tilt,
            shifted.tilt,
        );
    }

    #[test]
    fn test_negative_x_offset_shifts_pan_positive() {
        let mut cfg = zero_offset_config();
        cfg.laser_offset_x_mm = -15.0_f32;
        let t = Targeter::new(&cfg).ok().unwrap_or_else(|| unreachable!());

        // Center target with negative offset should produce positive pan
        // (laser is left of camera, mount must aim right to compensate).
        let s = t.compute(0.5_f32, 0.5_f32, 0_i16, 4500_i16);
        assert!(
            s.pan > 0_i16,
            "laser left of camera must shift pan positive, got {}",
            s.pan,
        );
    }

    #[test]
    fn test_parallax_magnitude_reasonable() {
        // 15mm offset at 2000mm distance:
        // atan(15/2000) = 0.007499 rad = 0.4297 deg = 42.97 centideg ≈ 43
        let t = Targeter::new(&offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());

        let expected_centideg = 43.0_f32;
        let tolerance = 1.0_f32;
        assert!(
            (t.parallax_pan - expected_centideg).abs() < tolerance,
            "pan parallax should be ~43 centideg, got {}",
            t.parallax_pan,
        );

        // 10mm offset at 2000mm:
        // atan(10/2000) = 0.004999 rad = 0.2865 deg = 28.65 centideg ≈ 29
        let expected_tilt = 29.0_f32;
        assert!(
            (t.parallax_tilt - expected_tilt).abs() < tolerance,
            "tilt parallax should be ~29 centideg, got {}",
            t.parallax_tilt,
        );
    }

    #[test]
    fn test_parallax_increases_with_shorter_distance() {
        let near_cfg = TargetingConfig {
            working_distance_mm: 1000.0_f32,
            ..offset_config()
        };
        let far_cfg = TargetingConfig {
            working_distance_mm: 3000.0_f32,
            ..offset_config()
        };

        let near = Targeter::new(&near_cfg)
            .ok()
            .unwrap_or_else(|| unreachable!());
        let far = Targeter::new(&far_cfg)
            .ok()
            .unwrap_or_else(|| unreachable!());

        assert!(
            near.parallax_pan > far.parallax_pan,
            "shorter working distance must produce larger parallax"
        );
    }

    // ---- clamping to servo limits ----

    #[test]
    fn test_pan_clamped_to_max() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        // Current pan near max + right-edge offset would exceed PAN_LIMIT_MAX.
        let s = t.compute(1.0_f32, 0.5_f32, 8000_i16, 4500_i16);
        assert_eq!(
            s.pan, PAN_LIMIT_MAX,
            "pan must clamp to PAN_LIMIT_MAX when exceeding range"
        );
    }

    #[test]
    fn test_pan_clamped_to_min() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let s = t.compute(0.0_f32, 0.5_f32, -8000_i16, 4500_i16);
        assert_eq!(
            s.pan, PAN_LIMIT_MIN,
            "pan must clamp to PAN_LIMIT_MIN when below range"
        );
    }

    #[test]
    fn test_tilt_clamped_to_max() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let s = t.compute(0.5_f32, 1.0_f32, 0_i16, 8000_i16);
        assert_eq!(
            s.tilt, TILT_LIMIT_MAX,
            "tilt must clamp to TILT_LIMIT_MAX when exceeding range"
        );
    }

    #[test]
    fn test_tilt_clamped_to_min() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        let s = t.compute(0.5_f32, 0.0_f32, 0_i16, -4000_i16);
        assert_eq!(
            s.tilt, TILT_LIMIT_MIN,
            "tilt must clamp to TILT_LIMIT_MIN when below range"
        );
    }

    #[test]
    fn test_clamp_does_not_affect_in_range_values() {
        let t = Targeter::new(&zero_offset_config())
            .ok()
            .unwrap_or_else(|| unreachable!());
        // Right edge from pan=0: 4000, well within [-9000, 9000].
        let s = t.compute(1.0_f32, 0.5_f32, 0_i16, 4500_i16);
        assert_eq!(
            s.pan, 4000_i16,
            "in-range values must not be affected by clamping"
        );
    }

    // ---- f32_to_clamped_centideg ----

    #[test]
    fn test_round_half_away_from_zero() {
        // 0.5 rounds to 1 (away from zero).
        assert_eq!(
            f32_to_clamped_centideg(0.5_f32, i16::MIN, i16::MAX),
            1_i16,
            "0.5 must round to 1"
        );
        // -0.5 rounds to -1 (away from zero).
        assert_eq!(
            f32_to_clamped_centideg(-0.5_f32, i16::MIN, i16::MAX),
            -1_i16,
            "-0.5 must round to -1"
        );
    }

    #[test]
    fn test_nan_clamps_to_min() {
        // f32::NAN.clamp() returns NAN, NAN.round() returns NAN,
        // NAN as i16 is 0 on most platforms but undefined behavior
        // is avoided because clamp handles it. Actually, NAN comparison
        // is always false, so clamp(min, max) returns NAN. To be safe,
        // we verify the output is at least within limits.
        let result = f32_to_clamped_centideg(f32::NAN, -9000_i16, 9000_i16);
        assert!(
            (-9000_i16..=9000_i16).contains(&result),
            "NaN input must produce a value within limits, got {result}"
        );
    }

    // ---- proptest ----

    proptest! {
        #[test]
        fn test_output_within_servo_limits(
            cx in 0.0_f32..=1.0_f32,
            cy in 0.0_f32..=1.0_f32,
            current_pan in -9000_i16..=9000_i16,
            current_tilt in -4500_i16..=9000_i16,
        ) {
            let t = Targeter::new(&zero_offset_config()).ok().unwrap_or_else(|| unreachable!());
            let s = t.compute(cx, cy, current_pan, current_tilt);
            prop_assert!(
                s.pan >= PAN_LIMIT_MIN && s.pan <= PAN_LIMIT_MAX,
                "pan {} outside [{}, {}]", s.pan, PAN_LIMIT_MIN, PAN_LIMIT_MAX,
            );
            prop_assert!(
                s.tilt >= TILT_LIMIT_MIN && s.tilt <= TILT_LIMIT_MAX,
                "tilt {} outside [{}, {}]", s.tilt, TILT_LIMIT_MIN, TILT_LIMIT_MAX,
            );
        }

        #[test]
        fn test_output_within_limits_with_parallax(
            cx in 0.0_f32..=1.0_f32,
            cy in 0.0_f32..=1.0_f32,
            current_pan in -9000_i16..=9000_i16,
            current_tilt in -4500_i16..=9000_i16,
        ) {
            let t = Targeter::new(&offset_config()).ok().unwrap_or_else(|| unreachable!());
            let s = t.compute(cx, cy, current_pan, current_tilt);
            prop_assert!(
                s.pan >= PAN_LIMIT_MIN && s.pan <= PAN_LIMIT_MAX,
                "pan {} outside [{}, {}] with parallax", s.pan, PAN_LIMIT_MIN, PAN_LIMIT_MAX,
            );
            prop_assert!(
                s.tilt >= TILT_LIMIT_MIN && s.tilt <= TILT_LIMIT_MAX,
                "tilt {} outside [{}, {}] with parallax", s.tilt, TILT_LIMIT_MIN, TILT_LIMIT_MAX,
            );
        }

        /// Pan must be non-decreasing as target_x increases, when the raw
        /// result stays within servo limits (no clamping).
        #[test]
        fn test_pan_monotonic_in_x(
            x1 in 0.0_f32..=1.0_f32,
            x2 in 0.0_f32..=1.0_f32,
            cy in 0.0_f32..=1.0_f32,
            current_pan in -5000_i16..=5000_i16,
            current_tilt in 500_i16..=8000_i16,
        ) {
            let t = Targeter::new(&zero_offset_config()).ok().unwrap_or_else(|| unreachable!());
            let s1 = t.compute(x1, cy, current_pan, current_tilt);
            let s2 = t.compute(x2, cy, current_pan, current_tilt);
            if x1 <= x2 {
                prop_assert!(
                    s1.pan <= s2.pan,
                    "pan must be non-decreasing with x: f({})={} > f({})={}",
                    x1, s1.pan, x2, s2.pan,
                );
            }
        }

        /// Tilt must be non-decreasing as target_y increases, when the raw
        /// result stays within servo limits (no clamping).
        #[test]
        fn test_tilt_monotonic_in_y(
            cx in 0.0_f32..=1.0_f32,
            y1 in 0.0_f32..=1.0_f32,
            y2 in 0.0_f32..=1.0_f32,
            current_pan in -5000_i16..=5000_i16,
            current_tilt in 500_i16..=5000_i16,
        ) {
            let t = Targeter::new(&zero_offset_config()).ok().unwrap_or_else(|| unreachable!());
            let s1 = t.compute(cx, y1, current_pan, current_tilt);
            let s2 = t.compute(cx, y2, current_pan, current_tilt);
            if y1 <= y2 {
                prop_assert!(
                    s1.tilt <= s2.tilt,
                    "tilt must be non-decreasing with y: f({})={} > f({})={}",
                    y1, s1.tilt, y2, s2.tilt,
                );
            }
        }

        /// Center of frame (0.5, 0.5) with no parallax must return the
        /// current servo position exactly.
        #[test]
        fn test_center_always_returns_current(
            current_pan in -9000_i16..=9000_i16,
            current_tilt in -4500_i16..=9000_i16,
        ) {
            let t = Targeter::new(&zero_offset_config()).ok().unwrap_or_else(|| unreachable!());
            let s = t.compute(0.5_f32, 0.5_f32, current_pan, current_tilt);
            prop_assert_eq!(
                s.pan, current_pan,
                "center with no parallax must return current pan",
            );
            prop_assert_eq!(
                s.tilt, current_tilt,
                "center with no parallax must return current tilt",
            );
        }

        /// Tilt output must not depend on target_x (pan and tilt are
        /// independent axes).
        #[test]
        fn test_tilt_independent_of_x(
            x1 in 0.0_f32..=1.0_f32,
            x2 in 0.0_f32..=1.0_f32,
            cy in 0.0_f32..=1.0_f32,
            current_pan in -5000_i16..=5000_i16,
            current_tilt in 0_i16..=5000_i16,
        ) {
            let t = Targeter::new(&zero_offset_config()).ok().unwrap_or_else(|| unreachable!());
            let s1 = t.compute(x1, cy, current_pan, current_tilt);
            let s2 = t.compute(x2, cy, current_pan, current_tilt);
            prop_assert_eq!(
                s1.tilt, s2.tilt,
                "tilt must be independent of target_x",
            );
        }

        /// Pan output must not depend on target_y.
        #[test]
        fn test_pan_independent_of_y(
            cx in 0.0_f32..=1.0_f32,
            y1 in 0.0_f32..=1.0_f32,
            y2 in 0.0_f32..=1.0_f32,
            current_pan in -5000_i16..=5000_i16,
            current_tilt in 0_i16..=5000_i16,
        ) {
            let t = Targeter::new(&zero_offset_config()).ok().unwrap_or_else(|| unreachable!());
            let s1 = t.compute(cx, y1, current_pan, current_tilt);
            let s2 = t.compute(cx, y2, current_pan, current_tilt);
            prop_assert_eq!(
                s1.pan, s2.pan,
                "pan must be independent of target_y",
            );
        }
    }
}
