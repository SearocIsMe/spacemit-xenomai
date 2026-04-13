set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
set logging file .build/qemu-virt/irq-pipeline.cpu1-rcu-return.gdb.log
set logging overwrite on
set logging enabled on

target remote :1235

break *raise_softirq+2
commands
  silent
  printf "\n=== raise_softirq entry ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p nr=%p thread=%d\n", $pc, $sp, $ra, $tp, $a0, $_thread
  x/8gx $sp
  bt 12
  continue
end

break *invoke_rcu_core+62
commands
  silent
  printf "\n=== invoke_rcu_core return slot ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p thread=%d\n", $pc, $sp, $ra, $tp, $_thread
  x/8gx $sp
  bt 12
  continue
end

break handle_bad_stack
commands
  silent
  printf "\n=== handle_bad_stack ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p regs=%p thread=%d\n", $pc, $sp, $ra, $tp, $a0, $_thread
  x/12gx $a0
  bt 20
  x/12i $ra-16
  detach
  quit
end

continue
