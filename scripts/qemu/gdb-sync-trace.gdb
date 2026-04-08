set pagination off
set confirm off
set print pretty on
set print elements 0
set disassemble-next-line off
set breakpoint pending on
set arch riscv:rv64
set remotetimeout 60
target remote :1235

set $sched_hits = 0
set $sync_hits = 0

break schedule_tail
commands
  silent
  set $sched_hits = $sched_hits + 1
  if $sched_hits <= 4
    printf "\n==== breakpoint: schedule_tail (%d) ====\n", $sched_hits
    bt 10
  end
  continue
end

break kernel_init
commands
  silent
  printf "\n==== breakpoint: kernel_init ====\n"
  bt 10
  continue
end

break sync_current_irq_stage
commands
  silent
  set $sync_hits = $sync_hits + 1
  if $sync_hits <= 3
    printf "\n==== breakpoint: sync_current_irq_stage (%d) ====\n", $sync_hits
    bt 12
  end
  continue
end

continue
