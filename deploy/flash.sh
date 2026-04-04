#!/usr/bin/env bash
# flash.sh - Flash firmware image to device via USB using Luckfox SDK tools.
#
# The device must be connected via USB and in maskrom or loader mode.
# Hold the BOOT button while powering on to enter maskrom mode.
#
# Requires:
#   LUCKFOX_SDK_PATH - Luckfox Pico SDK root
#
# Usage:
#   ./deploy/flash.sh                        # Flash default SDK output image
#   ./deploy/flash.sh --image path/to/update.img  # Flash a specific image

set -euo pipefail

if [ -z "${LUCKFOX_SDK_PATH:-}" ]; then
    echo "ERROR: LUCKFOX_SDK_PATH not set" >&2
    exit 1
fi

IMAGE_PATH="${LUCKFOX_SDK_PATH}/output/image/update.img"

while [ $# -gt 0 ]; do
    case "$1" in
        --image)
            IMAGE_PATH="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--image path/to/update.img]" >&2
            exit 1
            ;;
    esac
done

if [ ! -f "${IMAGE_PATH}" ]; then
    echo "ERROR: Firmware image not found: ${IMAGE_PATH}" >&2
    echo "Run ./deploy/build-image.sh first." >&2
    exit 1
fi

UPGRADE_TOOL="${LUCKFOX_SDK_PATH}/tools/linux/Linux_Upgrade_Tool/Linux_Upgrade_Tool/upgrade_tool"

if [ ! -x "${UPGRADE_TOOL}" ]; then
    echo "ERROR: upgrade_tool not found at: ${UPGRADE_TOOL}" >&2
    exit 1
fi

echo "=== Flashing firmware ==="
echo "Image: ${IMAGE_PATH}"
echo ""
echo "Ensure the device is connected via USB in maskrom or loader mode."
echo "Press Ctrl+C within 3 seconds to cancel."
sleep 3

"${UPGRADE_TOOL}" uf "${IMAGE_PATH}"

echo ""
echo "=== Flash complete ==="
echo "The device will reboot automatically."
