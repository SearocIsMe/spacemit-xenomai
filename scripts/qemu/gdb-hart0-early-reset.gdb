set pagination off
set confirm off
set print frame-arguments all
set breakpoint pending on

target remote :1235

set $hpf_hits = 0
set $st_hits = 0
set $take_hits = 0

break handle_irq_pipelined_finish
commands
  silent
  set $hpf_hits = $hpf_hits + 1
  if $hpf_hits <= 3
    printf "\n=== handle_irq_pipelined_finish hit %d ===\n", $hpf_hits
    bt 10
    info reg pc sp ra tp a0 a1 a2 a3
  end
  continue
end

break irq_pipeline_take_deferred_sync
commands
  silent
  set $take_hits = $take_hits + 1
  if $take_hits <= 6
    printf "\n=== irq_pipeline_take_deferred_sync hit %d ===\n", $take_hits
    bt 12
    info reg pc sp ra tp
  end
  continue
end

break irq_pipeline_request_deferred_sync
commands
  silent
  printf "\n=== irq_pipeline_request_deferred_sync ===\n"
  bt 12
  info reg pc sp ra tp
  continue
end

break schedule_tail
commands
  silent
  set $st_hits = $st_hits + 1
  if $st_hits <= 5
    printf "\n=== schedule_tail hit %d ===\n", $st_hits
    bt 8
    info reg pc sp ra tp
  end
  continue
end

break do_kernel_restart
commands
  silent
  printf "\n=== do_kernel_restart ===\n"
  bt 20
  info reg pc sp ra tp a0 a1
  continue
end

break sbi_srst_reset
commands
  silent
  printf "\n=== sbi_srst_reset ===\n"
  bt 20
  info reg pc sp ra tp a0 a1
  detach
  quit
end

break machine_restart
commands
  silent
  printf "\n=== machine_restart ===\n"
  bt 20
  info reg pc sp ra tp
  detach
  quit
end

break emergency_restart
commands
  silent
  printf "\n=== emergency_restart ===\n"
  bt 20
  info reg pc sp ra tp
  detach
  quit
end

break panic
commands
  silent
  printf "\n=== panic ===\n"
  bt 20
  info reg pc sp ra tp
  detach
  quit
end

continue
