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

break arch_send_call_function_single_ipi
commands
  silent
  printf "\n==== breakpoint: arch_send_call_function_single_ipi cpu=%lu ====\n", $a0
  bt 8
  quit
end

break handle_IPI
commands
  silent
  printf "\n==== breakpoint: handle_IPI irq=%lu cpu=%d ====\n", $a0, *(int *)$tp
  bt 8
  quit
end

disable 2
disable 3

continue
