//! Build script for catlaser-mcu.
//!
//! Sets linker arguments for cortex-m-rt entry point and defmt log frames,
//! and adds the crate root to the linker search path so `memory.x` is found.

fn main() {
    if let Ok(dir) = std::env::var("CARGO_MANIFEST_DIR") {
        println!("cargo:rustc-link-search={dir}");
    }
    println!("cargo:rerun-if-changed=memory.x");
    println!("cargo:rustc-link-arg-bins=--nmagic");
    println!("cargo:rustc-link-arg-bins=-Tlink.x");
    println!("cargo:rustc-link-arg-bins=-Tdefmt.x");
}
