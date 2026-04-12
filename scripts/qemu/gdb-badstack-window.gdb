set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break sched_ttwu_pending
commands
  silent
  printf "\n==== breakpoint: sched_ttwu_pending ====\n"
  printf "pc=%p sp=%p tp=%p ra=%p\n", $pc, $sp, $tp, $ra
  bt 12
  enable 2
  continue
end

break handle_bad_stack
commands
  silent
  printf "\n==== breakpoint: handle_bad_stack ====\n"
  printf "pc=%p sp=%p tp=%p ra=%p a0=%p\n", $pc, $sp, $tp, $ra, $a0
  bt 16
  detach
  quit
end

disable 2

continue
