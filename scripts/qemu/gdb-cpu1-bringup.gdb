set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break bringup_cpu if $a0 == 1
commands
  silent
  printf "\n==== breakpoint: bringup_cpu cpu=1 ====\n"
  bt 6
  continue
end

break *0xffffffff80014776 if $s1 == 1
commands
  silent
  printf "\n==== breakpoint: bringup_cpu cpu=1 after __cpu_up ret ====\n"
  bt 6
  printf "__cpu_up ret(a0)=%ld cpu(s1)=%lu\n", $a0, $s1
  quit
end

break _cpu_up if $a0 == 1
commands
  silent
  printf "\n==== breakpoint: _cpu_up cpu=1 entry target=%lu ====\n", $a2
  bt 6
  continue
end

break *0xffffffff8001597a if $s6 == 1
commands
  silent
  printf "\n==== breakpoint: _cpu_up cpu=1 return ====\n"
  bt 6
  printf "ret(a0)=%ld cpu(s6)=%lu target(s5)=%lu\n", $a0, $s6, $s5
  quit
end

continue
