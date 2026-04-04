//! Build script for catlaser-mcu (Non-Secure image).
//!
//! Sets linker arguments for cortex-m-rt entry point and defmt log frames,
//! adds the crate root to the linker search path so `memory.x` is found,
//! and links against the Secure image's CMSE veneer import library so
//! gateway extern declarations resolve to NSC veneer addresses.

fn main() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default();

    println!("cargo:rustc-link-search={dir}");
    println!("cargo:rerun-if-changed=memory.x");

    // cortex-m-rt entry point and defmt log frames.
    println!("cargo:rustc-link-arg-bins=--nmagic");
    println!("cargo:rustc-link-arg-bins=-Tlink.x");
    println!("cargo:rustc-link-arg-bins=-Tdefmt.x");

    // Link against the Secure image's CMSE veneer import library.
    // This resolves the extern "C" gateway function symbols declared
    // in src/gateway.rs to the NSC veneer addresses produced by the
    // Secure image's two-stage link (ADR-005).
    let secure_dir = format!("{dir}/../catlaser-mcu-secure");
    println!("cargo:rustc-link-arg-bins={secure_dir}/cmse_veneer.o");
    println!("cargo:rerun-if-changed={secure_dir}/cmse_veneer.o");
}
