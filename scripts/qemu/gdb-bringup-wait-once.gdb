set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break *0xffffffff800147ae
commands
  silent
  printf "\n==== breakpoint: bringup_cpu after wait_for_completion ====\n"
  bt 6
  printf "cpu(arg)=%lu\n", $s1
  quit
end

break *0xffffffff800147fc
commands
  silent
  printf "\n==== breakpoint: bringup_cpu cpu_online failed ====\n"
  bt 6
  printf "cpu(arg)=%lu\n", $s1
  quit
end

break cpuhp_online_idle
commands
  silent
  printf "\n==== breakpoint: cpuhp_online_idle state=%lu ====\n", $a0
  bt 6
  continue
end

continue
