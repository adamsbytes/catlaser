check:
    cargo fmt --all
    cargo clippy --all-targets
    cargo test --release
    cargo doc --no-deps --document-private-items
    cargo deny check

check-mcu:
    cargo clippy -p catlaser-mcu --target thumbv6m-none-eabi

build:
    cargo build

build-mcu:
    cargo build -p catlaser-mcu --target thumbv6m-none-eabi --release

test crate:
    cargo test --release -p catlaser-{{crate}} -- --nocapture

test-debug crate="":
    {{ if crate == "" { "cargo test" } else { "cargo test -p catlaser-" + crate + " -- --nocapture" } }}

mutants:
    cargo mutants

bench:
    cargo bench

docs:
    cargo doc --no-deps --open

proto-lint:
    buf lint proto/

proto-generate:
    buf generate

proto-format:
    buf format -w proto/

proto: proto-format proto-lint proto-generate

clean-deps:
    cargo machete
