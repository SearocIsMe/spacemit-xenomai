set pagination off
set confirm off
set print pretty on
set print elements 0
set disassemble-next-line off
set breakpoint pending on
set arch riscv:rv64
set remotetimeout 60
target remote :1235

set $sync_hits = 0

break sync_current_irq_stage
commands
  silent
  set $sync_hits = $sync_hits + 1
  if $sync_hits <= 3
    printf "\n==== breakpoint: sync_current_irq_stage (%d) ====\n", $sync_hits
    bt 12
  end
  if $sync_hits == 3
    quit
  end
  continue
end

continue
