set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
set logging file .build/qemu-virt/irq-pipeline.cpu1-rcu-softirq.gdb.log
set logging overwrite on
set logging enabled on

target remote :1235

set $ttwu_hits = 0
set $rcu_hits = 0
set $softirq_hits = 0
set $init_current = 0xffffffff8140dac0

break sched_ttwu_pending
commands
  silent
  set $ttwu_hits = $ttwu_hits + 1
  printf "\n=== sched_ttwu_pending hit %d ===\n", $ttwu_hits
  printf "pc=%p sp=%p ra=%p tp=%p thread=%d\n", $pc, $sp, $ra, $tp, $_thread
  bt 10
  continue
end

break invoke_rcu_core
commands
  silent
  if $ttwu_hits > 0 && $tp != $init_current
    set $rcu_hits = $rcu_hits + 1
    if $rcu_hits <= 24
      printf "\n=== secondary invoke_rcu_core hit %d ===\n", $rcu_hits
      printf "pc=%p sp=%p ra=%p tp=%p thread=%d\n", $pc, $sp, $ra, $tp, $_thread
      x/8gx $sp
      bt 10
    end
  end
  continue
end

break raise_softirq
commands
  silent
  if $ttwu_hits > 0 && $tp != $init_current
    set $softirq_hits = $softirq_hits + 1
    if $softirq_hits <= 24
      printf "\n=== secondary raise_softirq hit %d ===\n", $softirq_hits
      printf "pc=%p sp=%p ra=%p tp=%p nr=%p thread=%d\n", $pc, $sp, $ra, $tp, $a0, $_thread
      x/8gx $sp
      bt 12
    end
  end
  continue
end

break handle_bad_stack
commands
  silent
  printf "\n=== handle_bad_stack ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p regs=%p thread=%d\n", $pc, $sp, $ra, $tp, $a0, $_thread
  x/12gx $a0
  bt 20
  x/12i $ra-16
  detach
  quit
end

continue
