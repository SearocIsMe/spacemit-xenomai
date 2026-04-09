set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break smp_init
commands
  silent
  printf "\n==== breakpoint: smp_init ====\n"
  bt
  x/24i $pc
  continue
end

break sched_init_smp
commands
  silent
  printf "\n==== breakpoint: sched_init_smp ====\n"
  bt
  x/24i $pc
  continue
end

continue
