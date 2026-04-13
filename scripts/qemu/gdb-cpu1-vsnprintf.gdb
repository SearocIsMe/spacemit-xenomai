set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
set logging file .build/qemu-virt/irq-pipeline.cpu1-vsnprintf.gdb.log
set logging overwrite on
set logging enabled on

target remote :1235

set $ttwu_hits = 0
set $vsn_hits = 0
set $init_current = 0xffffffff8140dac0

break sched_ttwu_pending
commands
  silent
  set $ttwu_hits = $ttwu_hits + 1
  printf "\n=== sched_ttwu_pending hit %d ===\n", $ttwu_hits
  printf "pc=%p sp=%p ra=%p tp=%p thread=%d\n", $pc, $sp, $ra, $tp, $_thread
  bt 12
  continue
end

break vsnprintf
commands
  silent
  if $ttwu_hits > 0 && $tp != $init_current
    set $vsn_hits = $vsn_hits + 1
    if $vsn_hits <= 20
      printf "\n=== secondary vsnprintf hit %d ===\n", $vsn_hits
      printf "pc=%p sp=%p ra=%p tp=%p buf=%p size=%p fmt=%p thread=%d\n", $pc, $sp, $ra, $tp, $a0, $a1, $a2, $_thread
      x/s $a2
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
