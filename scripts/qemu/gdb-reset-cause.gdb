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
  continue
end

break *0xffffffff808da216
commands
  silent
  printf "\n==== breakpoint: panic ====\n"
  bt 12
  continue
end

break *0xffffffff80005d26
commands
  silent
  printf "\n==== breakpoint: die ====\n"
  bt 12
  continue
end

break *0xffffffff800044f6
commands
  silent
  printf "\n==== breakpoint: machine_restart ====\n"
  bt 12
  continue
end

break *0xffffffff80037b0c
commands
  silent
  printf "\n==== breakpoint: emergency_restart ====\n"
  bt 12
  continue
end

break *0xffffffff80038474
commands
  silent
  printf "\n==== breakpoint: kernel_restart ====\n"
  bt 12
  continue
end

continue
