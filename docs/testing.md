# Testing EVL on Milk-V Jupiter

## Overview

This document describes the procedure for flashing the EVL-enabled kernel to an SD card, booting the Milk-V Jupiter, and running latency tests to verify real-time performance.

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

Cross-compile libevl on the host and copy to the target:

```bash
# On WSL2 host (in ~/work/libevl)
cd ~/work/libevl
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- \
     DESTDIR=~/work/libevl-install \
     prefix=/usr \
     install

# Copy to target (via SSH or SD card rootfs mount)
scp -r ~/work/libevl-install/usr root@<jupiter-ip>:/
```

Or mount the rootfs partition and copy directly:
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
