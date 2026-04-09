set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break bringup_nonboot_cpus
commands
  silent
  printf "\n==== breakpoint: bringup_nonboot_cpus ====\n"
  bt 4
  printf "__boot_cpu_id = "
  x/wx 0xffffffff81504228
  printf "__cpu_present_mask = "
  x/gx 0xffffffff81504210
  printf "__cpu_online_mask = "
  x/gx 0xffffffff81504218
  printf "arg max_cpus(a0) = 0x%lx\n", $a0
  continue
end

break cpu_up
commands
  silent
  printf "\n==== breakpoint: cpu_up cpu=%lu target=%lu ====\n", $a0, $a1
  printf "__boot_cpu_id = "
  x/wx 0xffffffff81504228
  printf "__cpu_present_mask = "
  x/gx 0xffffffff81504210
  printf "__cpu_online_mask = "
  x/gx 0xffffffff81504218
  bt 3
  continue
end

continue
