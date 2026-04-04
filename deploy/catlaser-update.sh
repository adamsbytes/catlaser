#!/bin/sh
# catlaser-update.sh - On-device OTA update for catlaser.
#
# Updates the vision daemon binary and Python behavior sidecar on the
# writable overlay partition. Does NOT replace the read-only rootfs or
# kernel — full firmware updates require reflashing via USB.
#
# The update bundle is a tar.gz containing:
#   catlaser-visiond          - ARM binary (stripped)
#   catlaser_brain/           - Python package directory
#   yolov8n-coco.rknn         - (optional) updated detection model
#   cat_reid_mobilenet.rknn   - (optional) updated re-ID model
#   sha256sums.txt            - SHA256 checksums for all files
#
# Usage (run on device):
#   /usr/bin/catlaser-update.sh /tmp/catlaser-update.tar.gz
#   /usr/bin/catlaser-update.sh https://example.com/catlaser-update.tar.gz

set -eu

BUNDLE_PATH="$1"
STAGING_DIR="/tmp/catlaser-update-staging"
INSTALL_BIN="/usr/bin"
INSTALL_LIB="/usr/lib"
BRAIN_DIR="${INSTALL_LIB}/catlaser-brain/catlaser_brain"
MODEL_DIR="${INSTALL_LIB}"

cleanup() {
    rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

# ── Download or copy bundle ──────────────────────────────────────────

case "${BUNDLE_PATH}" in
    http://*|https://*)
        echo "Downloading update bundle..."
        wget -q -O "${STAGING_DIR}/bundle.tar.gz" "${BUNDLE_PATH}"
        ;;
    *)
        if [ ! -f "${BUNDLE_PATH}" ]; then
            echo "ERROR: Bundle not found: ${BUNDLE_PATH}" >&2
            exit 1
        fi
        cp "${BUNDLE_PATH}" "${STAGING_DIR}/bundle.tar.gz"
        ;;
esac

# ── Extract and verify ───────────────────────────────────────────────

echo "Extracting update bundle..."
cd "${STAGING_DIR}"
tar xzf bundle.tar.gz

if [ ! -f sha256sums.txt ]; then
    echo "ERROR: sha256sums.txt missing from bundle" >&2
    exit 1
fi

echo "Verifying checksums..."
sha256sum -c sha256sums.txt
echo "Checksums verified."

# ── Stop services ────────────────────────────────────────────────────

echo "Stopping services..."
/etc/init.d/S91behavior stop || true
/etc/init.d/S90visiond stop || true

# ── Install files ────────────────────────────────────────────────────

echo "Installing update..."

if [ -f catlaser-visiond ]; then
    cp catlaser-visiond "${INSTALL_BIN}/catlaser-visiond"
    chmod +x "${INSTALL_BIN}/catlaser-visiond"
fi

if [ -d catlaser_brain ]; then
    rm -rf "${BRAIN_DIR}"
    cp -r catlaser_brain "${BRAIN_DIR}"
fi

if [ -f yolov8n-coco.rknn ]; then
    cp yolov8n-coco.rknn "${MODEL_DIR}/"
fi

if [ -f cat_reid_mobilenet.rknn ]; then
    cp cat_reid_mobilenet.rknn "${MODEL_DIR}/"
fi

# ── Restart services ─────────────────────────────────────────────────

echo "Restarting services..."
/etc/init.d/S90visiond start
/etc/init.d/S91behavior start

echo "Update complete."
