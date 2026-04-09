set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

set $cpu_running = (void *)0xffffffff8140f3e0

break complete if $a0 == $cpu_running
commands
  silent
  printf "\n==== breakpoint: complete(cpu_running) ====\n"
  bt 6
  enable 2
  enable 3
  continue
end

break try_to_wake_up
commands
  silent
  printf "\n==== breakpoint: try_to_wake_up after complete(cpu_running) ====\n"
  bt 8
  disable 2
  continue
end

break sched_ttwu_pending
commands
  silent
  printf "\n==== breakpoint: sched_ttwu_pending after cpu_running wake ====\n"
  bt 8
  quit
end

disable 2
disable 3

continue
