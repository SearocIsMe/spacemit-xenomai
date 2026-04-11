set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break sched_ttwu_pending
commands
  silent
  printf "\n==== breakpoint: sched_ttwu_pending ====\n"
  bt 10
  enable 2
  enable 3
  enable 4
  enable 5
  enable 6
  enable 7
  continue
end

break *0xffffffff808e96c0
commands
  silent
  printf "\n==== breakpoint: __schedule after sched_ttwu_pending ====\n"
  bt 10
  continue
end

break *0xffffffff8003b520
commands
  silent
  printf "\n==== breakpoint: finish_task_switch.isra.0 after sched_ttwu_pending ====\n"
  bt 10
  continue
end

break *0xffffffff808f0708
commands
  silent
  printf "\n==== breakpoint: ret_from_fork after sched_ttwu_pending ====\n"
  bt 10
  continue
end

break *0xffffffff80009018 if $s1 == 1
commands
  silent
  printf "\n==== breakpoint: __cpu_up cpu=1 after wait_for_completion_timeout ====\n"
  bt 10
  printf "wait ret(a0)=%ld cpu(s1)=%lu\n", $a0, $s1
  continue
end

break *0xffffffff80009042 if $s1 == 1
commands
  silent
  printf "\n==== breakpoint: __cpu_up cpu=1 success return path ====\n"
  bt 10
  printf "ret(s3)=%ld cpu(s1)=%lu\n", $s3, $s1
  continue
end

break *0xffffffff80014a7a if $s1 == 1
commands
  silent
  printf "\n==== breakpoint: bringup_cpu cpu=1 after __cpu_up ret ====\n"
  bt 10
  printf "__cpu_up ret(a0)=%ld cpu(s1)=%lu\n", $a0, $s1
  continue
end

disable 2
disable 3
disable 4
disable 5
disable 6
disable 7

continue
