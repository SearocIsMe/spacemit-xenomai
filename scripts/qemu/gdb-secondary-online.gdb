set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break riscv_ipi_enable
commands
  silent
  printf "\n==== breakpoint: riscv_ipi_enable ====\n"
  bt
  x/16i $pc
  continue
end

break set_cpu_online
commands
  silent
  printf "\n==== breakpoint: set_cpu_online ====\n"
  bt
  x/16i $pc
  continue
end

continue
