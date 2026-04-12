# First Run: `vanilla-k1` Baseline on Jupiter

## Goal

Before touching `IRQ_PIPELINE`, `DOVETAIL`, or `EVL`, prove one simpler fact:

> a locally built kernel from the same SpacemiT vendor tree can still boot on Jupiter when inserted into a known-good base image.

If this step fails, then the blocker is below EVL and we should stop climbing the stack.

## Expected Directories in This Repository

From the current generated environment in [`scripts/build/env.sh`](scripts/build/env.sh), the important paths are:

- work root: `.build/`
- kernel source: `.build/linux-k1`
- default build root: `.build/build-k1`
- `vanilla-k1` output dir from [`scripts/build/build-kernel-bisect.sh`](scripts/build/build-kernel-bisect.sh): `.build/build-k1-vanilla`
- image output dir: `.build/images`

The `vanilla-k1` mapping comes from [`scripts/build/build-kernel-bisect.sh`](scripts/build/build-kernel-bisect.sh):

```text
vanilla-k1 : configs/k1_vanilla_defconfig : .build/build-k1-vanilla
```

## Preconditions

Make sure these are already true:

1. [`scripts/build/env.sh`](scripts/build/env.sh) exists
2. `.build/linux-k1/` exists
3. the base SD-card image exists locally
4. `kernel-overlay/` has already been deployed to the kernel tree at least once

Recommended base image candidates:

- official Bianbu / SpacemiT Jupiter SD image
- or the image produced by [`scripts/build/04-build-sdk.sh`](scripts/build/04-build-sdk.sh), if you already trust that output more

## Step 1 — Re-deploy the overlay for a clean starting point

Even for `vanilla-k1`, keep the tree state deterministic.

```bash
bash scripts/build/00b-deploy-overlay.sh
```

Reason:

- it ensures the kernel tree matches the repository state
- it avoids chasing stale partial overlay problems later

## Step 2 — Build the local vendor baseline kernel

```bash
JOBS=$(nproc) MODULE_JOBS=1 \
  bash scripts/build/build-kernel-bisect.sh vanilla-k1
```

This uses:

- config fragment [`configs/k1_vanilla_defconfig`](configs/k1_vanilla_defconfig)
- output directory `.build/build-k1-vanilla`

Expected artifacts:

- `.build/build-k1-vanilla/arch/riscv/boot/Image`
- `.build/build-k1-vanilla/arch/riscv/boot/dts/spacemit/k1-x_milkv-jupiter.dtb`
- `.build/build-k1-vanilla/modules_install/lib/modules/<version>/`

## Step 3 — Build the safest boot image first (`kernel-only`)

```bash
bash scripts/flash/make-baseline-sdcard-img.sh \
  <base_image>.img \
  .build/build-k1-vanilla \
  .build/images
```

Expected output shape:

```text
.build/images/evl-sdcard-k1-kernel-only-baseline-YYYYMMDD.img
```

This image:

- preserves the original bootloader
- preserves the original partition layout
- preserves the original rootfs
- preserves the original bootflow
- replaces only `Image` and DTBs

## Step 4 — Flash and test on Jupiter

Use either [`scripts/flash/flash-sdcard.sh`](scripts/flash/flash-sdcard.sh) or raw `dd`.

Example:

```bash
bash scripts/flash/flash-sdcard.sh --image \
  .build/images/evl-sdcard-k1-kernel-only-baseline-YYYYMMDD.img \
  /dev/sdX
```

Board-side evidence to collect:

- UART log from power-on to success or failure
- whether HDMI remains at Bianbu splash, goes black, or reaches login
- whether the failure point differs from the vendor image

## Step 5 — Only if needed, build the next conservative image (`kernel-modules`)

If `kernel-only` fails and the symptom still looks like module ABI mismatch or initramfs/rootfs module loading trouble, try:

```bash
bash scripts/flash/make-kernel-modules-sdcard-img.sh \
  <base_image>.img \
  .build/build-k1-vanilla \
  .build/images
```

This still preserves the base bootflow, but also injects the matching module tree.

## Decision Table

### Case A — `vanilla-k1 + kernel-only` boots

This is the best outcome.

Meaning:

- local kernel build is valid
- image replacement path is valid
- DTB replacement path is valid
- the next stage can move upward to `irq-pipeline-only`

### Case B — `vanilla-k1 + kernel-only` fails, but `vanilla-k1 + kernel-modules` boots

Meaning:

- the image builder is still good
- the main issue was module/rootfs ABI consistency
- future staged tests should prefer `kernel-modules` for this board/rootfs combination

### Case C — both `kernel-only` and `kernel-modules` fail

Meaning:

- stop blaming EVL
- stop blaming Xenomai first
- the problem is lower: local kernel replacement, DTB/kernel mismatch, vendor tree runtime issue, or bootflow assumption gap

In this case, do **not** move to `irq-pipeline-only` yet.

## Exact First-Run Command Sequence

Replace `<base_image>.img` with your actual base image path.

```bash
bash scripts/build/00b-deploy-overlay.sh

JOBS=$(nproc) MODULE_JOBS=1 \
  bash scripts/build/build-kernel-bisect.sh vanilla-k1

bash scripts/flash/make-baseline-sdcard-img.sh \
  <base_image>.img \
  .build/build-k1-vanilla \
  .build/images
```

If the first image fails on board:

```bash
bash scripts/flash/make-kernel-modules-sdcard-img.sh \
  <base_image>.img \
  .build/build-k1-vanilla \
  .build/images
```

## What Comes Immediately After Success

Only after `vanilla-k1` is proven bootable should the next stage be:

```bash
JOBS=$(nproc) MODULE_JOBS=1 \
  bash scripts/build/build-kernel-bisect.sh irq-pipeline-only
```

Then repeat the same image promotion rule:

1. `kernel-only`
2. if needed, `kernel-modules`

That is the narrowest safe next move.
