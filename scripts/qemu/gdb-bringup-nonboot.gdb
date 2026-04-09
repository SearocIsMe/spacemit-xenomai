set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break bringup_nonboot_cpus
commands
  silent
  printf "\n==== breakpoint: bringup_nonboot_cpus ====\n"
  bt
  x/24i $pc
  continue
end

break smp_cpus_done
commands
  silent
  printf "\n==== breakpoint: smp_cpus_done ====\n"
  bt
  x/24i $pc
  continue
end

continue
