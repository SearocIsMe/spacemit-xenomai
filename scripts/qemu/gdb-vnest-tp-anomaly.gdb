set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break *0xffffffff80008fce
commands
  silent
  if ((unsigned long)$tp >= 0xff60000000000000 && (unsigned long)$tp < 0xff70000000000000)
    printf "\n==== breakpoint: riscv_v_context_nesting_end tp anomaly ====\n"
    printf "pc=%p sp=%p tp=%p ra=%p a0(regs)=%p\n", $pc, $sp, $tp, $ra, $a0
    printf "tp+0x830(inband stall?)=%#lx\n", *(unsigned long *)($tp + 0x830)
    printf "tp+0xbf8(v_flags)=%#x\n", *(unsigned int *)($tp + 0xbf8)
    x/12gx $a0
    bt 16
    detach
    quit
  end
  continue
end

continue
