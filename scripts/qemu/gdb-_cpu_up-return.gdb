set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break _cpu_up
commands
  silent
  printf "\n==== breakpoint: _cpu_up entry cpu=%lu target=%lu ====\n", $a0, $a2
  bt 6
  continue
end

break *0xffffffff8001597a
commands
  silent
  printf "\n==== breakpoint: _cpu_up return ====\n"
  bt 6
  printf "ret(a0)=%ld cpu(s6)=%lu target(s5)=%lu\n", $a0, $s6, $s5
  quit
end

continue
