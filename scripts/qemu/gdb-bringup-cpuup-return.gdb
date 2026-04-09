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
  continue
end

break *0xffffffff80014776
commands
  silent
  printf "\n==== breakpoint: bringup_cpu after __cpu_up ret ====\n"
  bt 6
  printf "__cpu_up ret(a0)=%ld cpu(s1)=%lu\n", $a0, $s1
  quit
end

continue
