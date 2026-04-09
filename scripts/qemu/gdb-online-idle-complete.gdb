set debuginfod enabled off
set pagination off
set confirm off
set arch riscv:rv64
target remote :1235

break *0xffffffff8001614e
commands
  silent
  printf "\n==== breakpoint: cpuhp_online_idle after complete ====\n"
  bt 6
  quit
end

continue
