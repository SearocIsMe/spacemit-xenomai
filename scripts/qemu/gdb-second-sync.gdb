set pagination off
set confirm off
set print pretty on
set print elements 0
set disassemble-next-line off
set breakpoint pending on
set arch riscv:rv64
set remotetimeout 60
target remote :1235

break sync_current_irq_stage
ignore 1 1
commands
  silent
  printf "\n==== breakpoint: sync_current_irq_stage (2nd hit) ====\n"
  bt 12
  quit
end

continue
