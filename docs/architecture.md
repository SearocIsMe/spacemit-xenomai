# EVL Dual-Kernel Architecture on SpacemiT K1

## Overview

This document describes the Xenomai 4 / EVL (Eclipse Versatile Linux) dual-kernel architecture as it applies to the SpacemiT K1 RISC-V SoC on the Milk-V Jupiter board.

---

## 1. Dovetail Interrupt Pipeline

EVL's real-time capability is built on **Dovetail**, a lightweight interrupt pipeline that splits interrupt handling into two stages:

```
Hardware Interrupt
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│              Dovetail Interrupt Pipeline                  │
│                                                          │
│  ┌─────────────────────┐    ┌──────────────────────────┐ │
│  │  Stage 0: OOB       │    │  Stage 1: In-band        │ │
│  │  (Out-Of-Band)      │    │  (Normal Linux)          │ │
│  │                     │    │                          │ │
│  │  • EVL handles IRQs │    │  • Linux handles IRQs    │ │
│  │  • Lowest latency   │    │  • Normal scheduling     │ │
│  │  • Never masked by  │    │  • Can be masked by      │ │
│  │    Linux            │    │    local_irq_disable()   │ │
│  └─────────┬───────────┘    └──────────┬───────────────┘ │
│            │  stall/unstall            │                  │
│            └──────────────────────────┘                  │
└──────────────────────────────────────────────────────────┘
```

### Key Concept: Interrupt Stalling

When Linux calls `local_irq_disable()`, Dovetail does **not** actually mask hardware interrupts. Instead, it sets a "stall bit" in the in-band stage. Hardware interrupts still arrive and are handled by the OOB stage (EVL) first. Only after EVL is done does the interrupt get forwarded to the in-band (Linux) stage — but only if the stall bit is clear.

This means **EVL threads are never blocked by Linux's interrupt masking**, which is the fundamental source of EVL's low latency.

---

## 2. RISC-V Dovetail Implementation

On RISC-V, Dovetail hooks into the following kernel paths:

### 2.1 Interrupt Entry (`arch/riscv/kernel/entry.S`)

```
handle_exception:
    ...
    call do_irq          ← standard Linux path
                         ← Dovetail replaces this with pipeline dispatch
```

Dovetail adds an OOB entry stub that:
1. Saves minimal register context
2. Dispatches to EVL's OOB handler if an EVL IRQ domain is registered
3. Falls through to Linux's normal `do_irq` for in-band IRQs

### 2.2 IRQ Controller (`drivers/irqchip/irq-sifive-plic.c`)

The SpacemiT K1 uses a PLIC-compatible interrupt controller. Dovetail requires the PLIC driver to support **IRQ domain splitting** — some IRQ lines are claimed by EVL (OOB domain), others by Linux (in-band domain).

### 2.3 Timer (`drivers/clocksource/timer-riscv.c`)

The RISC-V `mtime`/`mtimecmp` timer is used by both Linux (for `jiffies`) and EVL (for OOB timers). Dovetail intercepts the timer interrupt and:
1. Delivers it to EVL first (for EVL timer expiry)
2. Then forwards to Linux (for `jiffies` update and `hrtimer` processing)

---

## 3. EVL Core Components

### 3.1 EVL Scheduler

The EVL scheduler runs in the OOB stage and manages EVL threads. It is a **fixed-priority preemptive scheduler** with optional extensions:

| Policy | Description | Use Case |
|--------|-------------|----------|
| `SCHED_FIFO` (EVL) | Fixed priority, FIFO within same priority | General RT tasks |
| `SCHED_RR` (EVL) | Fixed priority, round-robin | Multiple equal-priority tasks |
| `SCHED_QUOTA` | CPU quota per group | Preventing RT starvation |
| `SCHED_TP` | Time partitioning | Temporal isolation between tasks |

### 3.2 EVL Clock

EVL maintains its own clock (`evl_clock`) based on the hardware timer. This clock:
- Has nanosecond resolution
- Is monotonic
- Is independent of Linux's `CLOCK_MONOTONIC` (though they track the same hardware)
- Supports per-CPU gravity compensation for timer latency

### 3.3 EVL Thread Lifecycle

```
evl_attach_self()          ← thread registers with EVL core
       │
       ▼
  [OOB stage]              ← thread runs in OOB context
       │
  evl_sleep_until()        ← periodic wait
  evl_wait_event()         ← event wait
       │
       ▼
  [woken by EVL timer/IRQ] ← deterministic wakeup
       │
       ▼
  evl_detach_self()        ← thread unregisters
```

### 3.4 EVL Synchronization Primitives

| Primitive | Description | OOB Safe |
|-----------|-------------|----------|
| `evl_mutex` | Priority-inheritance mutex | Yes |
| `evl_sem` | Counting semaphore | Yes |
| `evl_flag` | Event flag | Yes |
| `evl_rwlock` | Reader-writer lock | Yes |
| `evl_poll` | I/O event polling | Yes |

---

## 4. Memory Architecture

### 4.1 EVL Heap

EVL provides its own memory allocator (`evl_heap`) for OOB-safe dynamic allocation. Standard `kmalloc`/`vmalloc` are **not safe** in OOB context because they may sleep or take spinlocks that interact with the in-band stage.

```
EVL Heap (pre-allocated at boot)
├── EVL thread stacks
├── EVL object descriptors
└── User-allocated OOB buffers (via evl_alloc_chunk)
```

### 4.2 Shared Memory (Cross-Buffer)

The `evl_xbuf` (cross-buffer) primitive provides zero-copy data transfer between OOB threads and in-band (Linux) processes:

```
OOB Thread                    In-band Process
    │                               │
    │  evl_write_xbuf()             │
    ├──────────────────────────────►│
    │                               │  read() on /dev/evl/xbuf0
    │◄──────────────────────────────┤
    │  evl_read_xbuf()              │
```

---

## 5. SpacemiT K1 Specific Considerations

### 5.1 Multi-Core Topology

The K1 has 8 cores. EVL supports SMP and can pin OOB threads to specific CPUs using `evl_set_thread_affinity()`. For lowest latency:
- Dedicate CPU 0 to Linux (housekeeping)
- Pin RT control threads to CPU 1–3
- Leave CPU 4–7 for Linux workloads

### 5.2 Cache Coherency

The K1's cache coherency model is standard RISC-V (RVWMO — RISC-V Weak Memory Ordering). EVL's memory barriers use `smp_mb()` / `smp_rmb()` / `smp_wmb()` which map to RISC-V `fence` instructions. No special handling needed.

### 5.3 RISC-V Vector Extension

The K1 supports RISC-V Vector (V) extension 1.0. **EVL does not currently save/restore Vector register state** for OOB threads. If an OOB thread uses Vector instructions, register corruption will occur.

**Mitigation:** Do not use Vector intrinsics or auto-vectorized code in EVL thread functions. Compile EVL thread code with `-mno-vector` or equivalent.

### 5.4 Power Management Interaction

CPU frequency scaling (DVFS) and C-state transitions can cause latency spikes. During RT operation:
- Disable `cpufreq` scaling: `echo performance > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`
- Disable deep C-states if supported

---

## 6. s-aiotm Capability Mapping

```
s-aiotm Capability          EVL Mechanism
─────────────────────────────────────────────────────────────
01 Protocol Adaptation  →   evl_proxy driver + OOB IRQ handler
                            (CAN, RS-485, custom fieldbus)

03 Real-time Data Bus   →   evl_xbuf (zero-copy ring buffer)
                            + evl_mutex for producer/consumer sync

04 Closed-loop Control  →   evl_thread (1 kHz periodic)
                            + evl_timer for precise wakeup
                            + evl_heap for OOB-safe allocation

08 Task Scheduling      →   EVL SCHED_QUOTA (CPU budget)
                            + EVL SCHED_TP (time partitioning)
                            + evl_set_thread_affinity (CPU pinning)
```
