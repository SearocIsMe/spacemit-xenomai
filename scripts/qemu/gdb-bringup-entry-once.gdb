set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break bringup_cpu
commands
  silent
  printf "\n==== breakpoint: bringup_cpu cpu=%lu ====\n", $a0
  bt 6
  quit
end

continue
