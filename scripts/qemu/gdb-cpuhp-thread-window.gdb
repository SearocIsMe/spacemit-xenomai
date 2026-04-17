set debuginfod enabled off
set pagination off
set confirm off
set breakpoint pending off
set arch riscv:rv64
target remote :1235

hbreak smpboot_thread_fn if (*(unsigned int *)$a0) == 1 || (*(unsigned int *)$a0) == 3
commands
  silent
  printf "\n==== smpboot_thread_fn cpu=%u status=%u pc=%p ====\n", *(unsigned int *)$a0, *(unsigned int *)($a0 + 4), $pc
  bt 6
  continue
end

hbreak cpuhp_thread_fun if $a0 == 1 || $a0 == 3
commands
  silent
  printf "\n==== cpuhp_thread_fun cpu=%lu pc=%p ====\n", $a0, $pc
  bt 6
  continue
end

continue
