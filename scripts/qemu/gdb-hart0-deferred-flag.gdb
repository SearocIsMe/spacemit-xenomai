set pagination off
set confirm off
set print frame-arguments all
set breakpoint pending on

target remote :1235

define dump_deferred_slots
  printf "deferred_sync_request slots:"
  x/1bx 0xffffffff80c1d848
  x/1bx 0xffffffff80c1d948
  x/1bx 0xffffffff80c1da48
  x/1bx 0xffffffff80c1db48
end

break irq_pipeline_request_deferred_sync
commands
  silent
  printf "\n=== irq_pipeline_request_deferred_sync ===\n"
  bt 12
  info reg pc sp ra tp
  dump_deferred_slots
  continue
end

break irq_pipeline_take_deferred_sync
commands
  silent
  printf "\n=== irq_pipeline_take_deferred_sync ===\n"
  bt 10
  info reg pc sp ra tp
  dump_deferred_slots
  continue
end

break handle_irq_pipelined_finish
commands
  silent
  printf "\n=== handle_irq_pipelined_finish ===\n"
  bt 10
  info reg pc sp ra tp
  dump_deferred_slots
  continue
end

continue
