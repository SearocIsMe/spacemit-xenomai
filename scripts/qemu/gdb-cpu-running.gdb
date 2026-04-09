set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break *0xffffffff800090c8
commands
  silent
  printf "\n==== breakpoint: smp_callin complete(cpu_running) ====\n"
  bt 6
  continue
end

break *0xffffffff80009012 if $s1 == 1
commands
  silent
  printf "\n==== breakpoint: __cpu_up cpu=1 after wait_for_completion_timeout ====\n"
  bt 6
  printf "cpu(s1)=%lu wait_ret(a0)=%ld\n", $s1, $a0
  continue
end

break *0xffffffff80009034 if $s1 == 1
commands
  silent
  printf "\n==== breakpoint: __cpu_up cpu=1 return ====\n"
  bt 6
  printf "cpu(s1)=%lu ret(s2)=%ld\n", $s1, $s2
  quit
end

continue
