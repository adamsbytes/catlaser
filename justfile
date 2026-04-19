check:
    cargo fmt --all
    cargo clippy --all-targets
    cargo test --release
    cargo doc --no-deps --document-private-items
    cargo deny check
    just py-check
    just ios-check
    just server-check
    just shellcheck

check-mcu:
    cargo clippy -p catlaser-mcu --target thumbv8m.main-none-eabi

check-mcu-secure:
    cd crates/catlaser-mcu-secure && cargo +nightly clippy --all-targets

build:
    cargo build

build-mcu:
    cargo build -p catlaser-mcu --target thumbv8m.main-none-eabi --release

build-mcu-secure:
    cd crates/catlaser-mcu-secure && cargo +nightly build --release

build-mcu-all: build-mcu-secure build-mcu

build-vision-cross:
    cargo +nightly build \
        -Zbuild-std=std,panic_abort \
        --target armv7-unknown-linux-uclibceabihf \
        --release \
        -p catlaser-vision

build-all: build-mcu-all build-vision-cross

build-image *args:
    ./deploy/build-image.sh {{args}}

flash *args:
    ./deploy/flash.sh {{args}}

convert-models:
    python3 models/convert/convert_yolo.py
    python3 models/convert/convert_reid.py

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

shellcheck:
    shellcheck deploy/*.sh
    shellcheck deploy/rootfs/etc/init.d/*

py-check:
    cd python && ruff check .
    cd python && ruff format --check .
    cd python && pyright .

py-fmt:
    cd python && ruff check --fix .
    cd python && ruff format .

py-test:
    cd python && .venv/bin/python -m pytest

ios-build:
    cd app/ios && swift build

# `--no-parallel` is load-bearing on Linux: Swift Testing's
# task-based concurrency layer leaks `AsyncStream` consumer tasks
# between suites on swift-6.3-linux, which saturates the cooperative
# thread pool and hangs the run past the last test. Serialised
# execution avoids that; Darwin CI still exercises the parallel path
# via Xcode's test runner.
ios-test:
    cd app/ios && swift test --no-parallel

ios-check: ios-build ios-test

# Archive the shipping Xcode app target. macOS-only — the xcodeproj
# pulls in LiveKit's WebRTC xcframework and needs xcodebuild + a
# provisioned signing identity. Running this on Linux will fail at
# `xcodebuild` invocation; the SPM package still builds and tests
# via `just ios-check` on any host.
ios-xcode-build:
    cd app/ios/App && xcodebuild -scheme CATLASER -configuration Debug -destination 'generic/platform=iOS Simulator' build

ios-xcode-archive:
    cd app/ios/App && xcodebuild -scheme CATLASER -configuration Release -destination 'generic/platform=iOS' archive -archivePath build/CATLASER.xcarchive

server-check:
    cd server && bun run lint
    cd server && bun run typecheck
    cd server && bun run tests

server-dev:
    cd server && bun run dev

server-docker-up:
    cd server && bun run docker:up

server-docker-down:
    cd server && bun run docker:down
