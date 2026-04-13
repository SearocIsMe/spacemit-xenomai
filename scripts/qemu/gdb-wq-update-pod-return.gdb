set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
set logging file .build/qemu-virt/irq-pipeline.wq-update-pod-return.gdb.log
set logging overwrite on
set logging enabled on

target remote :1235

set $ret1_hits = 0
set $next1_hits = 0
set $ret2_hits = 0
set $next2_hits = 0
set $alloc_ret_hits = 0
set $prep_ret1_hits = 0
set $prep_ret2_hits = 0

break *apply_wqattrs_prepare+0xae
commands
  silent
  set $prep_ret1_hits = $prep_ret1_hits + 1
  printf "\n=== apply_wqattrs_prepare first return site hit %d ===\n", $prep_ret1_hits
  printf "pc=%p sp=%p ra=%p tp=%p a0=%p s3(ctx)=%p s4(wq)=%p s8(attrs)=%p\n", $pc, $sp, $ra, $tp, $a0, $s3, $s4, $s8
  bt 12
  continue
end

break *apply_wqattrs_prepare+0x1a6
commands
  silent
  set $prep_ret2_hits = $prep_ret2_hits + 1
  printf "\n=== apply_wqattrs_prepare loop return site hit %d ===\n", $prep_ret2_hits
  printf "pc=%p sp=%p ra=%p tp=%p a0=%p s1(cpu)=%p s3(ctx)=%p s4(wq)=%p s8(attrs)=%p\n", $pc, $sp, $ra, $tp, $a0, $s1, $s3, $s4, $s8
  bt 12
  continue
end

break *alloc_unbound_pwq+0x258
commands
  silent
  set $alloc_ret_hits = $alloc_ret_hits + 1
  printf "\n=== alloc_unbound_pwq ret hit %d ===\n", $alloc_ret_hits
  printf "pc=%p sp=%p ra=%p tp=%p a0(ret pwq)=%p s2(pwq)=%p s3(wq)=%p\n", $pc, $sp, $ra, $tp, $a0, $s2, $s3
  x/s $s3+208
  x/4i $pc
  x/4i $ra
  bt 12
  continue
end

break *wq_update_pod+0xd8
commands
  silent
  set $ret1_hits = $ret1_hits + 1
  printf "\n=== wq_update_pod trace-path return hit %d ===\n", $ret1_hits
  printf "pc=%p sp=%p ra=%p tp=%p a0(pwq)=%p s1(wq)=%p s2(pwq)=%p s3(cpu)=%p s4=%p s5(name)=%p\n", $pc, $sp, $ra, $tp, $a0, $s1, $s2, $s3, $s4, $s5
  x/s $s5
  bt 12
  continue
end

break *wq_update_pod+0xe6
commands
  silent
  set $next1_hits = $next1_hits + 1
  printf "\n=== wq_update_pod trace-path mutex_lock site hit %d ===\n", $next1_hits
  printf "pc=%p sp=%p ra=%p tp=%p a0=%p s1(wq)=%p s2(pwq)=%p s3(cpu)=%p s5(name)=%p\n", $pc, $sp, $ra, $tp, $a0, $s1, $s2, $s3, $s5
  x/s $s5
  bt 12
  continue
end

break *wq_update_pod+0x1ce
commands
  silent
  set $ret2_hits = $ret2_hits + 1
  printf "\n=== wq_update_pod normal-path return hit %d ===\n", $ret2_hits
  printf "pc=%p sp=%p ra=%p tp=%p a0(pwq)=%p s1(wq)=%p s2(pwq)=%p s3(cpu)=%p s5(mutex)=%p\n", $pc, $sp, $ra, $tp, $a0, $s1, $s2, $s3, $s5
  x/s $s1+208
  bt 12
  continue
end

break *wq_update_pod+0x1d8
commands
  silent
  set $next2_hits = $next2_hits + 1
  printf "\n=== wq_update_pod normal-path mutex_lock site hit %d ===\n", $next2_hits
  printf "pc=%p sp=%p ra=%p tp=%p a0=%p s1(wq)=%p s2(pwq)=%p s3(cpu)=%p s5(mutex)=%p\n", $pc, $sp, $ra, $tp, $a0, $s1, $s2, $s3, $s5
  x/s $s1+208
  bt 12
  continue
end

break handle_bad_stack
commands
  silent
  printf "\n=== handle_bad_stack ===\n"
  printf "pc=%p sp=%p ra=%p tp=%p a0=%p\n", $pc, $sp, $ra, $tp, $a0
  bt 16
  detach
  quit
end

continue
