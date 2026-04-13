set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
set logging file .build/qemu-virt/irq-pipeline.workqueue-post-return.gdb.log
set logging overwrite on
set logging enabled on

target remote :1235

set $awr_hits = 0
set $vsn_hits = 0

break *apply_workqueue_attrs_locked+0x4c
commands
  silent
  set $awr_hits = $awr_hits + 1
  printf "\n=== apply_workqueue_attrs_locked return hit %d ===\n", $awr_hits
  printf "pc=%p sp=%p ra=%p tp=%p a0(ret)=%p\n", $pc, $sp, $ra, $tp, $a0
  bt 10
  enable 2
  enable 3
  continue
end

break vsnprintf
commands
  silent
  set $vsn_hits = $vsn_hits + 1
  if $vsn_hits <= 8
    printf "\n=== vsnprintf hit %d ===\n", $vsn_hits
    printf "pc=%p sp=%p ra=%p tp=%p buf=%p size=%p fmt=%p\n", $pc, $sp, $ra, $tp, $a0, $a1, $a2
    x/s $a2
    bt 12
  end
  continue
end

break handle_bad_stack
commands
  silent
  printf "\n=== handle_bad_stack ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p a0=%p\n", $pc, $sp, $ra, $tp, $a0
  bt 16
  detach
  quit
end

disable 2
disable 3

continue
