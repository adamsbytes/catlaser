#!/usr/bin/env bash
# build-image.sh - Build all catlaser firmware artifacts and assemble
# the Luckfox Pico firmware image.
#
# Requires:
#   LUCKFOX_SDK_PATH  - Luckfox Pico SDK root
#   Rockchip SDK toolchain on PATH (arm-rockchip830-linux-uclibcgnueabihf-gcc)
#   arm-none-eabi-gcc on PATH (MCU firmware)
#   Rust nightly with rust-src component
#   Python 3.12+ with rknn-toolkit2 (for model conversion)
#
# Usage:
#   ./deploy/build-image.sh              # Full build
#   ./deploy/build-image.sh --skip-models # Skip ONNX->RKNN conversion

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OVERLAY_DIR="${SCRIPT_DIR}/rootfs"

VISION_TARGET="armv7-unknown-linux-uclibceabihf"
MCU_TARGET="thumbv8m.main-none-eabi"

SKIP_MODELS=false
for arg in "$@"; do
    case "$arg" in
        --skip-models) SKIP_MODELS=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# ── Preflight checks ────────────────────────────────────────────────

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: $1 not found on PATH" >&2
        exit 1
    fi
}

check_command arm-rockchip830-linux-uclibcgnueabihf-gcc
check_command arm-none-eabi-gcc
check_command cargo
check_command strip

if [ -z "${LUCKFOX_SDK_PATH:-}" ]; then
    echo "ERROR: LUCKFOX_SDK_PATH not set" >&2
    exit 1
fi

if [ ! -d "${LUCKFOX_SDK_PATH}" ]; then
    echo "ERROR: LUCKFOX_SDK_PATH does not exist: ${LUCKFOX_SDK_PATH}" >&2
    exit 1
fi

echo "=== Building catlaser firmware ==="
echo "SDK: ${LUCKFOX_SDK_PATH}"
echo "Project: ${PROJECT_ROOT}"

# ── 1. MCU Secure firmware (must build first — produces veneer .o) ───

echo ""
echo "--- Building MCU Secure firmware ---"
cd "${PROJECT_ROOT}/crates/catlaser-mcu-secure"
cargo +nightly build --release

# ── 2. MCU Non-Secure firmware (links against Secure veneer) ────────

echo ""
echo "--- Building MCU Non-Secure firmware ---"
cd "${PROJECT_ROOT}/crates/catlaser-mcu"
cargo build --release

# ── 3. Vision daemon (cross-compile for RV1106) ─────────────────────

echo ""
echo "--- Building vision daemon for RV1106 ---"
cd "${PROJECT_ROOT}"

# Set cross-compiler env vars for any -sys crates using the cc crate.
export CC_armv7_unknown_linux_uclibceabihf=arm-rockchip830-linux-uclibcgnueabihf-gcc
export CXX_armv7_unknown_linux_uclibceabihf=arm-rockchip830-linux-uclibcgnueabihf-g++
export AR_armv7_unknown_linux_uclibceabihf=arm-rockchip830-linux-uclibcgnueabihf-ar

cargo +nightly build \
    -Zbuild-std=std,panic_abort \
    --target "${VISION_TARGET}" \
    --release \
    -p catlaser-vision

# ── 4. Model conversion (ONNX → RKNN) ───────────────────────────────

if [ "${SKIP_MODELS}" = false ]; then
    echo ""
    echo "--- Converting ONNX models to RKNN ---"
    YOLO_RKNN="${PROJECT_ROOT}/models/yolov8n-coco.rknn"
    REID_RKNN="${PROJECT_ROOT}/models/cat_reid_mobilenet.rknn"
    YOLO_ONNX="${PROJECT_ROOT}/models/yolov8n-coco.onnx"
    REID_ONNX="${PROJECT_ROOT}/models/cat_reid_mobilenet.onnx"

    # Only re-convert if RKNN is missing or older than ONNX source.
    if [ ! -f "${YOLO_RKNN}" ] || [ "${YOLO_ONNX}" -nt "${YOLO_RKNN}" ]; then
        python3 "${PROJECT_ROOT}/models/convert/convert_yolo.py"
    else
        echo "yolov8n-coco.rknn is up to date, skipping."
    fi

    if [ ! -f "${REID_RKNN}" ] || [ "${REID_ONNX}" -nt "${REID_RKNN}" ]; then
        python3 "${PROJECT_ROOT}/models/convert/convert_reid.py"
    else
        echo "cat_reid_mobilenet.rknn is up to date, skipping."
    fi
else
    echo ""
    echo "--- Skipping model conversion (--skip-models) ---"
fi

# ── 5. Assemble rootfs overlay ───────────────────────────────────────

echo ""
echo "--- Assembling rootfs overlay ---"

VISION_BIN="${PROJECT_ROOT}/target/${VISION_TARGET}/release/catlaser-vision"
if [ ! -f "${VISION_BIN}" ]; then
    echo "ERROR: Vision binary not found: ${VISION_BIN}" >&2
    exit 1
fi

# Strip and copy vision daemon.
arm-rockchip830-linux-uclibcgnueabihf-strip \
    -o "${OVERLAY_DIR}/usr/bin/catlaser-visiond" \
    "${VISION_BIN}"

# Copy Python behavior sidecar.
# The wrapper script is a thin launcher that invokes the Python package.
cat > "${OVERLAY_DIR}/usr/bin/catlaser-brain" << 'WRAPPER'
#!/bin/sh
exec python3 -m catlaser_brain "$@"
WRAPPER
chmod +x "${OVERLAY_DIR}/usr/bin/catlaser-brain"

# Bundle the Python package into the overlay.
BRAIN_DEST="${OVERLAY_DIR}/usr/lib/catlaser-brain"
rm -rf "${BRAIN_DEST}"
cp -r "${PROJECT_ROOT}/python/catlaser_brain" "${BRAIN_DEST}/catlaser_brain"
cp "${PROJECT_ROOT}/python/pyproject.toml" "${BRAIN_DEST}/"

# Copy RKNN models if they exist.
if [ -f "${PROJECT_ROOT}/models/yolov8n-coco.rknn" ]; then
    cp "${PROJECT_ROOT}/models/yolov8n-coco.rknn" "${OVERLAY_DIR}/usr/lib/"
fi
if [ -f "${PROJECT_ROOT}/models/cat_reid_mobilenet.rknn" ]; then
    cp "${PROJECT_ROOT}/models/cat_reid_mobilenet.rknn" "${OVERLAY_DIR}/usr/lib/"
fi

echo "Overlay assembled at: ${OVERLAY_DIR}"

# ── 6. Build firmware image via Luckfox SDK ──────────────────────────

echo ""
echo "--- Building firmware image ---"

# Copy overlay into SDK's overlay directory.
SDK_OVERLAY="${LUCKFOX_SDK_PATH}/project/cfg/BoardConfig_IPC/overlay/catlaser-overlay"
rm -rf "${SDK_OVERLAY}"
cp -r "${OVERLAY_DIR}" "${SDK_OVERLAY}"

cd "${LUCKFOX_SDK_PATH}"
./build.sh firmware
./build.sh updateimg

echo ""
echo "=== Build complete ==="
echo "MCU Secure:     ${PROJECT_ROOT}/crates/catlaser-mcu-secure/target/${MCU_TARGET}/release/catlaser-mcu-secure"
echo "MCU Non-Secure: ${PROJECT_ROOT}/crates/catlaser-mcu/target/${MCU_TARGET}/release/catlaser-mcu"
echo "Vision daemon:  ${OVERLAY_DIR}/usr/bin/catlaser-visiond"
echo "Firmware image: ${LUCKFOX_SDK_PATH}/output/image/update.img"
