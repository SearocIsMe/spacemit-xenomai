set pagination off
set confirm off
set print frame-arguments all
set breakpoint pending on

target remote :1235

set $hpf_hits = 0
set $st_hits = 0
set $take_hits = 0
set $inline_req_hits = 0
set $post_hirq_hits = 0
set $post_doirq_hits = 0
set $ret_exc_hits = 0
set $irqexit_hits = 0
set $irqexit_ret_hits = 0
set $irqstack_restore_hits = 0
set $irqstack_tailret_hits = 0
set $irqstack_ret_hits = 0

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

break *0xffffffff800780ca
commands
  silent
  set $inline_req_hits = $inline_req_hits + 1
  printf "\n=== inline deferred_sync_request set hit %d ===\n", $inline_req_hits
  bt 12
  info reg pc sp ra tp a0 a1 a5
  continue
end

break *0xffffffff80077e46
commands
  silent
  printf "\n=== handle_irq_pipelined_finish out path ===\n"
  bt 12
  info reg pc sp ra tp a0 a5
  continue
end

break *0xffffffff808e6be0
commands
  silent
  set $post_hirq_hits = $post_hirq_hits + 1
  if $post_hirq_hits <= 4
    printf "\n=== handle_riscv_irq return site hit %d ===\n", $post_hirq_hits
    bt 12
    info reg pc sp ra tp a0 a1
  end
  continue
end

break *0xffffffff808f0ea2
commands
  silent
  set $irqstack_restore_hits = $irqstack_restore_hits + 1
  if $irqstack_restore_hits <= 4
    printf "\n=== call_on_irq_stack restore-sp hit %d ===\n", $irqstack_restore_hits
    bt 12
    info reg pc sp ra tp a0 a1 s0
  end
  continue
end

break *0xffffffff808f0eb0
commands
  silent
  set $irqstack_tailret_hits = $irqstack_tailret_hits + 1
  if $irqstack_tailret_hits <= 4
    printf "\n=== call_on_irq_stack after tail-sync hit %d ===\n", $irqstack_tailret_hits
    bt 12
    info reg pc sp ra tp a0 a1
  end
  continue
end

break *0xffffffff808f0eb4
commands
  silent
  set $irqstack_ret_hits = $irqstack_ret_hits + 1
  if $irqstack_ret_hits <= 4
    printf "\n=== call_on_irq_stack final ret hit %d ===\n", $irqstack_ret_hits
    bt 12
    info reg pc sp ra tp a0 a1
  end
  continue
end

break *0xffffffff808e779e
commands
  silent
  set $post_doirq_hits = $post_doirq_hits + 1
  if $post_doirq_hits <= 4
    printf "\n=== do_irq post-handler site hit %d ===\n", $post_doirq_hits
    bt 12
    info reg pc sp ra tp a0 a1
  end
  continue
end

break *0xffffffff808e7c0a
commands
  silent
  set $irqexit_hits = $irqexit_hits + 1
  if $irqexit_hits <= 4
    printf "\n=== irqentry_exit entry hit %d ===\n", $irqexit_hits
    bt 12
    info reg pc sp ra tp a0 a1
  end
  continue
end

break *0xffffffff808e7c3e
commands
  silent
  set $irqexit_ret_hits = $irqexit_ret_hits + 1
  if $irqexit_ret_hits <= 4
    printf "\n=== irqentry_exit kernel ret hit %d ===\n", $irqexit_ret_hits
    bt 12
    info reg pc sp ra tp a0 a1
  end
  continue
end

break *0xffffffff808e7c46
commands
  silent
  printf "\n=== irqentry_exit to_user branch ===\n"
  bt 12
  info reg pc sp ra tp a0 a1
  continue
end

break *0xffffffff808e7c52
commands
  silent
  printf "\n=== irqentry_exit ct_irq_exit branch ===\n"
  bt 12
  info reg pc sp ra tp a0 a1
  continue
end

break *0xffffffff808f0d52
commands
  silent
  set $ret_exc_hits = $ret_exc_hits + 1
  if $ret_exc_hits <= 4
    printf "\n=== ret_from_exception hit %d ===\n", $ret_exc_hits
    bt 12
    info reg pc sp ra tp a0 a1
  end
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
