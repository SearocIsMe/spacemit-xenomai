set pagination off
set confirm off
set print pretty on
set print elements 0
set disassemble-next-line off
set breakpoint pending on
set arch riscv:rv64

define hook-stop
  printf "\n==== stop pc=%p ====\n", $pc
end

define dump_desc_state
  if $argc > 0
    printf "desc=%p\n", $arg0
    p/x ((struct irq_desc *)$arg0)->istate
    p/x ((struct irq_desc *)$arg0)->irq_data.irq
  end
end

break handle_oob_irq
commands
  silent
  printf "\n==== breakpoint: handle_oob_irq ====\n"
  bt 10
  info args
  p/x irq_desc_get_irq(desc)
  p/x desc->istate
  continue
end

break handle_percpu_devid_irq
commands
  silent
  printf "\n==== breakpoint: handle_percpu_devid_irq ====\n"
  bt 12
  info args
  p/x irq_desc_get_irq(desc)
  p/x desc->istate
  p/x flow
  continue
end

break handle_irq_pipelined_finish
commands
  silent
  printf "\n==== breakpoint: handle_irq_pipelined_finish ====\n"
  bt 12
  info args
  p/x system_state
  p/x stage_irqs_pending(this_inband_staged())
  p/x stage_irqs_pending(this_oob_staged())
  continue
end

break synchronize_pipeline
commands
  silent
  printf "\n==== breakpoint: synchronize_pipeline ====\n"
  bt 12
  p/x system_state
  p/x stage_irqs_pending(this_inband_staged())
  p/x stage_irqs_pending(this_oob_staged())
  continue
end

break sync_current_irq_stage
commands
  silent
  printf "\n==== breakpoint: sync_current_irq_stage ====\n"
  bt 12
  p/x system_state
  p/x current_irq_staged
  p/x stage_irqs_pending(current_irq_staged)
  continue
end

break do_inband_irq
commands
  silent
  printf "\n==== breakpoint: do_inband_irq ====\n"
  bt 12
  info args
  p/x irq
  p/x desc->istate
  continue
end

break riscv_timer_interrupt
commands
  silent
  printf "\n==== breakpoint: riscv_timer_interrupt ====\n"
  bt 12
  info args
  p/x irq
  continue
end

break schedule_tail
commands
  silent
  printf "\n==== breakpoint: schedule_tail ====\n"
  bt 12
  info args
  p/x system_state
  continue
end

target remote :1234
continue
