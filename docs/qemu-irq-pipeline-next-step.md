# Next Step: QEMU `irq-pipeline-qemu` Validation

## Short Answer

是的，在你已经证明 [`vanilla-k1`](docs/vanilla-first-run.md) 可启动之后，先验证 `QEMU virt` 下的 `irq-pipeline-qemu`，这是正确的下一步。

但建议把执行顺序稍微收紧一下：

1. 先确认 host 侧 `qemu-system-riscv64` 可用
2. 先构建并运行 `vanilla-qemu`，确认 QEMU lane 本身是通的
3. 再构建并运行 `irq-pipeline-qemu`
4. 若出现 early reset，再切到 `QEMU_GDB=1` + GDB 脚本

也就是说，你给出的命令方向是对的，但**最好补一个 `vanilla-qemu` 烟雾测试作为 QEMU lane 自检**。

## Why this is the right next step

你已经确认本地 vendor kernel 注入 Jupiter 没问题，这说明：

- SD image 生成链路不是当前首要矛盾
- 本地构建的基础内核不是立即可疑对象

于是当前最值得回答的问题就变成：

> [`IRQ_PIPELINE`](configs/k1_irq_pipeline_only_defconfig:12) 在 generic RISC-V `virt` 机器上，是否已经能走到可观察的 early boot 阶段？

如果 QEMU 这里都不稳，那么优先修 generic RISC-V pipeline 语义；
如果 QEMU 稳，而 Jupiter 仍挂，那么再回头聚焦 SpacemiT/K1 特有路径。

## What the current runner already supports

从 [`scripts/qemu/run-riscv64-virt.sh`](scripts/qemu/run-riscv64-virt.sh) 看，当前脚本已经具备你需要的关键能力：

- 自动查找 OpenSBI firmware
- 直接加载 built [`Image`](scripts/qemu/run-riscv64-virt.sh:57)
- 通过 `APPEND` 追加 `evl_debug`
- 用 `QEMU_NO_REBOOT=1` 抑制 guest reset 循环
- 用 `QEMU_DEBUG_LOG` 记录 QEMU 内部 reset / guest error 线索
- 用 `QEMU_STDOUT_LOG` 镜像 guest console 输出
- 用 `QEMU_GDB=1` 打开 GDB stub

所以从工具能力看，不需要先改脚本，先跑验证是合理的。

## Recommended command sequence

### 0. Ensure host-side QEMU exists

如果没装过：

```bash
bash scripts/qemu/setup-qemu-riscv64-ubuntu.sh
```

最小检查：

```bash
command -v qemu-system-riscv64
qemu-system-riscv64 --version
```

### 1. Self-check the QEMU lane with `vanilla-qemu`

先确认不是 QEMU lane 本身坏掉：

```bash
bash scripts/build/00b-deploy-overlay.sh

JOBS=$(nproc) MODULE_JOBS=1 \
  bash scripts/build/build-qemu-virt-bisect.sh vanilla-qemu

QEMU_NO_REBOOT=1 \
QEMU_STDOUT_LOG=.build/qemu-virt/vanilla-qemu-output.log \
bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/vanilla
```

判断：

- 如果 `vanilla-qemu` 都起不来，先不要讨论 `irq-pipeline-qemu`
- 如果 `vanilla-qemu` 正常，说明 QEMU lane 是可信的

### 2. Run `irq-pipeline-qemu`

这是你提出的主命令，方向正确：

```bash
bash scripts/build/00b-deploy-overlay.sh

JOBS=$(nproc) MODULE_JOBS=1 \
  bash scripts/build/build-qemu-virt-bisect.sh irq-pipeline-qemu

QEMU_NO_REBOOT=1 \
QEMU_DEBUG_LOG=.build/qemu-virt/irq-pipeline.evl_debug.qemu.log \
QEMU_STDOUT_LOG=.build/qemu-virt/irq-pipeline-qemu-output.log \
APPEND="evl_debug" \
bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/irq-pipeline
```

这组参数的意义：

- `QEMU_NO_REBOOT=1`：避免 reset 后无限重启，保住第一现场
- `QEMU_DEBUG_LOG=...`：抓 QEMU 自身的 reset / guest error 线索
- `QEMU_STDOUT_LOG=...`：保存 guest console，包括 `EVLDBG`
- `APPEND="evl_debug"`：打开你在 [`kernel-overlay/arch/riscv/kernel/traps.c`](kernel-overlay/arch/riscv/kernel/traps.c) 和 [`kernel-overlay/arch/riscv/include/asm/irq_pipeline.h`](kernel-overlay/arch/riscv/include/asm/irq_pipeline.h) 里埋的一次性 debug marker

## What outputs matter most

优先看这两个文件：

- [`irq-pipeline-qemu-output.log`](.build/qemu-virt/irq-pipeline-qemu-output.log)
- [`irq-pipeline.evl_debug.qemu.log`](.build/qemu-virt/irq-pipeline.evl_debug.qemu.log)

你最想看到的 guest 侧 marker，来自 [`docs/qemu-virt.md`](docs/qemu-virt.md:168)：

- `EVLDBG do_irq entry`
- `EVLDBG do_irq pipelined`
- `EVLDBG handle_riscv_irq entry`
- `EVLDBG handle_riscv_irq pipelined`
- `EVLDBG riscv_intc_irq entry`

### Interpretation table

#### Case A — reaches Linux banner / early console cleanly

说明：

- generic RISC-V QEMU lane 基本成立
- Jupiter 挂起更像 K1-specific 问题

#### Case B — prints some `EVLDBG` markers, then reset/panic

说明：

- blocker 很可能在 pipelined IRQ 进入后的 trap/timer/replay 路径
- 下一步该切 GDB，而不是继续盲试更多 image

#### Case C — resets back to OpenSBI before任何 Linux banner

说明：

- 问题非常早
- 很可能在 generic RISC-V bring-up、trap entry、timer 或 early pipeline state

#### Case D — `vanilla-qemu` 正常，`irq-pipeline-qemu` 异常

这是最有价值的结果。

说明：

- 你已经把问题收敛到 generic `IRQ_PIPELINE` 级别
- 接下来就该优先比较：
  - [`kernel-overlay/arch/riscv/include/asm/irqflags.h`](kernel-overlay/arch/riscv/include/asm/irqflags.h)
  - [`kernel-overlay/arch/riscv/include/asm/irq_pipeline.h`](kernel-overlay/arch/riscv/include/asm/irq_pipeline.h)
  - [`kernel-overlay/arch/riscv/kernel/irq_pipeline.c`](kernel-overlay/arch/riscv/kernel/irq_pipeline.c)
  - [`kernel-overlay/arch/riscv/kernel/traps.c`](kernel-overlay/arch/riscv/kernel/traps.c)

## When to switch to GDB

如果 `QEMU_NO_REBOOT=1` 的日志仍不足以定位，就切到 GDB 模式。

### Start QEMU paused

```bash
QEMU_GDB=1 \
QEMU_GDB_PORT=1235 \
QEMU_NO_REBOOT=1 \
QEMU_DEBUG_LOG=.build/qemu-virt/irq-pipeline.gdb.qemu.log \
QEMU_STDOUT_LOG=.build/qemu-virt/irq-pipeline.gdb.output.log \
APPEND="evl_debug" \
bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/irq-pipeline
```

### Then attach GDB

你当前打开的 [`scripts/qemu/gdb-hart0-early-reset.gdb`](scripts/qemu/gdb-hart0-early-reset.gdb) 就是为这种 early reset 场景准备的。

它会追踪这些关键点：

- `handle_irq_pipelined_finish`
- `irq_pipeline_take_deferred_sync`
- `schedule_tail`
- `panic`
- `machine_restart`
- `sbi_srst_reset`

建议命令：

```bash
riscv64-linux-gnu-gdb .build/qemu-virt/irq-pipeline/vmlinux \
  -x scripts/qemu/gdb-hart0-early-reset.gdb
```

注意：[`scripts/qemu/gdb-hart0-early-reset.gdb`](scripts/qemu/gdb-hart0-early-reset.gdb:6) 默认连的是 `:1235`，这和上面的 `QEMU_GDB_PORT=1235` 是匹配的。

## Final recommendation

结论是：

- codex 给出的方向是对的
- 这确实应当成为当前的下一步
- 但最好先补一个 `vanilla-qemu` 自检，再跑 `irq-pipeline-qemu`
- 若 `irq-pipeline-qemu` 失败，下一步不是回到 SD image，而是直接进 GDB 和 early trace 分析

## Approved next-step sequence

按这个顺序执行最稳妥：

```bash
bash scripts/build/00b-deploy-overlay.sh

JOBS=$(nproc) MODULE_JOBS=1 \
  bash scripts/build/build-qemu-virt-bisect.sh vanilla-qemu

QEMU_NO_REBOOT=1 \
QEMU_STDOUT_LOG=.build/qemu-virt/vanilla-qemu-output.log \
bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/vanilla

JOBS=$(nproc) MODULE_JOBS=1 \
  bash scripts/build/build-qemu-virt-bisect.sh irq-pipeline-qemu

QEMU_NO_REBOOT=1 \
QEMU_DEBUG_LOG=.build/qemu-virt/irq-pipeline.evl_debug.qemu.log \
QEMU_STDOUT_LOG=.build/qemu-virt/irq-pipeline-qemu-output.log \
APPEND="evl_debug" \
bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/irq-pipeline
```

如果第二段失败，再立刻切：

```bash
QEMU_GDB=1 \
QEMU_GDB_PORT=1235 \
QEMU_NO_REBOOT=1 \
QEMU_DEBUG_LOG=.build/qemu-virt/irq-pipeline.gdb.qemu.log \
QEMU_STDOUT_LOG=.build/qemu-virt/irq-pipeline.gdb.output.log \
APPEND="evl_debug" \
bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/irq-pipeline
```

另开一个终端：

```bash
riscv64-linux-gnu-gdb .build/qemu-virt/irq-pipeline/vmlinux \
  -x scripts/qemu/gdb-hart0-early-reset.gdb
```

## Current local validation result on this machine

在当前主机上，QEMU lane 还没有进入 guest boot 阶段，先卡在 **QEMU-oriented kernel build**。

### What failed

执行 `vanilla-qemu` 时，构建失败于两个缺失声明：

1. [`kernel-overlay/kernel/sched/core.c`](kernel-overlay/kernel/sched/core.c) 中的 [`irq_pipeline_set_ttwu_window()`](kernel-overlay/kernel/sched/core.c:3890)
2. [`kernel-overlay/arch/riscv/kernel/smpboot.c`](kernel-overlay/arch/riscv/kernel/smpboot.c:262) 中的 [`inband_irq_enable()`](kernel-overlay/arch/riscv/kernel/smpboot.c:262)

这说明当前 overlay 对于 generic QEMU `virt` lane 还不完整：

- `kernel/sched/core.c` 的 EVL/Dovetail 相关调用没有完整头文件可见性
- `arch/riscv/kernel/smpboot.c` 需要配套的 IRQ pipeline 头文件/声明接入，但目前 overlay 没有覆盖到这一点

### Why this matters

这不是 `QEMU` 本身问题，也不是镜像问题，而是：

> 当前内核 overlay 已经足够支持 Jupiter 上的 `vanilla-k1` 路径验证，但还不足以让 generic `QEMU virt` lane 顺利编译完成。

所以现在的下一步不应再直接尝试运行 QEMU，而应先补齐这些 build-time 缺口。

### Immediate next fix targets

优先检查并补齐：

1. [`kernel-overlay/arch/riscv/kernel/smpboot.c`](kernel-overlay/arch/riscv/kernel/smpboot.c)
2. [`kernel-overlay/kernel/sched/core.c`](kernel-overlay/kernel/sched/core.c)
3. 它们所需的头文件可见性，重点围绕：
   - [`kernel-overlay/include/linux/irq_pipeline.h`](kernel-overlay/include/linux/irq_pipeline.h)
   - [`kernel-overlay/include/asm-generic/irq_pipeline.h`](kernel-overlay/include/asm-generic/irq_pipeline.h)
   - [`kernel-overlay/arch/riscv/include/asm/irq_pipeline.h`](kernel-overlay/arch/riscv/include/asm/irq_pipeline.h)

### Updated decision

当前验证结果应解释为：

- QEMU lane 方向仍然正确
- 但在本机上，**第一阻塞点已前移到 generic QEMU build completeness**
- 下一步先修 compile gap，再重跑 `vanilla-qemu`
