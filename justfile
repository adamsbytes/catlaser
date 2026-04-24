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
    just kicad-check

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

setup-sdk:
    ./deploy/setup-sdk.sh

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

# ---------------------------------------------------------------------------
# Hardware: circuit-synth schematic + pcbnew SWIG layout, all in-process.
# PYTHONPATH points at the system site-packages where KiCad 10 ships
# pcbnew.py + _pcbnew.so; uv venvs do not see them otherwise.
# ---------------------------------------------------------------------------

export PYTHONPATH := "/usr/lib/python3/dist-packages"

kicad-check:
    cd hardware/kicad && uv run ruff check .
    cd hardware/kicad && uv run ruff format --check .
    cd hardware/kicad && uv run pyright .
    just kicad-test

kicad-fmt:
    cd hardware/kicad && uv run ruff check --fix .
    cd hardware/kicad && uv run ruff format .

kicad-test:
    cd hardware/kicad && uv run pytest

kicad-generate:
    cd hardware/kicad && uv run python -m catlaser_pcb.top

kicad-layout:
    cd hardware/kicad && uv run python -m catlaser_pcb.pcb

# Standalone DRC against the committed .kicad_pcb. `just kicad-layout`
# already runs DRC at the end; this target is for re-checking after a
# manual KiCad inspection or when validating a cherry-picked branch.
kicad-drc:
    kicad-cli pcb drc \
        --output hardware/kicad/project/output/drc-report.txt \
        --severity-error --severity-warning \
        --exit-code-violations --refill-zones \
        hardware/kicad/project/catlaser_aio.kicad_pcb

# CI gate: regenerate schematic + layout from Python sources and assert
# the committed project/ tree matches. Catches hand edits to the
# .kicad_pcb and pipeline non-determinism. Requires a clean working
# tree in hardware/kicad/project/ before running.
kicad-determinism:
    just kicad-generate
    just kicad-layout
    git diff --exit-code -- hardware/kicad/project/

kicad-bom:
    cd hardware/kicad && uv run python -m catlaser_pcb.fab.bom

kicad-cpl:
    cd hardware/kicad && uv run python -m catlaser_pcb.fab.cpl

kicad-pdf:
    cd hardware/kicad && uv run python -c "from catlaser_pcb.top import catlaser_aio; catlaser_aio().generate_pdf_schematic(project_name='catlaser_aio')"

kicad-gerbers:
    cd hardware/kicad && uv run python -c "from catlaser_pcb.top import catlaser_aio; catlaser_aio().generate_gerbers(project_name='catlaser_aio')"

# Bootstrap the Freerouting jar to .cache/. Version is required (no
# default) so the pin is explicit and reproducible. Resulting path
# must be exported as FREEROUTING_JAR for layout.route to find it.
kicad-setup-freerouting version:
    mkdir -p hardware/kicad/.cache
    gh release download v{{version}} \
        --repo freerouting/freerouting \
        --pattern 'freerouting-{{version}}.jar' \
        --dir hardware/kicad/.cache --clobber
    @echo "export FREEROUTING_JAR=$(realpath hardware/kicad/.cache/freerouting-{{version}}.jar)"
