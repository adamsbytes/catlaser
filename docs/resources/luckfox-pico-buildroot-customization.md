# Luckfox Pico Buildroot Customization for Production Rootfs

## SDK Build System Overview

The Luckfox Pico SDK wraps a Rockchip-forked Buildroot (2023.02.6) with a `build.sh` entry point. Board selection is done via `./build.sh lunch`, which creates a symlink at `.BoardConfig.mk` pointing to a file following the naming convention `BoardConfig-[BOOT_MEDIUM]-[ROOTFS_TYPE]-[HARDWARE_MODEL]-IPC.mk`. For the Pico Ultra W, this will be `BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_Ultra_W-IPC.mk`. All firmware customization flows through the variables exported in this file.

The SDK uses the `arm-rockchip830-linux-uclibcgnueabihf` toolchain — **uclibc, not glibc**. This is the single most important constraint for everything that follows.

---

## 1. Read-Only Root Filesystem

### Choosing SquashFS

Buildroot natively supports SquashFS output. In the Luckfox SDK, enter the Buildroot config with:

```sh
./build.sh buildrootconfig
```

Navigate to `Filesystem images` and select `squashfs root filesystem` with compression algorithm `xz` (best ratio for flash-constrained devices). Ensure the kernel has `CONFIG_SQUASHFS` and `CONFIG_SQUASHFS_XZ` enabled — check via `./build.sh kernelconfig`.

The resulting `rootfs.squashfs` is inherently read-only and highly compressed. The kernel command line (set via `RK_PARTITION_CMD_IN_ENV` in the BoardConfig) must include `rootfstype=squashfs ro`.

### Alternative: Read-Only ext4

If SquashFS's lack of random-access performance is a concern (unlikely at this scale), use ext4 with `ro` mount options. In the BoardConfig, ensure the kernel bootargs include `rootfstype=ext4 ro`. This avoids the SquashFS decompression overhead but sacrifices ~40-60% compression.

### Writable Layers

A read-only root requires writable tmpfs mounts for `/tmp`, `/run`, and `/var/run`. The stock Buildroot BusyBox init handles `/tmp` as tmpfs automatically. For `/var`, you need a bind mount or symlink to the writable data partition (see §2).

**Critical note on /etc:** If you need persistent writes to `/etc` (e.g., `machine-id`), Bootlin documents a proven pattern: an `init_overlay.sh` script set as `init=` on the kernel command line that mounts the data partition and sets up an OverlayFS over `/etc` before `exec`-ing the real `/sbin/init`. This avoids needing an initramfs.

---

## 2. Writable Data Partition

### Partition Layout

The partition table is defined by `RK_PARTITION_CMD_IN_ENV` in the BoardConfig. The stock layout for eMMC models looks like:

```
32K(env),512K@32K(idblock),256K(uboot),32M(boot),512M(oem),256M(userdata),-(rootfs)
```

For a production layout with a dedicated writable data partition, modify this to carve out space explicitly. The `userdata` partition already exists and is a natural home for SQLite databases and mutable config. Resize it as needed:

```
32K(env),512K@32K(idblock),256K(uboot),32M(boot),128M(oem),512M(userdata),-(rootfs)
```

The `userdata` partition is already formatted as ext4 with journaling on eMMC/SD builds and UBIFS on SPI NAND. The SDK's `S20linkmount` init script handles mounting it at `/userdata` on boot.

### Mount Discipline

For production, mount the data partition with `noatime,nosuid,nodev` to minimize write amplification and attack surface. Your SQLite database, config files, and logs live here. Structure it as:

```
/userdata/
├── db/           # SQLite databases
├── config/       # Mutable configuration
├── log/          # Rotating logs
└── lost+found/
```

Symlink `/var/lib` and any other writable paths into `/userdata` via the rootfs overlay (§3).

---

## 3. Rootfs Overlay

The SDK provides a well-documented overlay mechanism. Create a directory under `project/cfg/BoardConfig_IPC/overlay/` mirroring the root filesystem hierarchy, then reference it in the BoardConfig:

```sh
export RK_POST_OVERLAY="overlay-luckfox-config overlay-luckfox-buildroot-init overlay-luckfox-buildroot-shadow catlaser-overlay"
```

Multiple overlay directories are space-separated and applied in order. Create `catlaser-overlay/` with your custom files:

```
project/cfg/BoardConfig_IPC/overlay/catlaser-overlay/
├── etc/
│   ├── init.d/
│   │   ├── S30datapart        # Mount + fsck /userdata
│   │   ├── S40loadmodules     # insmod ISP/NPU/camera .ko files
│   │   ├── S90visiond         # Start the Rust vision daemon
│   │   └── S91behavior        # Start the Python behavior sidecar
│   └── fstab                  # If needed for additional mounts
├── usr/
│   └── bin/
│       ├── catlaser-visiond   # Cross-compiled Rust binary
│       └── catlaser-behavior  # Python entry point / wrapper
└── var/
    └── lib -> /userdata/db    # Symlink for SQLite
```

After modifying overlays, repack the firmware with `./build.sh firmware`. **Do not** run a full `./build.sh` after overlay changes, as this can overwrite custom files in the staging rootfs.

---

## 4. Init System: BusyBox Init (Not systemd)

### The uclibc Constraint

**systemd requires glibc.** The Luckfox SDK's toolchain is uclibc-based, and the Buildroot `BR2_INIT_SYSTEMD` option explicitly `depends on BR2_TOOLCHAIN_USES_GLIBC`. Switching to glibc would require rebuilding the entire toolchain, all Rockchip media/ISP/NPU userspace libraries (which are pre-compiled against uclibc), and is not supported by LuckfoxTECH. **Do not attempt to use systemd with the stock SDK.**

### BusyBox Init Scripts

The stock system uses BusyBox `init`, which reads `/etc/inittab` and runs SysV-style init scripts from `/etc/init.d/`. Scripts are executed in alphanumeric order: `S20linkmount`, `S21appinit`, `S40network`, etc. The `S21appinit` script calls `/oem/usr/bin/RkLunch.sh`, which in turn runs `/oem/usr/ko/insmod_ko.sh` to load all kernel modules.

For production, replace or extend this chain via the overlay. Your init scripts should follow the `S##name` convention where `##` determines boot ordering. Each script receives `start`, `stop`, or `restart` as its first argument.

### Script Template

```sh
#!/bin/sh
# S90visiond - Start catlaser vision daemon

case "$1" in
    start)
        echo "Starting catlaser-visiond..."
        # Wait for device nodes created by module loading
        while [ ! -e /dev/mpp_service ]; do sleep 0.1; done
        start-stop-daemon -S -b -m -p /var/run/visiond.pid \
            -x /usr/bin/catlaser-visiond
        ;;
    stop)
        start-stop-daemon -K -p /var/run/visiond.pid
        ;;
    restart)
        $0 stop; $0 start
        ;;
esac
```

---

## 5. Integrating Custom Rust Binaries

### Cross-Compilation Strategy

The Luckfox SDK's uclibc toolchain is **not a standard Rust target**. There is no upstream `armv7-unknown-linux-uclibceabihf` target in rustup. You have two practical options:

**Option A — Static musl binary (recommended):** Cross-compile the Rust vision daemon as a fully static binary using the `armv7-unknown-linux-musleabihf` target. This produces a standalone executable with zero runtime dependencies on the rootfs libc. Add the target and build:

```sh
rustup target add armv7-unknown-linux-musleabihf
cargo build --release --target armv7-unknown-linux-musleabihf
```

The resulting binary goes into the rootfs overlay at `catlaser-overlay/usr/bin/`. The tradeoff is binary size (static linking), but for a single daemon this is typically under 5-10 MB stripped.

**Note:** If the vision daemon links against Rockchip userspace libraries (librga, librknnrt, librkmpi), it **cannot** be fully static. In that case, use Option B.

**Option B — Dynamic linking against uclibc sysroot:** Create a custom Rust target JSON spec pointing the linker at the SDK's cross-compiler and sysroot:

```sh
# Set in .cargo/config.toml
[target.armv7-unknown-linux-uclibceabihf]
linker = "<SDK>/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf-gcc"
rustflags = ["-C", "link-arg=--sysroot=<SDK>/output/out/sysdrv_out/rootfs_uclibc_rv1106"]
```

You will also need a custom target spec JSON (based on `armv7-unknown-linux-gnueabihf` with the `env` field changed to `"uclibc"`) and build with `-Zbuild-std` on nightly Rust.

### Integration into the Image

Place the final stripped binary in the overlay directory. Do **not** attempt to integrate Rust compilation into the Buildroot package build system for this project — the SDK's forked Buildroot does not include upstream Rust package infrastructure, and adding it requires glibc. Build externally in CI, copy the artifact into the overlay, and run `./build.sh firmware`.

---

## 6. Boot Sequence & Module Loading Order

### Stock Module Loading

The default boot chain is: kernel → BusyBox init → `/etc/init.d/S20linkmount` (mounts partitions) → `S21appinit` → `/oem/usr/bin/RkLunch.sh` → `/oem/usr/ko/insmod_ko.sh`.

The `insmod_ko.sh` script loads modules via `insmod` (not `modprobe` — it is unavailable on the Buildroot image) in a strict dependency order. The observed load order from a running system is:

1. `rk_dvbm.ko` — DV buffer manager
2. `mpp_vcodec.ko` — Media Process Platform video codec
3. `video_rkcif.ko` — Rockchip Camera Interface (CIF) driver
4. `video_rkisp.ko` — Rockchip ISP 3.2 driver
5. `phy_rockchip_csi2_dphy_hw.ko` — MIPI CSI-2 D-PHY hardware
6. `phy_rockchip_csi2_dphy.ko` — MIPI CSI-2 D-PHY logical layer
7. `sc3336.ko` — SC3336 camera sensor driver
8. `rga3.ko` — 2D graphics accelerator
9. `rknpu.ko` — NPU driver (RKNPU v0.9.2+)
10. `rockit.ko` — Rockchip multimedia framework
11. `rve.ko` — Rockchip Video Engine

The ISP and NPU kernel modules are **out-of-tree `.ko` files** built by `./build.sh driver` and placed in `/oem/usr/ko/`. They are not built into the kernel.

### Custom Boot Sequence for Catlaser

Replace the stock `S21appinit` (which starts rkipc and other IPC demo applications) with targeted scripts:

```
S20linkmount       — Stock: mount /oem and /userdata partitions
S30loadmodules     — Custom: load only needed .ko files in order
S40network         — Stock: bring up networking
S90visiond         — Custom: start catlaser-visiond (after modules)
S91behavior        — Custom: start Python behavior sidecar
```

Your `S30loadmodules` script should explicitly insmod only the modules your application needs, in dependency order. For the catlaser project (camera + NPU + video encoding), the minimal set is:

```sh
#!/bin/sh
case "$1" in
    start)
        cd /oem/usr/ko
        insmod rk_dvbm.ko
        insmod mpp_vcodec.ko
        insmod video_rkcif.ko
        insmod video_rkisp.ko
        insmod phy_rockchip_csi2_dphy_hw.ko
        insmod phy_rockchip_csi2_dphy.ko
        insmod sc3336.ko          # Camera sensor
        insmod rga3.ko            # 2D accelerator (for frame scaling)
        insmod rknpu.ko           # NPU for YOLO inference
        insmod rockit.ko          # Multimedia framework
        ;;
    stop)
        # Reverse order removal if needed
        ;;
esac
```

The `S90visiond` script should poll for the existence of `/dev/mpp_service` or check that `/sys/class/misc/rknpu` exists before launching the vision daemon, ensuring the NPU driver is fully initialized.

### Confirming Module Status

After boot, verify with:

```sh
lsmod    # List loaded modules
ls /dev/mpp_service  # MPP device node (video codec)
cat /sys/kernel/debug/rknpu/version  # NPU driver version
```

---

## Build & Flash Workflow Summary

```sh
# 1. Select board
./build.sh lunch   # Choose [6] RV1106_Luckfox_Pico_Ultra_W → EMMC → Buildroot

# 2. Configure Buildroot (squashfs, packages)
./build.sh buildrootconfig

# 3. Configure kernel (squashfs support, module selection)
./build.sh kernelconfig

# 4. Full build
./build.sh

# 5. Place Rust binary and overlay files
cp target/armv7-unknown-linux-musleabihf/release/catlaser-visiond \
   project/cfg/BoardConfig_IPC/overlay/catlaser-overlay/usr/bin/

# 6. Repack firmware (does NOT rebuild, just repackages)
./build.sh firmware

# 7. Flash
./build.sh updateimg  # Generates update.img for SocToolKit
```

---

## Key Constraints & Gotchas

- **systemd is not viable** with the stock uclibc toolchain. Use BusyBox init scripts instead. The BusyBox init pattern (`S##name start|stop`) covers the use case of ordered daemon startup.
- **modprobe is not available** — only `insmod` with manual dependency ordering. The `/oem/usr/ko/insmod_ko.sh` script is the reference for correct load order.
- **Do not run `sudo ./build.sh`** for Buildroot images. Using sudo causes file permission issues that break subsequent builds.
- **After modifying the overlay or Buildroot config, use `./build.sh firmware`** to repackage without a full rebuild. A full `./build.sh` will overwrite files in `output/out/rootfs_uclibc_rv1106`.
- **Kernel module version magic** is strict: `.ko` files must match the exact kernel version (5.10.160 on current SDK). Mixing SDK versions will cause `insmod` to fail with version mismatch errors.
- **CMA memory** is configured via `RK_BOOTARGS_CMA_SIZE` in the BoardConfig (default 66M). If the camera is in use, do not reduce this. If unused, set to `1M` to free RAM.
