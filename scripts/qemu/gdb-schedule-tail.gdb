set pagination off
set confirm off
set print pretty on
set print elements 0
set disassemble-next-line off
set breakpoint pending on
set arch riscv:rv64
set remotetimeout 60

break handle_oob_irq
commands
  silent
  printf "\n==== breakpoint: handle_oob_irq ====\n"
  bt 10
  continue
end

break handle_irq_pipelined_finish
commands
  silent
  printf "\n==== breakpoint: handle_irq_pipelined_finish ====\n"
  bt 10
  continue
end

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
