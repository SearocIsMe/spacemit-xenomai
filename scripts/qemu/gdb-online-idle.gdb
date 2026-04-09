set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break __cpu_up
commands
  silent
  printf "\n==== breakpoint: __cpu_up cpu=%lu idle=0x%lx ====\n", $a0, $a1
  bt 4
  x/20i $pc
  continue
end

break cpuhp_online_idle
commands
  silent
  printf "\n==== breakpoint: cpuhp_online_idle state=%lu ====\n", $a0
  bt 4
  x/20i $pc
  continue
end

continue
