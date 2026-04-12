set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break sched_ttwu_pending
commands
  silent
  printf "\n==== breakpoint: sched_ttwu_pending ====\n"
  printf "pc=%p sp=%p tp=%p ra=%p\n", $pc, $sp, $tp, $ra
  bt 12
  enable 2
  enable 3
  enable 4
  continue
end

break *0xffffffff80008fce
commands
  silent
  printf "\n==== breakpoint: riscv_v_context_nesting_end entry ====\n"
  printf "pc=%p sp=%p tp=%p ra=%p a0(regs)=%p\n", $pc, $sp, $tp, $ra, $a0
  printf "tp+0x830(inband stall?)=%#lx\n", *(unsigned long *)($tp + 0x830)
  printf "tp+0xbf8(v_flags)=%#x\n", *(unsigned int *)($tp + 0xbf8)
  x/6gx $a0
  continue
end

break *0xffffffff80008fe8
commands
  silent
  printf "\n==== breakpoint: riscv_v_context_nesting_end after inband_irqs_disabled ====\n"
  printf "pc=%p sp=%p tp=%p ra=%p a0(ret)=%p s3(regs)=%p s4(saved_tp)=%p\n", $pc, $sp, $tp, $ra, $a0, $s3, $s4
  printf "tp+0x830(inband stall?)=%#lx\n", *(unsigned long *)($tp + 0x830)
  printf "tp+0xbf8(v_flags)=%#x\n", *(unsigned int *)($tp + 0xbf8)
  x/6gx $s3
  continue
end

break handle_bad_stack
commands
  silent
  printf "\n==== breakpoint: handle_bad_stack ====\n"
  printf "pc=%p sp=%p tp=%p ra=%p a0=%p\n", $pc, $sp, $tp, $ra, $a0
  printf "tp+0x830(inband stall?)=%#lx\n", *(unsigned long *)($tp + 0x830)
  printf "tp+0xbf8(v_flags)=%#x\n", *(unsigned int *)($tp + 0xbf8)
  x/10gx $a0
  bt 16
  detach
  quit
end

disable 2
disable 3
disable 4

continue
