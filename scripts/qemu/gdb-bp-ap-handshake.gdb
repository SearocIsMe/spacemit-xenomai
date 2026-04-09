set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break cpuhp_bp_sync_alive
commands
  silent
  printf "\n==== breakpoint: cpuhp_bp_sync_alive cpu=%lu ====\n", $a0
  bt 5
  continue
end

break bringup_wait_for_ap_online
commands
  silent
  printf "\n==== breakpoint: bringup_wait_for_ap_online cpu=%lu ====\n", $a0
  bt 5
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
