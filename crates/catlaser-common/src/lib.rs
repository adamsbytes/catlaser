//! Shared types and constants for the catlaser workspace.
//!
//! Wire-format structs, safety limits, and pin assignments used by both
//! the compute module (catlaser-vision) and MCU firmware (catlaser-mcu).

#![no_std]

pub mod constants;
pub mod frame_parser;
pub mod hopper;
pub mod servo_cmd;
pub mod servo_math;
pub mod trustzone;

pub use frame_parser::FrameParser;
pub use hopper::HopperDebouncer;
pub use servo_cmd::{ChecksumError, DispenseDirection, Flags, ServoCommand};
