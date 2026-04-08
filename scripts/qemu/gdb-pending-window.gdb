set pagination off
set confirm off
set print pretty on
set print elements 0
set disassemble-next-line off
set breakpoint pending on
set arch riscv:rv64
set remotetimeout 60

break schedule_tail
commands
  silent
  printf "\n==== breakpoint: schedule_tail ====\n"
  bt 10
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
  printf "\n==== breakpoint: sync_current_irq_stage ====\n"
  bt 12
  continue
end
