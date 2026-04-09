set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break smp_callin
commands
  silent
  printf "\n==== breakpoint: smp_callin ====\n"
  bt
  x/24i $pc
  continue
end

break notify_cpu_starting
commands
  silent
  printf "\n==== breakpoint: notify_cpu_starting ====\n"
  bt
  x/24i $pc
  continue
end

break __cpuhp_invoke_callback_range
commands
  silent
  printf "\n==== breakpoint: __cpuhp_invoke_callback_range ====\n"
  bt
  x/24i $pc
  continue
end

continue
