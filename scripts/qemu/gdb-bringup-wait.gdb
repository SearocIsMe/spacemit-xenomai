set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break bringup_cpu
commands
  silent
  printf "\n==== breakpoint: bringup_cpu cpu=%lu ====\n", $a0
  bt 5
  continue
end

break *0xffffffff800147ae
commands
  silent
  printf "\n==== breakpoint: bringup_cpu after wait_for_completion ====\n"
  bt 5
  printf "cpu(arg)=%lu\n", $s1
  continue
end

break *0xffffffff800147d2
commands
  silent
  printf "\n==== breakpoint: bringup_cpu cpu_online passed ====\n"
  bt 5
  printf "cpu(arg)=%lu target=%d\n", $s1, *(int *)($s6 + 4)
  continue
end

break *0xffffffff800147fc
commands
  silent
  printf "\n==== breakpoint: bringup_cpu cpu_online failed ====\n"
  bt 5
  printf "cpu(arg)=%lu\n", $s1
  continue
end

break cpuhp_online_idle
commands
  silent
  printf "\n==== breakpoint: cpuhp_online_idle state=%lu ====\n", $a0
  bt 5
  continue
end

continue
