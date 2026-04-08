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
set $syncpipe_hits = 0
set $syncinband_hits = 0

break sync_inband_irqs
commands
  silent
  set $syncinband_hits = $syncinband_hits + 1
  if $syncinband_hits <= 4
    printf "\n==== breakpoint: sync_inband_irqs (%d) ====\n", $syncinband_hits
    bt 12
  end
  continue
end

break synchronize_pipeline
commands
  silent
  set $syncpipe_hits = $syncpipe_hits + 1
  if $syncpipe_hits <= 6
    printf "\n==== breakpoint: synchronize_pipeline (%d) ====\n", $syncpipe_hits
    bt 12
  end
  continue
end

break sync_current_irq_stage
commands
  silent
  set $sync_hits = $sync_hits + 1
  if $sync_hits <= 6
    printf "\n==== breakpoint: sync_current_irq_stage (%d) ====\n", $sync_hits
    bt 12
  end
  if $sync_hits == 6
    quit
  end
  continue
end

continue
