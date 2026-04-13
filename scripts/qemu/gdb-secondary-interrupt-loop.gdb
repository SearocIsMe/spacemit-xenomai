set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
set logging file .build/qemu-virt/irq-pipeline.secondary-interrupt-loop.gdb.log
set logging overwrite on
set logging enabled on

target remote :1235

set $ttwu_hits = 0
set $irq_hits = 0
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

break do_irq
commands
  silent
  if $ttwu_hits > 0 && $tp != $init_current
    set $irq_hits = $irq_hits + 1
    if $irq_hits <= 24
      printf "\n=== secondary do_irq hit %d ===\n", $irq_hits
      printf "pc=%p sp=%p ra=%p tp=%p regs=%p thread=%d\n", $pc, $sp, $ra, $tp, $a0, $_thread
      printf "saved_epc=%p saved_ra=%p saved_sp=%p saved_tp=%p\n", *(void**)$a0, *(void**)($a0+8), *(void**)($a0+16), *(void**)($a0+32)
      printf "saved_status=%p saved_badaddr=%p saved_cause=%p\n", *(void**)($a0+256), *(void**)($a0+264), *(void**)($a0+272)
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
