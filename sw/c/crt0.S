# Startup code for C programs on rv32i_core (simulation and Basys3).
# Sets gp and sp, clears .bss, calls main, then reports main's return value
# to TOHOST the same way as the riscv-tests environment:
#   return 0 -> 1 (pass), return n -> (n << 1) | 1 (fail code n)

    .section .text.init
    .globl _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top

    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b

2:  call    main

    li      t0, 0x80000000
    beqz    a0, 3f
    slli    a0, a0, 1
    ori     a0, a0, 1
    j       4f
3:  li      a0, 1
4:  sw      a0, 0(t0)
5:  j       5b
