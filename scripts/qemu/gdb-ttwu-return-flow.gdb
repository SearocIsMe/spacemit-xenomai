set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break sched_ttwu_pending
commands
  silent
  printf "\n==== breakpoint: sched_ttwu_pending ====\n"
  bt 8
  enable 2
  enable 3
  enable 4
  continue
end

break finish_task_switch
commands
  silent
  printf "\n==== breakpoint: finish_task_switch after sched_ttwu_pending ====\n"
  bt 8
  continue
end

break __schedule
commands
  silent
  printf "\n==== breakpoint: __schedule after sched_ttwu_pending ====\n"
  bt 8
  continue
end

break ret_from_fork
commands
  silent
  printf "\n==== breakpoint: ret_from_fork after sched_ttwu_pending ====\n"
  bt 8
  quit
end

disable 2
disable 3
disable 4

continue
