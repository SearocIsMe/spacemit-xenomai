set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
set logging file .build/qemu-virt/irq-pipeline.schedule-ebreak.gdb.log
set logging overwrite on
set logging enabled on

target remote :1235

break *(__schedule+2096)
commands
  silent
  printf "\n=== __schedule ebreak +2096 ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p thread=%d\n", $pc, $sp, $ra, $tp, $_thread
  bt 20
  x/12i $pc-16
  continue
end

break *(__schedule+2100)
commands
  silent
  printf "\n=== __schedule ebreak +2100 ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p thread=%d\n", $pc, $sp, $ra, $tp, $_thread
  bt 20
  x/12i $pc-16
  continue
end

break *(__schedule+2104)
commands
  silent
  printf "\n=== __schedule ebreak +2104 ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p thread=%d\n", $pc, $sp, $ra, $tp, $_thread
  bt 20
  x/12i $pc-16
  continue
end

break *(__schedule+2130)
commands
  silent
  printf "\n=== __schedule ebreak +2130 ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p thread=%d\n", $pc, $sp, $ra, $tp, $_thread
  bt 20
  x/12i $pc-16
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
