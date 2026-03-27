//! Shared types and constants for the catlaser workspace.
//!
//! Wire-format structs, safety limits, and pin assignments used by both
//! the compute module (catlaser-vision) and MCU firmware (catlaser-mcu).

#![no_std]

pub mod constants;
pub mod servo_cmd;

pub use servo_cmd::{ChecksumError, Flags, ServoCommand};
