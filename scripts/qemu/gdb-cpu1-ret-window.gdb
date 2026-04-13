set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
set logging file .build/qemu-virt/irq-pipeline.cpu1-ret-window.gdb.log
set logging overwrite on
set logging enabled on

target remote :1235

set $ttwu_hits = 0
set $ret_hits = 0
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

break ret_from_exception
commands
  silent
  if $ttwu_hits > 0 && $tp != $init_current
    set $ret_hits = $ret_hits + 1
    if $ret_hits <= 24
      printf "\n=== secondary ret_from_exception hit %d ===\n", $ret_hits
      printf "pc=%p sp=%p ra=%p tp=%p regs=%p thread=%d\n", $pc, $sp, $ra, $tp, $sp, $_thread
      x/6gx $sp
      printf "saved_epc=%p saved_ra=%p saved_sp=%p saved_tp=%p\n", *(void**)$sp, *(void**)($sp+8), *(void**)($sp+16), *(void**)($sp+32)
      printf "saved_status=%p saved_badaddr=%p saved_cause=%p\n", *(void**)($sp+256), *(void**)($sp+264), *(void**)($sp+272)
      bt 8
    end
  end
  continue
end

break handle_kernel_stack_overflow
commands
  silent
  printf "\n=== handle_kernel_stack_overflow ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p thread=%d\n", $pc, $sp, $ra, $tp, $_thread
  bt 16
  x/12i $pc-8
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
