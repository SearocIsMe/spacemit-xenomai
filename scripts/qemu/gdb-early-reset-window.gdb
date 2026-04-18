set debuginfod enabled off
set pagination off
set confirm off
set breakpoint pending on
set arch riscv:rv64
target remote :1235

set $armed = 0
set $hits = 0

hbreak cpuhp_thread_fun if $a0 == 2
commands
  silent
  set $armed = 1
  printf "\n==== cpuhp_thread_fun cpu=2 pc=%p ====\n", $pc
  bt 8
  continue
end

hbreak schedule_tail if $armed
commands
  silent
  set $hits = $hits + 1
  printf "\n==== schedule_tail after cpu2 hit=%d pc=%p ====\n", $hits, $pc
  bt 8
  if $hits >= 8
    quit
  end
  continue
end

hbreak sync_current_irq_stage if $armed
commands
  silent
  set $hits = $hits + 1
  printf "\n==== sync_current_irq_stage after cpu2 hit=%d pc=%p ====\n", $hits, $pc
  bt 10
  if $hits >= 8
    quit
  end
  continue
end

hbreak handle_irq_pipelined_finish if $armed
commands
  silent
  set $hits = $hits + 1
  printf "\n==== handle_irq_pipelined_finish after cpu2 hit=%d pc=%p ====\n", $hits, $pc
  bt 10
  if $hits >= 8
    quit
  end
  continue
end

continue
