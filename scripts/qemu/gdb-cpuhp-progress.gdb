set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break _cpu_up
commands
  silent
  printf "\n==== breakpoint: _cpu_up cpu=%lu frozen=%lu target=%lu ====\n", $a0, $a1, $a2
  bt 4
  continue
end

break cpuhp_kick_ap
commands
  silent
  printf "\n==== breakpoint: cpuhp_kick_ap cpu=%lu target=%lu ====\n", $a0, $a2
  bt 4
  continue
end

break cpuhp_online_idle
commands
  silent
  printf "\n==== breakpoint: cpuhp_online_idle state=%lu ====\n", $a0
  bt 4
  continue
end

continue
