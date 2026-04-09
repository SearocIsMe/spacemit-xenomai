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
  enable 4
  continue
end

break handle_IPI
commands
  silent
  printf "\n==== breakpoint: handle_IPI irq=%lu ====\n", $a0
  bt 8
  quit
end

break generic_smp_call_function_single_interrupt
commands
  silent
  printf "\n==== breakpoint: generic_smp_call_function_single_interrupt ====\n"
  bt 8
  quit
end

break sched_ttwu_pending
commands
  silent
  printf "\n==== breakpoint: sched_ttwu_pending ====\n"
  bt 8
  quit
end

disable 2
disable 3
disable 4

continue
