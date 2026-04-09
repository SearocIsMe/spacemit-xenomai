set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

set $cpu_running = (void *)0xffffffff8140f3e0

break wait_for_completion_timeout if $a0 == $cpu_running
commands
  silent
  printf "\n==== breakpoint: wait_for_completion_timeout(cpu_running) ====\n"
  bt 6
  x/8gx $a0
  continue
end

break complete if $a0 == $cpu_running
commands
  silent
  printf "\n==== breakpoint: complete(cpu_running) ====\n"
  bt 6
  x/8gx $a0
  continue
end

continue
