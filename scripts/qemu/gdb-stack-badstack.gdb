set pagination off
set confirm off
set print pretty off
set disassemble-next-line off
target remote :1235

set $tail_hits = 0
set $bad_hits = 0

break irq_pipeline_call_on_irq_stack_tail_sync
commands
  silent
  set $tail_hits = $tail_hits + 1
  printf "\n=== irq_pipeline_call_on_irq_stack_tail_sync hit %d ===\n", $tail_hits
  printf "pc=%p sp=%p tp=%p ra=%p\n", $pc, $sp, $tp, $ra
  bt
  if $tail_hits >= 3
    detach
    quit
  end
  continue
end

break handle_bad_stack
commands
  silent
  set $bad_hits = $bad_hits + 1
  printf "\n=== handle_bad_stack hit %d ===\n", $bad_hits
  printf "pc=%p sp=%p tp=%p ra=%p a0=%p\n", $pc, $sp, $tp, $ra, $a0
  bt
  detach
  quit
end

continue
