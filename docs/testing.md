# Testing EVL on Milk-V Jupiter

## Overview

This document describes the procedure for flashing the EVL-enabled kernel to an SD card, booting the Milk-V Jupiter, and running latency tests to verify real-time performance.

> **⚠️ Current Status (2026-04-01):** The SD card image `evl-sdcard-k1-20260331.img`
> boots successfully on Jupiter (Bianbu desktop loads, terminal works), but
> **EVL / Dovetail is NOT present** in this image. The kernel is a plain SpacemiT
> kernel. See [§0 Pre-flight Check](#0-pre-flight-check) and
> `docs/porting-notes.md §8` for the root-cause analysis and required next steps
> before EVL testing is possible.

---

## 0. Pre-flight Check — Is EVL Actually in the Kernel?

Before running any EVL tests, confirm that the running kernel actually has EVL
compiled in. The current image (`evl-sdcard-k1-20260331.img`) does **not** —
this check will tell you immediately.

### 0.1 Connect to Jupiter via SSH (LAN)

```bash
# Find Jupiter's IP address (check your router, or run on Jupiter's terminal)
# Then SSH in from your host PC:
ssh root@<jupiter-ip>
# or, if Bianbu uses a non-root user:
ssh user@<jupiter-ip>
```

### 0.2 Check Whether EVL Is Present

Run these four commands on Jupiter:

```bash
# 1. Any EVL messages at boot?
dmesg | grep -i evl

# 2. EVL sysfs interface present?
ls /sys/devices/virtual/evl/

# 3. Kernel config — was DOVETAIL compiled in?
zcat /proc/config.gz | grep -E "CONFIG_DOVETAIL|CONFIG_EVL|CONFIG_IRQ_PIPELINE"

# 4. Kernel version string
uname -r
```

### 0.3 Interpreting Results

#### ✅ EVL IS present (expected after arch patch is applied and kernel rebuilt):

```
# dmesg | grep -i evl
[    2.345678] EVL: core started, ABI 19
[    2.345679] EVL: enabling out-of-band stage

# ls /sys/devices/virtual/evl/
control  clock  thread  ...

# zcat /proc/config.gz | grep CONFIG_DOVETAIL
CONFIG_DOVETAIL=y
```

→ Proceed to §3 Boot Verification and §5 Latency Testing.

#### ❌ EVL is NOT present (current state as of 2026-04-01):

```
# dmesg | grep -i evl
(no output)

# ls /sys/devices/virtual/evl/
ls: /sys/devices/virtual/evl: No such file or directory

# zcat /proc/config.gz | grep CONFIG_DOVETAIL
# CONFIG_DOVETAIL is not set
```

→ **Stop here.** The RISC-V Dovetail arch hooks are missing from the kernel.
See `docs/porting-notes.md §8` (root-cause) and `§9` (how to obtain the
missing patches). The kernel must be rebuilt before any EVL testing is possible.

---

## 0.4 Quick Diagnostic Script (run on Jupiter via SSH)

```bash
#!/bin/sh
# Paste this into the Jupiter terminal or run via SSH
echo "=== Kernel version ==="
uname -r

echo ""
echo "=== EVL in dmesg ==="
dmesg | grep -i evl || echo "(none)"

echo ""
echo "=== EVL sysfs ==="
ls /sys/devices/virtual/evl/ 2>/dev/null || echo "(not present)"

echo ""
echo "=== Kernel config: Dovetail/EVL ==="
zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_DOVETAIL|CONFIG_EVL|CONFIG_IRQ_PIPELINE" \
  || echo "(config.gz not available)"

echo ""
echo "=== evl tool ==="
which evl 2>/dev/null || echo "(evl not installed)"
```

---

## 1. Hardware Setup

### Required Hardware

| Item | Notes |
|------|-------|
| Milk-V Jupiter board | With SpacemiT K1 SoC |
| MicroSD card | ≥ 16 GB, Class 10 / UHS-I recommended |
| USB-UART adapter | 3.3V, for serial console (115200 8N1) |
| Power supply | 12V/3A barrel jack or USB-C PD |
| Linux host PC | For flashing (WSL2 Ubuntu 22.04 supported) |

### Serial Console Wiring (Jupiter UART0)

```
Jupiter 40-pin header          USB-UART Adapter
─────────────────────          ────────────────
Pin 6  (GND)          ────────  GND
Pin 8  (TX / GPIO14)  ────────  RX
Pin 10 (RX / GPIO15)  ────────  TX
```

Connect with: `minicom -D /dev/ttyUSB0 -b 115200` or `screen /dev/ttyUSB0 115200`

---

## 2. Preparing the SD Card

### 2.1 Get a Base Image

Start with the official SpacemiT / Milk-V Jupiter image to get a working rootfs, then replace only the kernel:

```bash
# Download official Jupiter image (check Milk-V wiki for latest URL)
wget https://milkv.io/images/jupiter/bianbu-latest-jupiter.img.zip
unzip bianbu-latest-jupiter.img.zip
```

### 2.2 Flash Base Image to SD Card

```bash
# Identify SD card (IMPORTANT: verify this is your SD card, not a system disk)
lsblk

# Flash base image (replace /dev/sdX with your SD card)
sudo dd if=bianbu-latest-jupiter.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

### 2.3 Replace Kernel with EVL Build

After flashing the base image, replace the kernel using our flash script:

```bash
bash scripts/flash/flash-sdcard.sh /dev/sdX ~/work/build-k1
```

This script:
1. Mounts the boot partition (`/dev/sdX1`)
2. Replaces `Image` with the EVL kernel
3. Copies updated DTBs
4. Optionally installs kernel modules to rootfs

---

## 3. Boot Verification

### 3.1 First Boot

Insert the SD card into Jupiter and power on. Connect to serial console and observe boot messages:

```
U-Boot ...
Loading kernel from SD...
Starting kernel ...

[    0.000000] Linux version 6.6.63-evl+ (...)
[    0.000000] RISC-V: RV64IMAFDC
...
[    X.XXXXXX] EVL: core started, ABI 19
[    X.XXXXXX] EVL: enabling out-of-band stage
```

The key line to look for is `EVL: core started` — this confirms EVL loaded successfully.

### 3.2 Verify EVL from Shell

```bash
# Check EVL kernel messages
dmesg | grep -i evl

# Check EVL sysfs interface
ls /sys/devices/virtual/evl/

# Check EVL version
cat /sys/devices/virtual/evl/control/version

# Run EVL built-in self-check
evl check
```

Expected `evl check` output:
```
== Testing clock...
== Testing heap...
== Testing mutex...
== Testing semaphore...
== Testing flag...
== Testing poll...
All tests passed.
```

---

## 4. Installing libevl on Target

> **Prerequisite:** EVL must be present in the kernel (§0 pre-flight check must
> pass) before libevl is useful on the target.

Cross-compile libevl on the host and copy to the target via SSH (preferred,
since Jupiter is on the LAN):

```bash
# On WSL2/Linux host — build libevl for RISC-V
cd ~/work/libevl
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- \
     DESTDIR=~/work/libevl-install \
     prefix=/usr \
     install

# Copy to Jupiter via SSH (get Jupiter IP from your router or 'ip addr' on Jupiter)
scp -r ~/work/libevl-install/usr root@<jupiter-ip>:/

# Verify on Jupiter
ssh root@<jupiter-ip> "evl check"
```

### 4.1 SSH Workflow for Iterative Testing

Since Jupiter is on the LAN, all test commands can be run remotely without
needing HDMI or serial console:

```bash
JUPITER=root@<jupiter-ip>

# Check EVL status remotely
ssh $JUPITER "dmesg | grep -i evl"

# Run latmus and capture results locally
ssh $JUPITER "evl run latmus -T 60 -c 1" | tee latency-$(date +%Y%m%d-%H%M).txt

# Copy a new test binary to Jupiter
scp ~/work/my-test $JUPITER:/tmp/
ssh $JUPITER "/tmp/my-test"

# Sync the entire libevl install tree (faster than scp for many files)
rsync -avz ~/work/libevl-install/usr/ $JUPITER:/usr/

# Collect full diagnostic info
ssh $JUPITER "uname -r; zcat /proc/config.gz | grep -E 'DOVETAIL|EVL|IRQ_PIPELINE'"
```

### 4.2 Alternative: Mount rootfs Partition Directly

If SSH is not available (e.g. before first boot), mount the SD card rootfs:

```bash
sudo mount /dev/sdX2 /mnt/rootfs
sudo cp -r ~/work/libevl-install/usr/* /mnt/rootfs/usr/
sudo umount /mnt/rootfs
```

---

## 5. Latency Testing

### 5.1 latmus — EVL Latency Measurement Tool

`latmus` is the primary EVL latency measurement tool, included with libevl.

#### Timer Latency Test (OOB timer wakeup)

```bash
# Run for 60 seconds, 1000 Hz, on CPU 1
evl run latmus -T 60 -c 1

# Expected output format:
# RTT|  00:00:01  (1000 us period, 1 thread, priority 98)
# RTH|----lat min|----lat avg|----lat max|-overrun|---msw|---lat best|--lat worst
# RTD|      1.234|      2.456|      8.901|       0|     0|      1.234|      8.901
# ...
# RTS|      1.100|      2.300|     12.500|       0|     0|      1.100|     12.500
```

#### IRQ Latency Test (hardware interrupt to OOB handler)

```bash
# Requires a GPIO loopback or timer-based IRQ injection
evl run latmus -I -T 60 -c 1
```

### 5.2 Interpreting Results

| Metric | Description | Target (Jupiter) |
|--------|-------------|-----------------|
| `lat min` | Minimum wakeup latency | < 5 µs |
| `lat avg` | Average wakeup latency | < 15 µs |
| `lat max` | Maximum wakeup latency | < 50 µs (initial) |
| `overrun` | Missed deadlines | 0 |
| `msw` | Mode switches (OOB→in-band) | 0 during test |

### 5.3 Stress Testing

Run latmus under system load to find worst-case latency:

```bash
# Terminal 1: Run latmus
evl run latmus -T 300 -c 1 -o /tmp/latency-results.txt

# Terminal 2: Generate system load
stress-ng --cpu 7 --io 4 --vm 2 --vm-bytes 512M &
# Also run network traffic, disk I/O, etc.

# After test, check results
cat /tmp/latency-results.txt
```

### 5.4 Cyclictest Comparison (PREEMPT_RT baseline)

For comparison, if testing a PREEMPT_RT kernel:

```bash
cyclictest -p 98 -t 1 -n -i 1000 -l 100000 -q
```

---

## 6. Troubleshooting Boot Issues

### EVL not starting

```bash
dmesg | grep -i "evl\|dovetail\|pipeline"
```

Common causes:
- `CONFIG_DOVETAIL` not set → rebuild with `02-configure.sh`
- Patch not applied → re-run `01-apply-patches.sh`
- FPU context issue → check for `BUG` or `OOPS` in dmesg

### Kernel panic on boot

```bash
# Check last lines before panic in serial console
# Common causes:
# 1. DTB mismatch — ensure correct DTB is loaded
# 2. Module loading failure — check /etc/modules
# 3. Dovetail IRQ routing issue — check irq_pipeline messages
```

### High latency (> 100 µs)

Possible causes and fixes:

| Cause | Fix |
|-------|-----|
| CPU frequency scaling | `echo performance > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` |
| IRQ affinity | `echo 1 > /proc/irq/<N>/smp_affinity` (move IRQs off RT CPU) |
| Memory pressure | Increase available RAM, reduce background processes |
| Thermal throttling | Ensure adequate cooling on Jupiter |
| `CONFIG_HZ` too low | Rebuild with `CONFIG_HZ_1000=y` |

---

## 7. Recording and Reporting Results

### 7.1 Collect System Information

```bash
# Save to file for reporting
{
  echo "=== System Info ==="
  uname -a
  cat /proc/cpuinfo | grep -E "model|hart|isa"
  echo ""
  echo "=== EVL Version ==="
  cat /sys/devices/virtual/evl/control/version
  echo ""
  echo "=== Kernel Config (EVL options) ==="
  zcat /proc/config.gz | grep -E "CONFIG_EVL|CONFIG_DOVETAIL|CONFIG_HZ|CONFIG_PREEMPT"
} > system-info.txt
```

### 7.2 Latency Test Report Template

```
Date       : YYYY-MM-DD
Board      : Milk-V Jupiter
SoC        : SpacemiT K1
Kernel     : linux-6.6.63-evl+
EVL ABI    : 19
Test tool  : latmus
Duration   : 300s
Load       : stress-ng (7 CPU + 4 IO + 2 VM)

Results:
  lat min  : X.XXX µs
  lat avg  : X.XXX µs
  lat max  : XX.XXX µs
  overruns : 0
  msw      : 0
```

Update `docs/porting-notes.md` progress log with test results.
