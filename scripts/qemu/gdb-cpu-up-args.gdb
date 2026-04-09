set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break cpu_up
commands
  silent
  printf "\n==== breakpoint: cpu_up cpu=%lu target=%lu ====\n", $a0, $a1
  bt 3
  continue
end

break set_cpu_online
commands
  silent
  printf "\n==== breakpoint: set_cpu_online cpu=%lu on=%lu ====\n", $a0, $a1
  bt 3
  continue
end

continue
