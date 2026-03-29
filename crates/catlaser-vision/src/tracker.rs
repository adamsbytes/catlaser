//! SORT tracker: Kalman filter + Hungarian matching for frame-to-frame cat
//! tracking.
//!
//! Maintains persistent track objects across frames. Each detection from
//! [`Detector::detect()`](crate::detect::Detector::detect) is matched to an
//! existing track or spawns a new one. Tracks follow a lifecycle:
//!
//! `Tentative` (new) → `Confirmed` (3+ hits) → `Coasting` (no match,
//! Kalman predicts) → removed (30 frames unmatched).
//!
//! The tracker outputs normalized coordinates (0.0–1.0) ready for IPC to
//! the Python behavior engine.

use crate::detect::{BoundingBox, Detection};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// SORT tracker configuration.
#[derive(Debug, Clone)]
pub(crate) struct TrackerConfig {
    /// Consecutive hits required to promote a tentative track to confirmed.
    pub min_hits_to_confirm: u32,
    /// Frames without a match before a track is removed.
    pub max_coast_frames: u32,
    /// Minimum `IoU` for a detection to match an existing track.
    pub iou_threshold: f32,
}

impl Default for TrackerConfig {
    fn default() -> Self {
        Self {
            min_hits_to_confirm: 3_u32,
            max_coast_frames: 30_u32,
            iou_threshold: 0.3_f32,
        }
    }
}

// ---------------------------------------------------------------------------
// Track state
// ---------------------------------------------------------------------------

/// Lifecycle state of a track.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TrackState {
    /// Newly created, not yet confirmed. Fewer than `min_hits_to_confirm`
    /// consecutive matches.
    Tentative,
    /// Actively matched for `min_hits_to_confirm` or more consecutive frames.
    Confirmed,
    /// Lost match — Kalman predicts forward while waiting for re-acquisition.
    Coasting,
}

// ---------------------------------------------------------------------------
// Kalman filter (8-state constant-velocity model)
// ---------------------------------------------------------------------------

/// State vector dimension: [x, y, w, h, dx, dy, dw, dh].
const STATE_DIM: usize = 8;

/// Measurement vector dimension: [x, y, w, h].
const MEAS_DIM: usize = 4;

/// 8x8 matrix stored in row-major order.
#[derive(Debug, Clone, Copy)]
struct Mat8x8([f32; 64]);

/// 8x4 matrix stored in row-major order.
#[derive(Debug, Clone, Copy)]
struct Mat8x4([f32; 32]);

/// 4x8 matrix stored in row-major order.
#[derive(Debug, Clone, Copy)]
struct Mat4x8([f32; 32]);

/// 4x4 matrix stored in row-major order.
#[derive(Debug, Clone, Copy)]
struct Mat4x4([f32; 16]);

/// 8-element state vector.
#[derive(Debug, Clone, Copy)]
struct Vec8([f32; STATE_DIM]);

/// 4-element measurement/residual vector.
#[derive(Debug, Clone, Copy)]
struct Vec4([f32; MEAS_DIM]);

impl Mat8x8 {
    /// 8x8 identity matrix.
    fn identity() -> Self {
        let mut m = [0.0_f32; 64];
        let mut i = 0_usize;
        while i < STATE_DIM {
            // i * 8 + i: diagonal indices are 0, 9, 18, 27, 36, 45, 54, 63.
            // All fit in 64-element array.
            if let Some(slot) = m.get_mut(i.wrapping_mul(STATE_DIM).wrapping_add(i)) {
                *slot = 1.0_f32;
            }
            i = i.wrapping_add(1);
        }
        Self(m)
    }

    /// 8x8 zero matrix.
    const fn zero() -> Self {
        Self([0.0_f32; 64])
    }

    /// Returns a diagonal matrix with the given diagonal values.
    fn diagonal(diag: &[f32; STATE_DIM]) -> Self {
        let mut m = Self::zero();
        for (i, &val) in diag.iter().enumerate() {
            if let Some(slot) = m.0.get_mut(i.wrapping_mul(STATE_DIM).wrapping_add(i)) {
                *slot = val;
            }
        }
        m
    }

    /// Gets element at (row, col).
    fn get(&self, row: usize, col: usize) -> f32 {
        self.0
            .get(row.wrapping_mul(STATE_DIM).wrapping_add(col))
            .copied()
            .unwrap_or(0.0_f32)
    }

    /// Sets element at (row, col).
    fn set(&mut self, row: usize, col: usize, val: f32) {
        if let Some(slot) = self
            .0
            .get_mut(row.wrapping_mul(STATE_DIM).wrapping_add(col))
        {
            *slot = val;
        }
    }

    /// Matrix-vector multiply: 8x8 * 8x1 → 8x1.
    fn mul_vec(&self, v: &Vec8) -> Vec8 {
        let mut out = [0.0_f32; STATE_DIM];
        for (r, out_slot) in out.iter_mut().enumerate() {
            let mut sum = 0.0_f32;
            for c in 0..STATE_DIM {
                sum += self.get(r, c) * v.0.get(c).copied().unwrap_or(0.0_f32);
            }
            *out_slot = sum;
        }
        Vec8(out)
    }

    /// Matrix multiply: 8x8 * 8x8 → 8x8.
    fn mul_8x8(&self, other: &Self) -> Self {
        let mut out = [0.0_f32; 64];
        for r in 0..STATE_DIM {
            for c in 0..STATE_DIM {
                let mut sum = 0.0_f32;
                for k in 0..STATE_DIM {
                    sum += self.get(r, k) * other.get(k, c);
                }
                if let Some(slot) = out.get_mut(r.wrapping_mul(STATE_DIM).wrapping_add(c)) {
                    *slot = sum;
                }
            }
        }
        Self(out)
    }

    /// Matrix multiply: 8x8 * 8x4 → 8x4.
    fn mul_8x4(&self, other: &Mat8x4) -> Mat8x4 {
        let mut out = [0.0_f32; 32];
        for r in 0..STATE_DIM {
            for c in 0..MEAS_DIM {
                let mut sum = 0.0_f32;
                for k in 0..STATE_DIM {
                    sum += self.get(r, k) * other.get(k, c);
                }
                if let Some(slot) = out.get_mut(r.wrapping_mul(MEAS_DIM).wrapping_add(c)) {
                    *slot = sum;
                }
            }
        }
        Mat8x4(out)
    }

    /// Transpose: 8x8 → 8x8.
    fn transpose(&self) -> Self {
        let mut out = Self::zero();
        for r in 0..STATE_DIM {
            for c in 0..STATE_DIM {
                out.set(c, r, self.get(r, c));
            }
        }
        out
    }

    /// Element-wise addition.
    fn add(&self, other: &Self) -> Self {
        let mut out = [0.0_f32; 64];
        for (i, slot) in out.iter_mut().enumerate() {
            *slot = self.0.get(i).copied().unwrap_or(0.0_f32)
                + other.0.get(i).copied().unwrap_or(0.0_f32);
        }
        Self(out)
    }

    /// Element-wise subtraction.
    fn sub(&self, other: &Self) -> Self {
        let mut out = [0.0_f32; 64];
        for (i, slot) in out.iter_mut().enumerate() {
            *slot = self.0.get(i).copied().unwrap_or(0.0_f32)
                - other.0.get(i).copied().unwrap_or(0.0_f32);
        }
        Self(out)
    }
}

impl Mat8x4 {
    fn get(&self, row: usize, col: usize) -> f32 {
        self.0
            .get(row.wrapping_mul(MEAS_DIM).wrapping_add(col))
            .copied()
            .unwrap_or(0.0_f32)
    }

    /// Multiply 8x4 * 4x1 → 8x1.
    fn mul_vec(&self, v: &Vec4) -> Vec8 {
        let mut out = [0.0_f32; STATE_DIM];
        for (r, out_slot) in out.iter_mut().enumerate() {
            let mut sum = 0.0_f32;
            for c in 0..MEAS_DIM {
                sum += self.get(r, c) * v.0.get(c).copied().unwrap_or(0.0_f32);
            }
            *out_slot = sum;
        }
        Vec8(out)
    }

    /// Multiply 8x4 * 4x4 → 8x4.
    fn mul_4x4(&self, other: &Mat4x4) -> Self {
        let mut out = [0.0_f32; 32];
        for r in 0..STATE_DIM {
            for c in 0..MEAS_DIM {
                let mut sum = 0.0_f32;
                for k in 0..MEAS_DIM {
                    sum += self.get(r, k) * other.get(k, c);
                }
                if let Some(slot) = out.get_mut(r.wrapping_mul(MEAS_DIM).wrapping_add(c)) {
                    *slot = sum;
                }
            }
        }
        Self(out)
    }

    /// Multiply 8x4 * 4x8 → 8x8.
    fn mul_4x8(&self, other: &Mat4x8) -> Mat8x8 {
        let mut out = [0.0_f32; 64];
        for r in 0..STATE_DIM {
            for c in 0..STATE_DIM {
                let mut sum = 0.0_f32;
                for k in 0..MEAS_DIM {
                    sum += self.get(r, k) * other.get(k, c);
                }
                if let Some(slot) = out.get_mut(r.wrapping_mul(STATE_DIM).wrapping_add(c)) {
                    *slot = sum;
                }
            }
        }
        Mat8x8(out)
    }

    /// Transpose: 8x4 → 4x8.
    fn transpose(&self) -> Mat4x8 {
        let mut out = [0.0_f32; 32];
        for r in 0..STATE_DIM {
            for c in 0..MEAS_DIM {
                if let Some(slot) = out.get_mut(c.wrapping_mul(STATE_DIM).wrapping_add(r)) {
                    *slot = self.get(r, c);
                }
            }
        }
        Mat4x8(out)
    }
}

impl Mat4x8 {
    fn get(&self, row: usize, col: usize) -> f32 {
        self.0
            .get(row.wrapping_mul(STATE_DIM).wrapping_add(col))
            .copied()
            .unwrap_or(0.0_f32)
    }

    /// Multiply 4x8 * 8x1 → 4x1.
    fn mul_vec(&self, v: &Vec8) -> Vec4 {
        let mut out = [0.0_f32; MEAS_DIM];
        for (r, out_slot) in out.iter_mut().enumerate() {
            let mut sum = 0.0_f32;
            for c in 0..STATE_DIM {
                sum += self.get(r, c) * v.0.get(c).copied().unwrap_or(0.0_f32);
            }
            *out_slot = sum;
        }
        Vec4(out)
    }

    /// Multiply 4x8 * 8x8 → 4x8.
    fn mul_8x8(&self, other: &Mat8x8) -> Self {
        let mut out = [0.0_f32; 32];
        for r in 0..MEAS_DIM {
            for c in 0..STATE_DIM {
                let mut sum = 0.0_f32;
                for k in 0..STATE_DIM {
                    sum += self.get(r, k) * other.get(k, c);
                }
                if let Some(slot) = out.get_mut(r.wrapping_mul(STATE_DIM).wrapping_add(c)) {
                    *slot = sum;
                }
            }
        }
        Self(out)
    }

    /// Transpose: 4x8 → 8x4.
    fn transpose(&self) -> Mat8x4 {
        let mut out = [0.0_f32; 32];
        for r in 0..MEAS_DIM {
            for c in 0..STATE_DIM {
                if let Some(slot) = out.get_mut(c.wrapping_mul(MEAS_DIM).wrapping_add(r)) {
                    *slot = self.get(r, c);
                }
            }
        }
        Mat8x4(out)
    }
}

impl Mat4x4 {
    fn get(&self, row: usize, col: usize) -> f32 {
        self.0
            .get(row.wrapping_mul(MEAS_DIM).wrapping_add(col))
            .copied()
            .unwrap_or(0.0_f32)
    }

    fn set(&mut self, row: usize, col: usize, val: f32) {
        if let Some(slot) = self.0.get_mut(row.wrapping_mul(MEAS_DIM).wrapping_add(col)) {
            *slot = val;
        }
    }

    /// Invert a 4x4 matrix via Gauss-Jordan elimination.
    ///
    /// Returns `None` if the matrix is singular (pivot magnitude below epsilon).
    fn invert(&self) -> Option<Self> {
        // Augmented matrix [A | I] stored as two 4x4 blocks.
        let mut a = *self;
        let mut inv = Self::identity();

        for col in 0..MEAS_DIM {
            // Partial pivoting: find row with largest absolute value in column.
            let mut max_val = a.get(col, col).abs();
            let mut max_row = col;
            for row in (col.wrapping_add(1))..MEAS_DIM {
                let val = a.get(row, col).abs();
                if val > max_val {
                    max_val = val;
                    max_row = row;
                }
            }

            if max_val < 1e-12_f32 {
                return None;
            }

            // Swap rows if needed.
            if max_row != col {
                for k in 0..MEAS_DIM {
                    let tmp_a = a.get(col, k);
                    a.set(col, k, a.get(max_row, k));
                    a.set(max_row, k, tmp_a);

                    let tmp_inv = inv.get(col, k);
                    inv.set(col, k, inv.get(max_row, k));
                    inv.set(max_row, k, tmp_inv);
                }
            }

            // Scale pivot row.
            let pivot = a.get(col, col);
            for k in 0..MEAS_DIM {
                a.set(col, k, a.get(col, k) / pivot);
                inv.set(col, k, inv.get(col, k) / pivot);
            }

            // Eliminate column in all other rows.
            for row in 0..MEAS_DIM {
                if row == col {
                    continue;
                }
                let factor = a.get(row, col);
                for k in 0..MEAS_DIM {
                    a.set(row, k, factor.mul_add(-a.get(col, k), a.get(row, k)));
                    inv.set(row, k, factor.mul_add(-inv.get(col, k), inv.get(row, k)));
                }
            }
        }

        Some(inv)
    }

    fn identity() -> Self {
        let mut m = [0.0_f32; 16];
        let mut i = 0_usize;
        while i < MEAS_DIM {
            if let Some(slot) = m.get_mut(i.wrapping_mul(MEAS_DIM).wrapping_add(i)) {
                *slot = 1.0_f32;
            }
            i = i.wrapping_add(1);
        }
        Self(m)
    }
}

impl Vec8 {
    /// Element-wise addition.
    fn add(&self, other: &Self) -> Self {
        let mut out = [0.0_f32; STATE_DIM];
        for (i, slot) in out.iter_mut().enumerate() {
            *slot = self.0.get(i).copied().unwrap_or(0.0_f32)
                + other.0.get(i).copied().unwrap_or(0.0_f32);
        }
        Self(out)
    }
}

impl Vec4 {
    /// Element-wise subtraction.
    fn sub(&self, other: &Self) -> Self {
        let mut out = [0.0_f32; MEAS_DIM];
        for (i, slot) in out.iter_mut().enumerate() {
            *slot = self.0.get(i).copied().unwrap_or(0.0_f32)
                - other.0.get(i).copied().unwrap_or(0.0_f32);
        }
        Self(out)
    }
}

// ---------------------------------------------------------------------------
// Kalman filter
// ---------------------------------------------------------------------------

/// Constant-velocity Kalman filter for bounding box tracking.
///
/// State: `[cx, cy, w, h, dcx, dcy, dw, dh]` — center position, dimensions,
/// and their per-frame velocities. Measurement: `[cx, cy, w, h]`.
#[derive(Debug, Clone)]
struct KalmanFilter {
    /// State estimate.
    x: Vec8,
    /// Error covariance.
    p: Mat8x8,
}

/// Process noise standard deviations, scaled by the measurement magnitude.
/// Tuned for ~15 FPS tracking of objects spanning 5-80% of frame dimensions.
///
/// Position noise proportional to bbox size (larger objects tolerate more
/// drift). Velocity noise higher to accommodate erratic cat movement.
const PROCESS_NOISE_POS_FACTOR: f32 = 0.05_f32;
const PROCESS_NOISE_VEL_FACTOR: f32 = 0.02_f32;

/// Measurement noise standard deviations, scaled by measurement magnitude.
const MEASUREMENT_NOISE_POS_FACTOR: f32 = 0.05_f32;
const MEASUREMENT_NOISE_SIZE_FACTOR: f32 = 0.1_f32;

/// State transition matrix F for constant-velocity model (dt=1 frame).
///
/// ```text
/// [1 0 0 0 1 0 0 0]   cx' = cx + dcx
/// [0 1 0 0 0 1 0 0]   cy' = cy + dcy
/// [0 0 1 0 0 0 1 0]   w'  = w  + dw
/// [0 0 0 1 0 0 0 1]   h'  = h  + dh
/// [0 0 0 0 1 0 0 0]   dcx' = dcx
/// [0 0 0 0 0 1 0 0]   dcy' = dcy
/// [0 0 0 0 0 0 1 0]   dw'  = dw
/// [0 0 0 0 0 0 0 1]   dh'  = dh
/// ```
fn transition_matrix() -> Mat8x8 {
    let mut f = Mat8x8::identity();
    // Upper-right 4x4 identity block: position += velocity.
    f.set(0, 4, 1.0_f32);
    f.set(1, 5, 1.0_f32);
    f.set(2, 6, 1.0_f32);
    f.set(3, 7, 1.0_f32);
    f
}

/// Measurement matrix H: extracts [cx, cy, w, h] from the 8-state vector.
///
/// ```text
/// [1 0 0 0 0 0 0 0]
/// [0 1 0 0 0 0 0 0]
/// [0 0 1 0 0 0 0 0]
/// [0 0 0 1 0 0 0 0]
/// ```
fn measurement_matrix() -> Mat4x8 {
    let mut h = [0.0_f32; 32];
    // H[0,0] = 1, H[1,1] = 1, H[2,2] = 1, H[3,3] = 1
    for i in 0..MEAS_DIM {
        if let Some(slot) = h.get_mut(i.wrapping_mul(STATE_DIM).wrapping_add(i)) {
            *slot = 1.0_f32;
        }
    }
    Mat4x8(h)
}

/// Builds the process noise covariance Q, scaled by the current state size.
///
/// Noise is proportional to the bounding box dimensions so that large objects
/// tolerate more position/velocity uncertainty than small ones.
fn process_noise(w: f32, h: f32) -> Mat8x8 {
    let size = (w + h) * 0.5_f32;
    let pos_var = (PROCESS_NOISE_POS_FACTOR * size) * (PROCESS_NOISE_POS_FACTOR * size);
    let vel_var = (PROCESS_NOISE_VEL_FACTOR * size) * (PROCESS_NOISE_VEL_FACTOR * size);
    Mat8x8::diagonal(&[
        pos_var, pos_var, pos_var, pos_var, vel_var, vel_var, vel_var, vel_var,
    ])
}

/// Builds the measurement noise covariance R, scaled by the measurement size.
fn measurement_noise(w: f32, h: f32) -> Mat4x4 {
    let size = (w + h) * 0.5_f32;
    let pos_var = (MEASUREMENT_NOISE_POS_FACTOR * size) * (MEASUREMENT_NOISE_POS_FACTOR * size);
    let size_var = (MEASUREMENT_NOISE_SIZE_FACTOR * size) * (MEASUREMENT_NOISE_SIZE_FACTOR * size);
    let mut r = [0.0_f32; 16];
    if let Some(slot) = r.get_mut(0) {
        *slot = pos_var;
    }
    if let Some(slot) = r.get_mut(5) {
        *slot = pos_var;
    }
    if let Some(slot) = r.get_mut(10) {
        *slot = size_var;
    }
    if let Some(slot) = r.get_mut(15) {
        *slot = size_var;
    }
    Mat4x4(r)
}

impl KalmanFilter {
    /// Initializes a filter from a first measurement `[cx, cy, w, h]`.
    ///
    /// Velocity components are initialized to zero. Initial covariance is
    /// large for velocity (high uncertainty) and moderate for position.
    fn new(measurement: [f32; MEAS_DIM]) -> Self {
        let x = Vec8([
            measurement.first().copied().unwrap_or(0.0_f32),
            measurement.get(1).copied().unwrap_or(0.0_f32),
            measurement.get(2).copied().unwrap_or(0.0_f32),
            measurement.get(3).copied().unwrap_or(0.0_f32),
            0.0_f32,
            0.0_f32,
            0.0_f32,
            0.0_f32,
        ]);

        let size = (measurement.get(2).copied().unwrap_or(0.0_f32)
            + measurement.get(3).copied().unwrap_or(0.0_f32))
            * 0.5_f32;
        let pos_std = 0.1_f32 * size;
        let vel_std = 0.05_f32 * size;
        let p = Mat8x8::diagonal(&[
            pos_std * pos_std,
            pos_std * pos_std,
            pos_std * pos_std,
            pos_std * pos_std,
            vel_std * vel_std,
            vel_std * vel_std,
            vel_std * vel_std,
            vel_std * vel_std,
        ]);

        Self { x, p }
    }

    /// Predict step: advance state by one frame using constant-velocity model.
    fn predict(&mut self) {
        let f = transition_matrix();
        let ft = f.transpose();

        // x' = F * x
        self.x = f.mul_vec(&self.x);

        // Adaptive process noise based on current estimated size.
        let w = self.x.0.get(2).copied().unwrap_or(0.01_f32).max(0.01_f32);
        let h = self.x.0.get(3).copied().unwrap_or(0.01_f32).max(0.01_f32);
        let q = process_noise(w, h);

        // P' = F * P * F^T + Q
        self.p = f.mul_8x8(&self.p).mul_8x8(&ft).add(&q);
    }

    /// Update step: incorporate a new measurement.
    ///
    /// Returns the pre-fit residual (innovation).
    #[expect(
        clippy::many_single_char_names,
        reason = "Kalman filter update uses standard notation from the literature: \
                  z (measurement), H (observation matrix), y (innovation), R (measurement noise), \
                  S (innovation covariance), K (Kalman gain). Renaming these would obscure the \
                  correspondence with the standard equations."
    )]
    fn update(&mut self, measurement: [f32; MEAS_DIM]) -> Vec4 {
        let z = Vec4(measurement);
        let hmat = measurement_matrix();
        let ht = hmat.transpose();

        // Innovation: y = z - H * x
        let predicted_meas = hmat.mul_vec(&self.x);
        let y = z.sub(&predicted_meas);

        // Adaptive measurement noise based on measurement size.
        let meas_w = measurement
            .get(2)
            .copied()
            .unwrap_or(0.01_f32)
            .max(0.01_f32);
        let meas_h = measurement
            .get(3)
            .copied()
            .unwrap_or(0.01_f32)
            .max(0.01_f32);
        let r = measurement_noise(meas_w, meas_h);

        // Innovation covariance: S = H * P * H^T + R
        let hp = hmat.mul_8x8(&self.p);
        let s = Mat4x4(hp.mul_vec_to_4x4(&ht, &r));

        // Kalman gain: K = P * H^T * S^-1
        let Some(s_inv) = s.invert() else {
            // Singular innovation covariance — measurement adds no
            // information. Skip the update, preserving the predict-only
            // state. This can happen when the covariance collapses
            // (e.g. two identical measurements) but is not an error.
            return y;
        };
        let k = self.p.mul_8x4(&ht).mul_4x4(&s_inv);

        // State update: x = x + K * y
        self.x = self.x.add(&k.mul_vec(&y));

        // Covariance update (Joseph form):
        // P = (I - KH) * P * (I - KH)^T + K * R * K^T
        //
        // The Joseph form is symmetric positive-definite by construction,
        // unlike the simple P = (I - KH)P which accumulates roundoff and
        // can lose positive-definiteness over long-lived tracks.
        let kh = k.mul_4x8(&hmat);
        let i_kh = Mat8x8::identity().sub(&kh);
        let i_kh_t = i_kh.transpose();
        let kt = k.transpose();
        let kr = k.mul_4x4(&r);
        self.p = i_kh.mul_8x8(&self.p).mul_8x8(&i_kh_t).add(&kr.mul_4x8(&kt));

        y
    }

    /// Returns the predicted bounding box as `[cx, cy, w, h]`.
    fn state_bbox(&self) -> [f32; MEAS_DIM] {
        [
            self.x.0.first().copied().unwrap_or(0.0_f32),
            self.x.0.get(1).copied().unwrap_or(0.0_f32),
            self.x.0.get(2).copied().unwrap_or(0.0_f32).max(0.0_f32),
            self.x.0.get(3).copied().unwrap_or(0.0_f32).max(0.0_f32),
        ]
    }

    /// Returns the velocity estimate `[dcx, dcy, dw, dh]`.
    fn velocity(&self) -> [f32; MEAS_DIM] {
        [
            self.x.0.get(4).copied().unwrap_or(0.0_f32),
            self.x.0.get(5).copied().unwrap_or(0.0_f32),
            self.x.0.get(6).copied().unwrap_or(0.0_f32),
            self.x.0.get(7).copied().unwrap_or(0.0_f32),
        ]
    }
}

/// Helper: compute `H * P * H^T + R` as a flat 4x4.
///
/// Avoids allocating intermediate `Mat4x8` by doing the full
/// `(4x8) * (8x8) * (8x4)` in-line and adding R directly.
impl Mat4x8 {
    fn mul_vec_to_4x4(&self, ht: &Mat8x4, r: &Mat4x4) -> [f32; 16] {
        // self is H (4x8), need H * P * H^T, but we receive HP (4x8) as self.
        // Actually this receives HP already. Multiply HP * H^T + R.
        let mut out = [0.0_f32; 16];
        for row in 0..MEAS_DIM {
            for col in 0..MEAS_DIM {
                let mut sum = 0.0_f32;
                for k in 0..STATE_DIM {
                    sum += self.get(row, k) * ht.get(k, col);
                }
                sum += r.get(row, col);
                if let Some(slot) = out.get_mut(row.wrapping_mul(MEAS_DIM).wrapping_add(col)) {
                    *slot = sum;
                }
            }
        }
        out
    }
}

// ---------------------------------------------------------------------------
// IoU computation
// ---------------------------------------------------------------------------

/// Converts a center-form bbox `[cx, cy, w, h]` to corner-form `[x1, y1, x2, y2]`.
fn center_to_corners(bbox: &[f32; 4]) -> [f32; 4] {
    let cx = bbox.first().copied().unwrap_or(0.0_f32);
    let cy = bbox.get(1).copied().unwrap_or(0.0_f32);
    let w = bbox.get(2).copied().unwrap_or(0.0_f32);
    let h = bbox.get(3).copied().unwrap_or(0.0_f32);
    let hw = w * 0.5_f32;
    let hh = h * 0.5_f32;
    [cx - hw, cy - hh, cx + hw, cy + hh]
}

/// Intersection over Union between two center-form bboxes `[cx, cy, w, h]`.
fn iou_center(a: &[f32; 4], b: &[f32; 4]) -> f32 {
    let ca = center_to_corners(a);
    let cb = center_to_corners(b);

    let x1 = ca
        .first()
        .copied()
        .unwrap_or(0.0_f32)
        .max(cb.first().copied().unwrap_or(0.0_f32));
    let y1 = ca
        .get(1)
        .copied()
        .unwrap_or(0.0_f32)
        .max(cb.get(1).copied().unwrap_or(0.0_f32));
    let x2 = ca
        .get(2)
        .copied()
        .unwrap_or(0.0_f32)
        .min(cb.get(2).copied().unwrap_or(0.0_f32));
    let y2 = ca
        .get(3)
        .copied()
        .unwrap_or(0.0_f32)
        .min(cb.get(3).copied().unwrap_or(0.0_f32));

    let inter_w = (x2 - x1).max(0.0_f32);
    let inter_h = (y2 - y1).max(0.0_f32);
    let inter = inter_w * inter_h;

    let area_a = a.get(2).copied().unwrap_or(0.0_f32) * a.get(3).copied().unwrap_or(0.0_f32);
    let area_b = b.get(2).copied().unwrap_or(0.0_f32) * b.get(3).copied().unwrap_or(0.0_f32);
    let union = area_a + area_b - inter;

    if union <= 0.0_f32 {
        return 0.0_f32;
    }

    inter / union
}

// ---------------------------------------------------------------------------
// Hungarian algorithm (Kuhn-Munkres)
// ---------------------------------------------------------------------------

/// Pre-allocated work buffers for the Hungarian algorithm.
///
/// Avoids per-frame heap allocation on the Cortex-A7 hot path. Buffers are
/// resized (never shrunk) to fit the current problem size.
#[derive(Debug, Clone)]
struct HungarianWork {
    cost: Vec<f32>,
    assignment: Vec<usize>,
    col_to_row: Vec<usize>,
    visited_cols: Vec<bool>,
    visited_rows: Vec<bool>,
    parent_row: Vec<usize>,
    row_queue: Vec<usize>,
}

impl HungarianWork {
    const fn new() -> Self {
        Self {
            cost: Vec::new(),
            assignment: Vec::new(),
            col_to_row: Vec::new(),
            visited_cols: Vec::new(),
            visited_rows: Vec::new(),
            parent_row: Vec::new(),
            row_queue: Vec::new(),
        }
    }

    /// Resizes all buffers to fit an `n x n` square problem.
    fn resize(&mut self, n: usize) {
        let unassigned = usize::MAX;
        self.cost.resize(n.saturating_mul(n), 0.0_f32);
        self.assignment.resize(n, unassigned);
        self.col_to_row.resize(n, unassigned);
        self.visited_cols.resize(n, false);
        self.visited_rows.resize(n, false);
        self.parent_row.resize(n, unassigned);
        // row_queue doesn't need a fixed size — it's cleared and pushed to.
    }
}

/// Solves the linear assignment problem for a cost matrix using the
/// Hungarian algorithm (Jonker-Volgenant variant for rectangular matrices).
///
/// Input: `costs` is a row-major `n_rows x n_cols` cost matrix where
/// `costs[r * n_cols + c]` is the cost of assigning row `r` to column `c`.
///
/// Returns a vec of `(row, col)` pairs representing the optimal assignment.
/// Unassigned rows/columns are omitted.
///
/// Cost values should be non-negative. The algorithm minimizes total cost.
#[expect(
    clippy::arithmetic_side_effects,
    reason = "Hungarian algorithm: index arithmetic on bounded matrix dimensions \
              (max ~50 tracks x ~20 detections). All loop indices are < n_rows or \
              n_cols. f32 cost subtraction on bounded IoU-derived values."
)]
fn hungarian(
    costs: &[f32],
    n_rows: usize,
    n_cols: usize,
    work: &mut HungarianWork,
) -> Vec<(usize, usize)> {
    if n_rows == 0 || n_cols == 0 {
        return Vec::new();
    }

    // Pad to square matrix (larger dimension).
    let n = if n_rows > n_cols { n_rows } else { n_cols };
    work.resize(n);

    // Fill the padded cost matrix from the input.
    work.cost.fill(0.0_f32);
    for r in 0..n_rows {
        for c in 0..n_cols {
            let val = costs.get(r * n_cols + c).copied().unwrap_or(0.0_f32);
            if let Some(slot) = work.cost.get_mut(r * n + c) {
                *slot = val;
            }
        }
    }

    // Step 1: Row reduction — subtract row minimum from each row.
    for r in 0..n {
        let mut min_val = f32::MAX;
        for c in 0..n {
            let v = work.cost.get(r * n + c).copied().unwrap_or(0.0_f32);
            if v < min_val {
                min_val = v;
            }
        }
        for c in 0..n {
            if let Some(slot) = work.cost.get_mut(r * n + c) {
                *slot -= min_val;
            }
        }
    }

    // Step 2: Column reduction — subtract column minimum from each column.
    for c in 0..n {
        let mut min_val = f32::MAX;
        for r in 0..n {
            let v = work.cost.get(r * n + c).copied().unwrap_or(0.0_f32);
            if v < min_val {
                min_val = v;
            }
        }
        for r in 0..n {
            if let Some(slot) = work.cost.get_mut(r * n + c) {
                *slot -= min_val;
            }
        }
    }

    // Initialize assignment arrays.
    let unassigned = usize::MAX;
    work.assignment.fill(unassigned);
    work.col_to_row.fill(unassigned);

    // Iteratively find augmenting paths.
    for r in 0..n {
        augment_row(r, work, n);
    }

    // Collect valid assignments (only original rows/cols, not padding).
    let mut result = Vec::new();
    for r in 0..n_rows {
        let c = work.assignment.get(r).copied().unwrap_or(unassigned);
        if c < n_cols {
            result.push((r, c));
        }
    }
    result
}

/// Finds an augmenting path for a single row, adjusting costs if needed.
#[expect(
    clippy::arithmetic_side_effects,
    reason = "Hungarian algorithm: index arithmetic on bounded matrix dimensions \
              (max ~50 tracks x ~20 detections). f32 cost adjustments on bounded values."
)]
fn augment_row(r: usize, work: &mut HungarianWork, n: usize) {
    let unassigned = usize::MAX;
    work.visited_cols.fill(false);
    work.parent_row.fill(unassigned);

    if try_augment(r, work, n) {
        return;
    }

    // Full Hungarian step: find minimum uncovered value, adjust costs, retry.
    loop {
        work.visited_rows.fill(false);
        work.visited_cols.fill(false);
        work.parent_row.fill(unassigned);
        work.row_queue.clear();
        work.row_queue.push(r);
        if let Some(vr) = work.visited_rows.get_mut(r) {
            *vr = true;
        }

        // Build alternating tree.
        let mut changed = true;
        while changed {
            changed = false;
            // Iterate over a snapshot of the current queue length to avoid
            // borrow conflicts — new entries appended during the loop are
            // picked up on the next `while changed` iteration.
            let queue_len = work.row_queue.len();
            for qi in 0..queue_len {
                let qr = work.row_queue.get(qi).copied().unwrap_or(usize::MAX);
                if qr == usize::MAX {
                    continue;
                }
                for c in 0..n {
                    if work.visited_cols.get(c).copied().unwrap_or(true) {
                        continue;
                    }
                    let val = work.cost.get(qr * n + c).copied().unwrap_or(f32::MAX);
                    if val.abs() < 1e-9_f32 {
                        if let Some(vc) = work.visited_cols.get_mut(c) {
                            *vc = true;
                        }
                        let matched_row = work.col_to_row.get(c).copied().unwrap_or(unassigned);
                        if matched_row == unassigned {
                            if let Some(slot) = work.parent_row.get_mut(c) {
                                *slot = qr;
                            }
                            flip_path(
                                c,
                                &work.parent_row,
                                &mut work.assignment,
                                &mut work.col_to_row,
                            );
                            changed = false;
                            work.row_queue.clear();
                            break;
                        }
                        if let Some(slot) = work.parent_row.get_mut(c) {
                            *slot = qr;
                        }
                        if !work.visited_rows.get(matched_row).copied().unwrap_or(true) {
                            if let Some(vr) = work.visited_rows.get_mut(matched_row) {
                                *vr = true;
                            }
                            work.row_queue.push(matched_row);
                            changed = true;
                        }
                    }
                }
            }
        }

        if work.assignment.get(r).copied().unwrap_or(unassigned) != unassigned {
            break;
        }

        // Find minimum uncovered cost.
        let mut min_uncovered = f32::MAX;
        for row in 0..n {
            if !work.visited_rows.get(row).copied().unwrap_or(false) {
                continue;
            }
            for col in 0..n {
                if work.visited_cols.get(col).copied().unwrap_or(true) {
                    continue;
                }
                let val = work.cost.get(row * n + col).copied().unwrap_or(f32::MAX);
                if val < min_uncovered {
                    min_uncovered = val;
                }
            }
        }

        if min_uncovered >= f32::MAX * 0.5_f32 {
            break;
        }

        // Adjust costs: subtract from uncovered, add to doubly-covered.
        for row in 0..n {
            for col in 0..n {
                let row_vis = work.visited_rows.get(row).copied().unwrap_or(false);
                let col_vis = work.visited_cols.get(col).copied().unwrap_or(false);
                if let Some(slot) = work.cost.get_mut(row * n + col) {
                    if row_vis && !col_vis {
                        *slot -= min_uncovered;
                    } else if !row_vis && col_vis {
                        *slot += min_uncovered;
                    }
                }
            }
        }
    }
}

/// Attempts a simple augmenting path from `row` via DFS.
///
/// Returns `true` if an augmenting path was found and flipped.
fn try_augment(row: usize, work: &mut HungarianWork, n: usize) -> bool {
    let unassigned = usize::MAX;
    for c in 0..n {
        if work.visited_cols.get(c).copied().unwrap_or(true) {
            continue;
        }
        let val = work
            .cost
            .get(row.wrapping_mul(n).wrapping_add(c))
            .copied()
            .unwrap_or(f32::MAX);
        if val.abs() < 1e-9_f32 {
            if let Some(vc) = work.visited_cols.get_mut(c) {
                *vc = true;
            }
            if let Some(slot) = work.parent_row.get_mut(c) {
                *slot = row;
            }
            let matched_row = work.col_to_row.get(c).copied().unwrap_or(unassigned);
            if matched_row == unassigned || try_augment(matched_row, work, n) {
                if let Some(a) = work.assignment.get_mut(row) {
                    *a = c;
                }
                if let Some(cr) = work.col_to_row.get_mut(c) {
                    *cr = row;
                }
                return true;
            }
        }
    }
    false
}

/// Traces back the augmenting path from `col` and flips assignments.
fn flip_path(
    start_col: usize,
    parent_row: &[usize],
    assignment: &mut [usize],
    col_to_row: &mut [usize],
) {
    let unassigned = usize::MAX;
    let mut col = start_col;
    loop {
        let row = parent_row.get(col).copied().unwrap_or(unassigned);
        if row == unassigned {
            break;
        }
        let prev_col = assignment.get(row).copied().unwrap_or(unassigned);
        if let Some(a) = assignment.get_mut(row) {
            *a = col;
        }
        if let Some(cr) = col_to_row.get_mut(col) {
            *cr = row;
        }
        if prev_col == unassigned {
            break;
        }
        col = prev_col;
    }
}

// ---------------------------------------------------------------------------
// Track
// ---------------------------------------------------------------------------

/// A single tracked object maintained across frames.
#[derive(Debug, Clone)]
pub(crate) struct Track {
    /// Monotonically increasing track identifier, assigned at creation.
    id: u32,
    /// Current lifecycle state.
    state: TrackState,
    /// Kalman filter state.
    kf: KalmanFilter,
    /// Consecutive frames with a matched detection (reset to 0 on coast).
    hits: u32,
    /// Consecutive frames without a matched detection.
    coast_frames: u32,
    /// COCO class ID of the initial detection (used for class filtering).
    class_id: u16,
}

impl Track {
    /// Returns the track's unique identifier.
    pub(crate) const fn id(&self) -> u32 {
        self.id
    }

    /// Returns the current lifecycle state.
    pub(crate) const fn state(&self) -> TrackState {
        self.state
    }

    /// Returns the predicted bounding box center and size as `[cx, cy, w, h]`
    /// in normalized frame coordinates (0.0–1.0).
    pub(crate) fn bbox(&self) -> [f32; MEAS_DIM] {
        self.kf.state_bbox()
    }

    /// Returns the estimated velocity `[dcx, dcy, dw, dh]` in normalized
    /// units per frame. Multiply by FPS to get per-second velocity.
    pub(crate) fn velocity(&self) -> [f32; MEAS_DIM] {
        self.kf.velocity()
    }

    /// Returns the COCO class ID of the detection that created this track.
    pub(crate) const fn class_id(&self) -> u16 {
        self.class_id
    }
}

// ---------------------------------------------------------------------------
// Tracker
// ---------------------------------------------------------------------------

/// SORT multi-object tracker.
///
/// Call [`update()`](Self::update) once per frame with the detections from
/// [`Detector::detect()`](crate::detect::Detector::detect). Returns a slice
/// of active [`Track`]s (tentative, confirmed, or coasting).
#[derive(Debug)]
pub(crate) struct Tracker {
    config: TrackerConfig,
    tracks: Vec<Track>,
    next_id: u32,
    // Pre-allocated buffers reused across frames.
    cost_matrix: Vec<f32>,
    assignments: Vec<(usize, usize)>,
    matched_tracks: Vec<bool>,
    matched_detections: Vec<bool>,
    normalized: Vec<[f32; MEAS_DIM]>,
    hungarian_work: HungarianWork,
}

impl Tracker {
    /// Creates a new tracker with the given configuration.
    pub(crate) const fn new(config: TrackerConfig) -> Self {
        Self {
            config,
            tracks: Vec::new(),
            next_id: 0_u32,
            cost_matrix: Vec::new(),
            assignments: Vec::new(),
            matched_tracks: Vec::new(),
            matched_detections: Vec::new(),
            normalized: Vec::new(),
            hungarian_work: HungarianWork::new(),
        }
    }

    /// Returns the currently active tracks.
    pub(crate) fn tracks(&self) -> &[Track] {
        &self.tracks
    }

    /// Processes a frame's detections and updates all tracks.
    ///
    /// `detections` are in pixel coordinates from the detector.
    /// `model_width` and `model_height` are the detector's input dimensions
    /// used to normalize coordinates to 0.0–1.0.
    pub(crate) fn update(&mut self, detections: &[Detection], model_width: f32, model_height: f32) {
        // Normalize detections to [cx, cy, w, h] in 0.0-1.0 range.
        self.normalized.clear();
        for det in detections {
            self.normalized
                .push(normalize_detection(&det.bbox, model_width, model_height));
        }

        // Predict all tracks forward.
        for track in &mut self.tracks {
            track.kf.predict();
        }

        // Build cost matrix, solve assignment, classify matches.
        self.build_cost_matrix();
        let n_tracks = self.tracks.len();
        let n_dets = self.normalized.len();
        self.assignments = hungarian(
            &self.cost_matrix,
            n_tracks,
            n_dets,
            &mut self.hungarian_work,
        );
        self.classify_matches(n_tracks, n_dets);

        // Apply matches, coast unmatched, spawn new, prune dead.
        self.apply_matches();
        self.coast_unmatched();
        self.spawn_new_tracks(detections);
        self.tracks
            .retain(|track| track.coast_frames <= self.config.max_coast_frames);
    }

    /// Builds the `IoU`-based cost matrix (tracks x detections).
    fn build_cost_matrix(&mut self) {
        let n_tracks = self.tracks.len();
        let n_dets = self.normalized.len();

        self.cost_matrix.clear();
        self.cost_matrix
            .resize(n_tracks.saturating_mul(n_dets), 0.0_f32);

        for (t, track) in self.tracks.iter().enumerate() {
            let track_bbox = track.kf.state_bbox();
            for (d, norm_det) in self.normalized.iter().enumerate() {
                let iou_val = iou_center(&track_bbox, norm_det);
                let cost = if iou_val >= self.config.iou_threshold {
                    1.0_f32 - iou_val
                } else {
                    1.0_f32
                };
                if let Some(slot) = self
                    .cost_matrix
                    .get_mut(t.wrapping_mul(n_dets).wrapping_add(d))
                {
                    *slot = cost;
                }
            }
        }
    }

    /// Classifies assignment results into matched/unmatched tracks and detections.
    fn classify_matches(&mut self, n_tracks: usize, n_dets: usize) {
        self.matched_tracks.clear();
        self.matched_tracks.resize(n_tracks, false);
        self.matched_detections.clear();
        self.matched_detections.resize(n_dets, false);

        for &(t, d) in &self.assignments {
            let track_bbox = self
                .tracks
                .get(t)
                .map_or([0.0_f32; MEAS_DIM], |tr| tr.kf.state_bbox());
            let det_bbox = self
                .normalized
                .get(d)
                .copied()
                .unwrap_or([0.0_f32; MEAS_DIM]);
            let iou_val = iou_center(&track_bbox, &det_bbox);
            if iou_val >= self.config.iou_threshold {
                if let Some(mt) = self.matched_tracks.get_mut(t) {
                    *mt = true;
                }
                if let Some(md) = self.matched_detections.get_mut(d) {
                    *md = true;
                }
            }
        }
    }

    /// Updates matched tracks with their assigned detections.
    fn apply_matches(&mut self) {
        // Clone assignments to avoid borrow conflict with self.tracks.
        let assignments = self.assignments.clone();
        for (t, d) in assignments {
            if !self.matched_tracks.get(t).copied().unwrap_or(false) {
                continue;
            }
            if let (Some(track), Some(measurement)) =
                (self.tracks.get_mut(t), self.normalized.get(d))
            {
                let _ = track.kf.update(*measurement);
                track.hits = track.hits.saturating_add(1_u32);
                track.coast_frames = 0_u32;

                if track.state == TrackState::Tentative
                    && track.hits >= self.config.min_hits_to_confirm
                {
                    track.state = TrackState::Confirmed;
                }

                if track.state == TrackState::Coasting {
                    track.state = TrackState::Confirmed;
                }
            }
        }
    }

    /// Marks unmatched tracks as coasting.
    fn coast_unmatched(&mut self) {
        for (t, track) in self.tracks.iter_mut().enumerate() {
            if self.matched_tracks.get(t).copied().unwrap_or(false) {
                continue;
            }
            track.coast_frames = track.coast_frames.saturating_add(1_u32);
            track.hits = 0_u32;
            if track.state != TrackState::Coasting {
                track.state = TrackState::Coasting;
            }
        }
    }

    /// Spawns new tentative tracks for unmatched detections.
    fn spawn_new_tracks(&mut self, detections: &[Detection]) {
        for (d, det) in detections.iter().enumerate() {
            if self.matched_detections.get(d).copied().unwrap_or(true) {
                continue;
            }
            if let Some(measurement) = self.normalized.get(d) {
                let id = self.next_id;
                self.next_id = self.next_id.saturating_add(1_u32);
                self.tracks.push(Track {
                    id,
                    state: TrackState::Tentative,
                    kf: KalmanFilter::new(*measurement),
                    hits: 1_u32,
                    coast_frames: 0_u32,
                    class_id: det.class_id,
                });
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Normalizes a pixel-space bounding box to `[cx, cy, w, h]` in 0.0–1.0.
fn normalize_detection(bbox: &BoundingBox, model_width: f32, model_height: f32) -> [f32; MEAS_DIM] {
    let cx = (bbox.x1 + bbox.x2) * 0.5_f32 / model_width;
    let cy = (bbox.y1 + bbox.y2) * 0.5_f32 / model_height;
    let w = (bbox.x2 - bbox.x1) / model_width;
    let h = (bbox.y2 - bbox.y1) / model_height;
    [cx, cy, w, h]
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[expect(
    clippy::indexing_slicing,
    clippy::expect_used,
    clippy::as_conversions,
    clippy::cast_precision_loss,
    clippy::arithmetic_side_effects,
    reason = "test code: indexing on known-size arrays, expect for assertions, \
              arithmetic and casts on small known values"
)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    // -------------------------------------------------------------------
    // Kalman filter tests
    // -------------------------------------------------------------------

    #[test]
    fn test_kalman_new_initializes_at_measurement() {
        let meas = [0.5_f32, 0.5_f32, 0.2_f32, 0.3_f32];
        let kf = KalmanFilter::new(meas);
        let state = kf.state_bbox();
        assert!(
            (state[0] - 0.5_f32).abs() < 1e-6_f32,
            "cx should be 0.5, got {}",
            state[0]
        );
        assert!(
            (state[1] - 0.5_f32).abs() < 1e-6_f32,
            "cy should be 0.5, got {}",
            state[1]
        );
        assert!(
            (state[2] - 0.2_f32).abs() < 1e-6_f32,
            "w should be 0.2, got {}",
            state[2]
        );
        assert!(
            (state[3] - 0.3_f32).abs() < 1e-6_f32,
            "h should be 0.3, got {}",
            state[3]
        );

        let vel = kf.velocity();
        for (i, &v) in vel.iter().enumerate() {
            assert!(
                v.abs() < 1e-6_f32,
                "initial velocity[{i}] should be 0, got {v}"
            );
        }
    }

    #[test]
    fn test_kalman_predict_constant_velocity() {
        let meas = [0.5_f32, 0.5_f32, 0.2_f32, 0.3_f32];
        let mut kf = KalmanFilter::new(meas);
        // Manually set a velocity.
        kf.x.0[4] = 0.01_f32; // dcx
        kf.x.0[5] = -0.02_f32; // dcy

        kf.predict();
        let state = kf.state_bbox();
        assert!(
            (state[0] - 0.51_f32).abs() < 1e-4_f32,
            "cx should advance by velocity, got {}",
            state[0]
        );
        assert!(
            (state[1] - 0.48_f32).abs() < 1e-4_f32,
            "cy should advance by velocity, got {}",
            state[1]
        );
    }

    #[test]
    fn test_kalman_update_converges_on_stationary_target() {
        let true_pos = [0.5_f32, 0.5_f32, 0.2_f32, 0.3_f32];
        let mut kf = KalmanFilter::new([0.4_f32, 0.4_f32, 0.15_f32, 0.25_f32]);

        for _ in 0_i32..20_i32 {
            kf.predict();
            let _ = kf.update(true_pos);
        }

        let state = kf.state_bbox();
        assert!(
            (state[0] - 0.5_f32).abs() < 0.01_f32,
            "cx should converge to 0.5, got {}",
            state[0]
        );
        assert!(
            (state[1] - 0.5_f32).abs() < 0.01_f32,
            "cy should converge to 0.5, got {}",
            state[1]
        );
        assert!(
            (state[2] - 0.2_f32).abs() < 0.02_f32,
            "w should converge to 0.2, got {}",
            state[2]
        );
        assert!(
            (state[3] - 0.3_f32).abs() < 0.02_f32,
            "h should converge to 0.3, got {}",
            state[3]
        );
    }

    #[test]
    fn test_kalman_update_tracks_moving_target() {
        let mut kf = KalmanFilter::new([0.3_f32, 0.3_f32, 0.1_f32, 0.1_f32]);

        // Move target rightward at ~0.01 per frame.
        for i in 0_u32..30 {
            kf.predict();
            let cx = 0.01_f32.mul_add((i + 1) as f32, 0.3_f32);
            let _ = kf.update([cx, 0.3_f32, 0.1_f32, 0.1_f32]);
        }

        let vel = kf.velocity();
        assert!(
            (vel[0] - 0.01_f32).abs() < 0.005_f32,
            "x velocity should converge near 0.01, got {}",
            vel[0]
        );
        assert!(
            vel[1].abs() < 0.005_f32,
            "y velocity should be near 0, got {}",
            vel[1]
        );
    }

    #[test]
    fn test_kalman_predict_without_update_drifts_with_velocity() {
        let mut kf = KalmanFilter::new([0.5_f32, 0.5_f32, 0.1_f32, 0.1_f32]);
        kf.x.0[4] = 0.02_f32;

        for _ in 0_i32..5_i32 {
            kf.predict();
        }

        let state = kf.state_bbox();
        assert!(
            (state[0] - 0.6_f32).abs() < 1e-3_f32,
            "cx should drift to ~0.6 after 5 predictions with dcx=0.02, got {}",
            state[0]
        );
    }

    // -------------------------------------------------------------------
    // Mat4x4 inversion tests
    // -------------------------------------------------------------------

    #[test]
    fn test_mat4x4_identity_inverts_to_identity() {
        let id = Mat4x4::identity();
        let inv = id.invert().expect("identity must be invertible");
        for r in 0..4 {
            for c in 0..4 {
                let expected = if r == c { 1.0_f32 } else { 0.0_f32 };
                let val = inv.get(r, c);
                assert!(
                    (val - expected).abs() < 1e-6_f32,
                    "inv[{r},{c}] should be {expected}, got {val}"
                );
            }
        }
    }

    #[test]
    fn test_mat4x4_diagonal_inversion() {
        let mut m = Mat4x4([0.0_f32; 16]);
        m.set(0, 0, 2.0_f32);
        m.set(1, 1, 4.0_f32);
        m.set(2, 2, 0.5_f32);
        m.set(3, 3, 8.0_f32);

        let inv = m.invert().expect("diagonal matrix must be invertible");
        assert!(
            (inv.get(0, 0) - 0.5_f32).abs() < 1e-6_f32,
            "inv[0,0] should be 0.5"
        );
        assert!(
            (inv.get(1, 1) - 0.25_f32).abs() < 1e-6_f32,
            "inv[1,1] should be 0.25"
        );
        assert!(
            (inv.get(2, 2) - 2.0_f32).abs() < 1e-6_f32,
            "inv[2,2] should be 2.0"
        );
        assert!(
            (inv.get(3, 3) - 0.125_f32).abs() < 1e-6_f32,
            "inv[3,3] should be 0.125"
        );
    }

    #[test]
    fn test_mat4x4_singular_returns_none() {
        let m = Mat4x4([0.0_f32; 16]); // All zeros = singular.
        assert!(m.invert().is_none(), "zero matrix should not be invertible");
    }

    // -------------------------------------------------------------------
    // IoU tests
    // -------------------------------------------------------------------

    #[test]
    fn test_iou_identical_boxes() {
        let a = [0.5_f32, 0.5_f32, 0.2_f32, 0.2_f32];
        let result = iou_center(&a, &a);
        assert!(
            (result - 1.0_f32).abs() < 1e-5_f32,
            "IoU of identical boxes should be 1.0, got {result}"
        );
    }

    #[test]
    fn test_iou_non_overlapping() {
        let a = [0.1_f32, 0.1_f32, 0.1_f32, 0.1_f32];
        let b = [0.9_f32, 0.9_f32, 0.1_f32, 0.1_f32];
        let result = iou_center(&a, &b);
        assert!(
            result < 1e-6_f32,
            "IoU of non-overlapping boxes should be ~0, got {result}"
        );
    }

    #[test]
    fn test_iou_partial_overlap() {
        // Two boxes: both 0.2x0.2, centered 0.1 apart horizontally.
        let a = [0.4_f32, 0.5_f32, 0.2_f32, 0.2_f32];
        let b = [0.5_f32, 0.5_f32, 0.2_f32, 0.2_f32];
        let result = iou_center(&a, &b);
        // Overlap = 0.1 * 0.2 = 0.02, Union = 2 * 0.04 - 0.02 = 0.06
        // IoU = 0.02 / 0.06 = 1/3
        assert!(
            (result - 1.0_f32 / 3.0_f32).abs() < 1e-5_f32,
            "IoU should be ~0.333, got {result}"
        );
    }

    #[test]
    fn test_iou_zero_area_box() {
        let a = [0.5_f32, 0.5_f32, 0.0_f32, 0.0_f32];
        let b = [0.5_f32, 0.5_f32, 0.2_f32, 0.2_f32];
        let result = iou_center(&a, &b);
        assert!(
            result.abs() < 1e-6_f32,
            "IoU with zero-area box should be 0, got {result}"
        );
    }

    // -------------------------------------------------------------------
    // Hungarian algorithm tests
    // -------------------------------------------------------------------

    #[test]
    fn test_hungarian_empty() {
        let mut work = HungarianWork::new();
        let result = hungarian(&[], 0, 0, &mut work);
        assert!(
            result.is_empty(),
            "empty matrix should produce no assignments"
        );
    }

    #[test]
    fn test_hungarian_1x1() {
        let costs = [0.5_f32];
        let mut work = HungarianWork::new();
        let result = hungarian(&costs, 1, 1, &mut work);
        assert_eq!(result.len(), 1, "1x1 matrix should produce one assignment");
        assert_eq!(result[0], (0, 0), "1x1 assignment should be (0, 0)");
    }

    #[test]
    fn test_hungarian_identity_cost() {
        // 3x3 identity cost matrix — each row should match its column.
        let costs = [
            0.0_f32, 1.0_f32, 1.0_f32, 1.0_f32, 0.0_f32, 1.0_f32, 1.0_f32, 1.0_f32, 0.0_f32,
        ];
        let mut work = HungarianWork::new();
        let result = hungarian(&costs, 3, 3, &mut work);
        assert_eq!(result.len(), 3, "3x3 should produce 3 assignments");
        let mut total = 0.0_f32;
        for &(r, c) in &result {
            total += costs[r * 3 + c];
        }
        assert!(
            total < 1e-6_f32,
            "optimal assignment should have zero cost, got {total}"
        );
    }

    #[test]
    fn test_hungarian_permuted_cost() {
        // Optimal assignment: (0→2), (1→0), (2→1) = cost 1+2+3 = 6.
        let costs = [
            10.0_f32, 5.0_f32, 1.0_f32, 2.0_f32, 10.0_f32, 8.0_f32, 7.0_f32, 3.0_f32, 10.0_f32,
        ];
        let mut work = HungarianWork::new();
        let result = hungarian(&costs, 3, 3, &mut work);
        let mut total = 0.0_f32;
        for &(r, c) in &result {
            total += costs[r * 3 + c];
        }
        assert!(
            (total - 6.0_f32).abs() < 1e-5_f32,
            "optimal cost should be 6.0, got {total}"
        );
    }

    #[test]
    fn test_hungarian_more_rows_than_cols() {
        // 3 tracks, 2 detections.
        let costs = [0.1_f32, 0.9_f32, 0.9_f32, 0.1_f32, 0.5_f32, 0.5_f32];
        let mut work = HungarianWork::new();
        let result = hungarian(&costs, 3, 2, &mut work);
        assert!(
            result.len() <= 2,
            "at most 2 assignments for 2 columns, got {}",
            result.len()
        );
        let mut total = 0.0_f32;
        for &(r, c) in &result {
            total += costs[r * 2 + c];
        }
        assert!(total < 0.3_f32, "optimal cost should be ~0.2, got {total}");
    }

    #[test]
    fn test_hungarian_more_cols_than_rows() {
        // 2 tracks, 3 detections.
        let costs = [0.1_f32, 0.9_f32, 0.5_f32, 0.9_f32, 0.1_f32, 0.5_f32];
        let mut work = HungarianWork::new();
        let result = hungarian(&costs, 2, 3, &mut work);
        assert_eq!(result.len(), 2, "2 rows should produce 2 assignments");
        let mut total = 0.0_f32;
        for &(r, c) in &result {
            total += costs[r * 3 + c];
        }
        assert!(total < 0.3_f32, "optimal cost should be ~0.2, got {total}");
    }

    // -------------------------------------------------------------------
    // Normalization tests
    // -------------------------------------------------------------------

    #[test]
    fn test_normalize_detection_full_frame() {
        let bbox = BoundingBox {
            x1: 0.0_f32,
            y1: 0.0_f32,
            x2: 640.0_f32,
            y2: 480.0_f32,
        };
        let norm = normalize_detection(&bbox, 640.0_f32, 480.0_f32);
        assert!(
            (norm[0] - 0.5_f32).abs() < 1e-6_f32,
            "cx should be 0.5, got {}",
            norm[0]
        );
        assert!(
            (norm[1] - 0.5_f32).abs() < 1e-6_f32,
            "cy should be 0.5, got {}",
            norm[1]
        );
        assert!(
            (norm[2] - 1.0_f32).abs() < 1e-6_f32,
            "w should be 1.0, got {}",
            norm[2]
        );
        assert!(
            (norm[3] - 1.0_f32).abs() < 1e-6_f32,
            "h should be 1.0, got {}",
            norm[3]
        );
    }

    #[test]
    fn test_normalize_detection_quarter_frame() {
        let bbox = BoundingBox {
            x1: 160.0_f32,
            y1: 120.0_f32,
            x2: 480.0_f32,
            y2: 360.0_f32,
        };
        let norm = normalize_detection(&bbox, 640.0_f32, 480.0_f32);
        assert!(
            (norm[0] - 0.5_f32).abs() < 1e-6_f32,
            "cx should be 0.5, got {}",
            norm[0]
        );
        assert!(
            (norm[1] - 0.5_f32).abs() < 1e-6_f32,
            "cy should be 0.5, got {}",
            norm[1]
        );
        assert!(
            (norm[2] - 0.5_f32).abs() < 1e-6_f32,
            "w should be 0.5, got {}",
            norm[2]
        );
        assert!(
            (norm[3] - 0.5_f32).abs() < 1e-6_f32,
            "h should be 0.5, got {}",
            norm[3]
        );
    }

    // -------------------------------------------------------------------
    // Track lifecycle tests
    // -------------------------------------------------------------------

    fn make_detection(x1: f32, y1: f32, x2: f32, y2: f32, class_id: u16) -> Detection {
        Detection {
            bbox: BoundingBox { x1, y1, x2, y2 },
            class_id,
            confidence: 0.9_f32,
        }
    }

    #[test]
    fn test_tracker_single_detection_creates_tentative_track() {
        let mut tracker = Tracker::new(TrackerConfig::default());
        let dets = [make_detection(
            100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32, 15,
        )];
        tracker.update(&dets, 640.0_f32, 480.0_f32);

        assert_eq!(
            tracker.tracks().len(),
            1,
            "single detection should create one track"
        );
        assert_eq!(
            tracker.tracks()[0].state(),
            TrackState::Tentative,
            "new track should be tentative"
        );
        assert_eq!(tracker.tracks()[0].id(), 0, "first track ID should be 0");
    }

    #[test]
    fn test_tracker_three_hits_promotes_to_confirmed() {
        let mut tracker = Tracker::new(TrackerConfig::default());
        let dets = [make_detection(
            100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32, 15,
        )];

        for _ in 0_i32..3_i32 {
            tracker.update(&dets, 640.0_f32, 480.0_f32);
        }

        assert_eq!(
            tracker.tracks().len(),
            1,
            "consistently matched detection should maintain one track"
        );
        assert_eq!(
            tracker.tracks()[0].state(),
            TrackState::Confirmed,
            "track should be confirmed after 3 hits"
        );
    }

    #[test]
    fn test_tracker_empty_frame_causes_coasting() {
        let mut tracker = Tracker::new(TrackerConfig::default());
        let dets = [make_detection(
            100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32, 15,
        )];

        // 3 frames to confirm.
        for _ in 0_i32..3_i32 {
            tracker.update(&dets, 640.0_f32, 480.0_f32);
        }
        assert_eq!(
            tracker.tracks()[0].state(),
            TrackState::Confirmed,
            "should be confirmed"
        );

        // Empty frame.
        tracker.update(&[], 640.0_f32, 480.0_f32);
        assert_eq!(
            tracker.tracks()[0].state(),
            TrackState::Coasting,
            "should be coasting after empty frame"
        );
    }

    #[test]
    fn test_tracker_dead_track_removed_after_max_coast() {
        let config = TrackerConfig {
            max_coast_frames: 5_u32,
            ..TrackerConfig::default()
        };
        let mut tracker = Tracker::new(config);
        let dets = [make_detection(
            100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32, 15,
        )];

        tracker.update(&dets, 640.0_f32, 480.0_f32);
        assert_eq!(tracker.tracks().len(), 1, "should have one track");

        for _ in 0_i32..6_i32 {
            tracker.update(&[], 640.0_f32, 480.0_f32);
        }

        assert!(
            tracker.tracks().is_empty(),
            "track should be removed after exceeding max coast frames"
        );
    }

    #[test]
    fn test_tracker_reacquire_coasting_to_confirmed() {
        let mut tracker = Tracker::new(TrackerConfig::default());
        let dets = [make_detection(
            100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32, 15,
        )];

        // Confirm the track.
        for _ in 0_i32..3_i32 {
            tracker.update(&dets, 640.0_f32, 480.0_f32);
        }

        // Coast for 2 frames.
        tracker.update(&[], 640.0_f32, 480.0_f32);
        tracker.update(&[], 640.0_f32, 480.0_f32);
        assert_eq!(
            tracker.tracks()[0].state(),
            TrackState::Coasting,
            "should be coasting"
        );

        // Re-acquire.
        tracker.update(&dets, 640.0_f32, 480.0_f32);
        assert_eq!(
            tracker.tracks()[0].state(),
            TrackState::Confirmed,
            "should return to confirmed on re-acquisition"
        );
    }

    #[test]
    fn test_tracker_two_detections_create_two_tracks() {
        let mut tracker = Tracker::new(TrackerConfig::default());
        let dets = [
            make_detection(50.0_f32, 50.0_f32, 150.0_f32, 150.0_f32, 15),
            make_detection(400.0_f32, 300.0_f32, 500.0_f32, 400.0_f32, 15),
        ];

        tracker.update(&dets, 640.0_f32, 480.0_f32);
        assert_eq!(
            tracker.tracks().len(),
            2,
            "two separate detections should create two tracks"
        );
        assert_ne!(
            tracker.tracks()[0].id(),
            tracker.tracks()[1].id(),
            "tracks should have distinct IDs"
        );
    }

    #[test]
    fn test_tracker_track_id_monotonic() {
        let mut tracker = Tracker::new(TrackerConfig::default());

        // Frame 1: two detections.
        let dets1 = [
            make_detection(50.0_f32, 50.0_f32, 150.0_f32, 150.0_f32, 15),
            make_detection(400.0_f32, 300.0_f32, 500.0_f32, 400.0_f32, 15),
        ];
        tracker.update(&dets1, 640.0_f32, 480.0_f32);

        // Frame 2: new detection far from existing tracks.
        let dets2 = [
            make_detection(50.0_f32, 50.0_f32, 150.0_f32, 150.0_f32, 15),
            make_detection(400.0_f32, 300.0_f32, 500.0_f32, 400.0_f32, 15),
            make_detection(300.0_f32, 200.0_f32, 350.0_f32, 250.0_f32, 15),
        ];
        tracker.update(&dets2, 640.0_f32, 480.0_f32);

        let ids: Vec<u32> = tracker.tracks().iter().map(Track::id).collect();
        for window in ids.windows(2) {
            assert!(
                window[0] < window[1],
                "track IDs should be monotonically increasing: {ids:?}"
            );
        }
    }

    #[test]
    fn test_tracker_class_id_preserved() {
        let mut tracker = Tracker::new(TrackerConfig::default());
        let dets = [make_detection(
            100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32, 42,
        )];
        tracker.update(&dets, 640.0_f32, 480.0_f32);

        assert_eq!(
            tracker.tracks()[0].class_id(),
            42_u16,
            "track should preserve detection class_id"
        );
    }

    #[test]
    fn test_tracker_normalized_coordinates_in_range() {
        let mut tracker = Tracker::new(TrackerConfig::default());
        let dets = [make_detection(
            100.0_f32, 50.0_f32, 300.0_f32, 200.0_f32, 15,
        )];
        tracker.update(&dets, 640.0_f32, 480.0_f32);

        let bbox = tracker.tracks()[0].bbox();
        for (i, &val) in bbox.iter().enumerate() {
            assert!(
                (0.0_f32..=1.0_f32).contains(&val),
                "bbox[{i}] = {val} should be in [0, 1]"
            );
        }
    }

    #[test]
    fn test_tracker_stable_track_across_many_frames() {
        let mut tracker = Tracker::new(TrackerConfig::default());
        let dets = [make_detection(
            300.0_f32, 220.0_f32, 380.0_f32, 300.0_f32, 15,
        )];

        for _ in 0_i32..50_i32 {
            tracker.update(&dets, 640.0_f32, 480.0_f32);
        }

        assert_eq!(
            tracker.tracks().len(),
            1,
            "stable detection should maintain exactly one track"
        );
        assert_eq!(
            tracker.tracks()[0].id(),
            0,
            "track ID should remain 0 (same track)"
        );
        assert_eq!(
            tracker.tracks()[0].state(),
            TrackState::Confirmed,
            "track should be confirmed"
        );
    }

    #[test]
    fn test_tracker_moving_detection_tracked_correctly() {
        let mut tracker = Tracker::new(TrackerConfig::default());

        // Move a detection slowly across the frame.
        for i in 0_u32..20 {
            let x_offset = 2.0_f32 * i as f32;
            let dets = [make_detection(
                100.0_f32 + x_offset,
                100.0_f32,
                200.0_f32 + x_offset,
                200.0_f32,
                15,
            )];
            tracker.update(&dets, 640.0_f32, 480.0_f32);
        }

        assert_eq!(
            tracker.tracks().len(),
            1,
            "slowly moving detection should maintain one track"
        );
        let vel = tracker.tracks()[0].velocity();
        assert!(
            vel[0] > 0.0_f32,
            "x velocity should be positive for rightward motion, got {}",
            vel[0]
        );
    }

    // -------------------------------------------------------------------
    // Property-based tests
    // -------------------------------------------------------------------

    proptest! {
        #[test]
        fn test_iou_symmetric(
            cx_a in 0.1_f32..0.9_f32,
            cy_a in 0.1_f32..0.9_f32,
            w_a in 0.05_f32..0.3_f32,
            h_a in 0.05_f32..0.3_f32,
            cx_b in 0.1_f32..0.9_f32,
            cy_b in 0.1_f32..0.9_f32,
            w_b in 0.05_f32..0.3_f32,
            h_b in 0.05_f32..0.3_f32,
        ) {
            let a = [cx_a, cy_a, w_a, h_a];
            let b = [cx_b, cy_b, w_b, h_b];
            let iou_ab = iou_center(&a, &b);
            let iou_ba = iou_center(&b, &a);
            prop_assert!(
                (iou_ab - iou_ba).abs() < 1e-6_f32,
                "IoU must be symmetric: IoU(a,b)={iou_ab}, IoU(b,a)={iou_ba}",
            );
        }

        #[test]
        fn test_iou_bounded(
            cx_a in 0.1_f32..0.9_f32,
            cy_a in 0.1_f32..0.9_f32,
            w_a in 0.01_f32..0.5_f32,
            h_a in 0.01_f32..0.5_f32,
            cx_b in 0.1_f32..0.9_f32,
            cy_b in 0.1_f32..0.9_f32,
            w_b in 0.01_f32..0.5_f32,
            h_b in 0.01_f32..0.5_f32,
        ) {
            let a = [cx_a, cy_a, w_a, h_a];
            let b = [cx_b, cy_b, w_b, h_b];
            let result = iou_center(&a, &b);
            prop_assert!(
                (0.0_f32..=1.0_f32).contains(&result),
                "IoU must be in [0, 1], got {result}",
            );
        }

        #[test]
        fn test_iou_self_is_one(
            cx in 0.1_f32..0.9_f32,
            cy in 0.1_f32..0.9_f32,
            w in 0.01_f32..0.5_f32,
            h in 0.01_f32..0.5_f32,
        ) {
            let a = [cx, cy, w, h];
            let result = iou_center(&a, &a);
            prop_assert!(
                (result - 1.0_f32).abs() < 1e-5_f32,
                "IoU(a,a) must be 1.0, got {result}",
            );
        }

        #[test]
        fn test_kalman_predict_preserves_finite(
            cx in 0.0_f32..1.0_f32,
            cy in 0.0_f32..1.0_f32,
            w in 0.01_f32..0.5_f32,
            h in 0.01_f32..0.5_f32,
        ) {
            let mut kf = KalmanFilter::new([cx, cy, w, h]);
            for _ in 0_i32..10_i32 {
                kf.predict();
            }
            let state = kf.state_bbox();
            for (i, &v) in state.iter().enumerate() {
                prop_assert!(
                    v.is_finite(),
                    "state[{i}] must be finite after 10 predictions, got {v}",
                );
            }
        }

        #[test]
        fn test_kalman_update_preserves_finite(
            cx in 0.1_f32..0.9_f32,
            cy in 0.1_f32..0.9_f32,
            w in 0.05_f32..0.4_f32,
            h in 0.05_f32..0.4_f32,
        ) {
            let mut kf = KalmanFilter::new([cx, cy, w, h]);
            for _ in 0_i32..10_i32 {
                kf.predict();
                let _ = kf.update([cx, cy, w, h]);
            }
            let state = kf.state_bbox();
            for (i, &v) in state.iter().enumerate() {
                prop_assert!(
                    v.is_finite(),
                    "state[{i}] must be finite after predict/update cycles, got {v}",
                );
            }
            let vel = kf.velocity();
            for (i, &v) in vel.iter().enumerate() {
                prop_assert!(
                    v.is_finite(),
                    "velocity[{i}] must be finite, got {v}",
                );
            }
        }

        #[test]
        fn test_tracker_never_duplicates_ids(
            n_frames in 1_usize..15,
        ) {
            let mut tracker = Tracker::new(TrackerConfig {
                min_hits_to_confirm: 2,
                max_coast_frames: 3,
                iou_threshold: 0.3_f32,
            });

            let dets = [
                make_detection(100.0_f32, 100.0_f32, 200.0_f32, 200.0_f32, 15),
                make_detection(400.0_f32, 300.0_f32, 500.0_f32, 400.0_f32, 15),
            ];

            for _ in 0..n_frames {
                tracker.update(&dets, 640.0_f32, 480.0_f32);
            }

            let ids: Vec<u32> = tracker.tracks().iter().map(Track::id).collect();
            let unique: std::collections::HashSet<u32> = ids.iter().copied().collect();
            prop_assert!(
                ids.len() == unique.len(),
                "all track IDs must be unique: {:?}",
                ids,
            );
        }

        #[test]
        fn test_hungarian_assignment_valid(
            n in 1_usize..8,
        ) {
            // Square identity-like cost matrix.
            let mut costs = vec![1.0_f32; n * n];
            for i in 0..n {
                costs[i * n + i] = 0.0_f32;
            }
            let mut work = HungarianWork::new();
            let result = hungarian(&costs, n, n, &mut work);
            prop_assert_eq!(
                result.len(),
                n,
                "square assignment should produce n pairs",
            );

            // Verify no row or column appears twice.
            let mut used_rows = vec![false; n];
            let mut used_cols = vec![false; n];
            for &(r, c) in &result {
                prop_assert!(
                    !used_rows[r],
                    "row {r} assigned twice",
                );
                prop_assert!(
                    !used_cols[c],
                    "col {c} assigned twice",
                );
                used_rows[r] = true;
                used_cols[c] = true;
            }
        }
    }
}
