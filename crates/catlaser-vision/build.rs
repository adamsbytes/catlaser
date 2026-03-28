fn main() -> Result<(), Box<dyn std::error::Error>> {
    buffa_build::Config::new()
        .files(&[
            "../../proto/catlaser/detection/v1/detection.proto",
            "../../proto/catlaser/app/v1/app.proto",
        ])
        .includes(&["../../proto"])
        .compile()?;
    Ok(())
}
