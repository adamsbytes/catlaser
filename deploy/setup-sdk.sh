#!/usr/bin/env bash
# setup-sdk.sh - Configure the Luckfox Pico SDK for catlaser builds.
#
# Idempotent. Applies the following to an existing LUCKFOX_SDK_PATH:
#   1. Symlinks .BoardConfig.mk to the Pico Ultra W IPC config.
#   2. Appends catlaser-overlay to RK_POST_OVERLAY so build-image.sh
#      can drop the rootfs/ tree into the final image.
#   3. Enables CONFIG_TUN in the kernel defconfig (tailscale needs it).
#   4. Backports the tailscale Buildroot package from upstream — the
#      Rockchip-forked Buildroot 2023.02.6 predates its addition
#      (merged upstream in 2023.11).
#   5. Enables BR2_PACKAGE_TAILSCALE in the Buildroot defconfig.
#
# Requires:
#   LUCKFOX_SDK_PATH - existing checkout of LuckfoxTECH/luckfox-pico
#   curl             - to fetch the tailscale package from git.buildroot.net
#
# First-time clone (not done by this script — the tree is ~10GB):
#   git clone https://github.com/LuckfoxTECH/luckfox-pico.git ~/luckfox-pico
#   export LUCKFOX_SDK_PATH=~/luckfox-pico
#
# Usage:
#   ./deploy/setup-sdk.sh

set -euo pipefail

BOARD_CONFIG_NAME="BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_Ultra_W-IPC.mk"
OVERLAY_NAME="catlaser-overlay"
BUILDROOT_TAG="2024.02.10"

# ── Preflight ───────────────────────────────────────────────────────

if [ -z "${LUCKFOX_SDK_PATH:-}" ]; then
    cat >&2 <<'USAGE'
ERROR: LUCKFOX_SDK_PATH is not set.

First-time setup:
    git clone https://github.com/LuckfoxTECH/luckfox-pico.git ~/luckfox-pico
    export LUCKFOX_SDK_PATH=~/luckfox-pico

Then re-run this script.
USAGE
    exit 1
fi

if [ ! -d "${LUCKFOX_SDK_PATH}" ]; then
    echo "ERROR: LUCKFOX_SDK_PATH does not exist: ${LUCKFOX_SDK_PATH}" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required to fetch the tailscale package" >&2
    exit 1
fi

BOARD_CONFIG="${LUCKFOX_SDK_PATH}/project/cfg/BoardConfig_IPC/${BOARD_CONFIG_NAME}"
if [ ! -f "${BOARD_CONFIG}" ]; then
    echo "ERROR: BoardConfig not found: ${BOARD_CONFIG}" >&2
    echo "       Check project/cfg/BoardConfig_IPC/ for the correct filename." >&2
    exit 1
fi

echo "=== catlaser SDK setup ==="
echo "SDK: ${LUCKFOX_SDK_PATH}"
echo ""

# ── Helpers ─────────────────────────────────────────────────────────

# Save a one-time backup the first time we touch a file, then no-op on
# subsequent runs. Lets the operator diff against .catlaser.bak to
# audit what the script changed.
backup_once() {
    local file="$1"
    if [ ! -f "${file}.catlaser.bak" ]; then
        cp "${file}" "${file}.catlaser.bak"
    fi
}

# Ensure a key=value line appears in a kconfig-style file. Removes any
# prior `# KEY is not set` comment form and any stale assignment.
set_kconfig() {
    local file="$1" key="$2" value="${3:-y}"
    if grep -qE "^${key}=${value}\$" "${file}"; then
        echo "  keep  ${key}=${value}"
        return 0
    fi
    backup_once "${file}"
    sed -i -E "/^(# *)?${key}( is not set|=)/d" "${file}"
    echo "${key}=${value}" >> "${file}"
    echo "  set   ${key}=${value}"
}

# Read the RHS of an `export KEY="value"` line from a BoardConfig .mk.
extract_mk_export() {
    local file="$1" key="$2"
    grep -E "^export ${key}=" "${file}" \
        | sed -E "s/^export ${key}=\"?([^\"]*)\"?\$/\1/" \
        | tail -n 1
}

# ── [1/5] Select BoardConfig ───────────────────────────────────────

echo "--- [1/5] Selecting BoardConfig ---"

# build.sh lunch is interactive. The effect is a single symlink at
# the SDK root — create it directly.
(
    cd "${LUCKFOX_SDK_PATH}"
    if [ -L .BoardConfig.mk ] \
        && [ "$(readlink .BoardConfig.mk)" = "project/cfg/BoardConfig_IPC/${BOARD_CONFIG_NAME}" ]; then
        echo "  keep  .BoardConfig.mk"
    else
        rm -f .BoardConfig.mk
        ln -s "project/cfg/BoardConfig_IPC/${BOARD_CONFIG_NAME}" .BoardConfig.mk
        echo "  link  .BoardConfig.mk -> ${BOARD_CONFIG_NAME}"
    fi
)

# ── [2/5] Append catlaser-overlay to RK_POST_OVERLAY ───────────────

echo ""
echo "--- [2/5] Registering catlaser-overlay ---"

if grep -qE "^export RK_POST_OVERLAY=\"[^\"]*\\b${OVERLAY_NAME}\\b" "${BOARD_CONFIG}"; then
    echo "  keep  RK_POST_OVERLAY contains ${OVERLAY_NAME}"
elif grep -qE "^export RK_POST_OVERLAY=" "${BOARD_CONFIG}"; then
    backup_once "${BOARD_CONFIG}"
    sed -i -E "s|^(export RK_POST_OVERLAY=\"[^\"]*)\"|\1 ${OVERLAY_NAME}\"|" "${BOARD_CONFIG}"
    echo "  add   ${OVERLAY_NAME} to RK_POST_OVERLAY"
else
    backup_once "${BOARD_CONFIG}"
    echo "export RK_POST_OVERLAY=\"${OVERLAY_NAME}\"" >> "${BOARD_CONFIG}"
    echo "  set   RK_POST_OVERLAY=\"${OVERLAY_NAME}\""
fi

# ── [3/5] Kernel: CONFIG_TUN=y ──────────────────────────────────────

echo ""
echo "--- [3/5] Kernel defconfig: CONFIG_TUN ---"

KERNEL_DEFCONFIG_NAME="$(extract_mk_export "${BOARD_CONFIG}" RK_KERNEL_DEFCONFIG)"
if [ -z "${KERNEL_DEFCONFIG_NAME}" ]; then
    echo "ERROR: RK_KERNEL_DEFCONFIG not set in BoardConfig" >&2
    exit 1
fi

# Rockchip SDKs place defconfigs at sysdrv/source/kernel/arch/arm/configs/.
KERNEL_DEFCONFIG="${LUCKFOX_SDK_PATH}/sysdrv/source/kernel/arch/arm/configs/${KERNEL_DEFCONFIG_NAME}"
if [ ! -f "${KERNEL_DEFCONFIG}" ]; then
    echo "ERROR: kernel defconfig not found: ${KERNEL_DEFCONFIG}" >&2
    exit 1
fi

set_kconfig "${KERNEL_DEFCONFIG}" CONFIG_TUN

# ── [4/5] Backport tailscale package to Buildroot ──────────────────

echo ""
echo "--- [4/5] Backporting tailscale package from Buildroot ${BUILDROOT_TAG} ---"

BUILDROOT_DIR="$(find "${LUCKFOX_SDK_PATH}/sysdrv/source/buildroot" -maxdepth 1 -type d -name 'buildroot-*' | sort | tail -n 1)"
if [ -z "${BUILDROOT_DIR}" ] || [ ! -d "${BUILDROOT_DIR}" ]; then
    echo "ERROR: Buildroot source not found under sysdrv/source/buildroot/" >&2
    exit 1
fi
echo "  tree  ${BUILDROOT_DIR#"${LUCKFOX_SDK_PATH}"/}"

PKG_DIR="${BUILDROOT_DIR}/package/tailscale"
if [ -f "${PKG_DIR}/tailscale.mk" ]; then
    echo "  keep  package/tailscale/ already vendored"
else
    mkdir -p "${PKG_DIR}"
    for f in Config.in tailscale.mk tailscale.hash; do
        url="https://git.buildroot.net/buildroot/plain/package/tailscale/${f}?h=${BUILDROOT_TAG}"
        if ! curl -fsSL --retry 3 "${url}" -o "${PKG_DIR}/${f}"; then
            echo "ERROR: failed to fetch ${url}" >&2
            rm -rf "${PKG_DIR}"
            exit 1
        fi
        echo "  fetch package/tailscale/${f}"
    done
fi

# Register the new Config.in under the Networking applications menu.
# Anchor on openssh's source line, which is stable across Buildroot
# versions and lives in the right menu.
PKG_CONFIG_IN="${BUILDROOT_DIR}/package/Config.in"
if grep -q 'package/tailscale/Config.in' "${PKG_CONFIG_IN}"; then
    echo "  keep  package/Config.in references tailscale"
elif grep -q 'source "package/openssh/Config.in"' "${PKG_CONFIG_IN}"; then
    backup_once "${PKG_CONFIG_IN}"
    sed -i '/source "package\/openssh\/Config.in"/a\	source "package/tailscale/Config.in"' "${PKG_CONFIG_IN}"
    echo "  add   source line to package/Config.in"
else
    echo "ERROR: could not find openssh anchor in ${PKG_CONFIG_IN}" >&2
    echo "       the Networking applications menu layout has shifted —" >&2
    echo "       add 'source \"package/tailscale/Config.in\"' manually." >&2
    exit 1
fi

# ── [5/5] Enable BR2_PACKAGE_TAILSCALE ─────────────────────────────

echo ""
echo "--- [5/5] Buildroot defconfig: BR2_PACKAGE_TAILSCALE ---"

BR_DEFCONFIG_NAME="$(extract_mk_export "${BOARD_CONFIG}" RK_CFG_BUILDROOT)"
if [ -z "${BR_DEFCONFIG_NAME}" ]; then
    echo "ERROR: RK_CFG_BUILDROOT not set in BoardConfig" >&2
    exit 1
fi

# Rockchip stores Buildroot defconfigs inside the Buildroot tree's
# configs/ directory with a _defconfig suffix.
BR_DEFCONFIG="${BUILDROOT_DIR}/configs/${BR_DEFCONFIG_NAME}_defconfig"
if [ ! -f "${BR_DEFCONFIG}" ]; then
    echo "ERROR: Buildroot defconfig not found: ${BR_DEFCONFIG}" >&2
    exit 1
fi

set_kconfig "${BR_DEFCONFIG}" BR2_PACKAGE_TAILSCALE

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Provision /userdata/tailscale/authkey on the device before first boot"
echo "     (generate a tagged pre-auth key in the Tailscale admin console)."
echo "  2. Run 'just build-image' to rebuild the firmware image."
echo "  3. Run 'just flash' to push it to a device in maskrom/loader mode."
