//! Build script for catlaser-mcu-secure.
//!
//! Adds the crate root to the linker search path so `memory.x` is found,
//! sets linker arguments for cortex-m-rt entry point and defmt frames,
//! and configures CMSE veneer import library generation.
//!
//! The `--cmse-implib` flag tells the linker to produce a veneer import
//! library (`cmse_veneer.o`) that the Non-Secure image links against to
//! resolve gateway function addresses. This is the "two-stage link"
//! described in ADR-005.

fn main() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default();

    println!("cargo:rustc-link-search={dir}");
    println!("cargo:rerun-if-changed=memory.x");

    // cortex-m-rt entry point and defmt log frames.
    println!("cargo:rustc-link-arg-bins=--nmagic");
    println!("cargo:rustc-link-arg-bins=-Tlink.x");
    println!("cargo:rustc-link-arg-bins=-Tdefmt.x");

    // CMSE: generate veneer import library for the Non-Secure image.
    // The linker produces cmse_veneer.o in the crate root directory,
    // which the NS build.rs adds to its link line.
    println!("cargo:rustc-link-arg-bins=--cmse-implib");
    println!("cargo:rustc-link-arg-bins=--out-implib={dir}/cmse_veneer.o");
}
