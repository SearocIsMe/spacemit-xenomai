set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break complete if $ra == 0xffffffff8001614e
commands
  silent
  printf "\n==== breakpoint: complete from cpuhp_online_idle ====\n"
  bt 6
  enable 2
  continue
end

break try_to_wake_up
commands
  silent
  printf "\n==== breakpoint: try_to_wake_up after cpuhp_online_idle complete ====\n"
  bt 8
  quit
end

disable 2

continue
