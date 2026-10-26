// Minimal test environment for running riscv-tests (rv32ui) on a bare RV32I core.
//
// It replaces riscv-tests/env/p/riscv_test.h, which needs CSRs, traps and ecall.
// Here a test reports its result by storing a word to the memory-mapped TOHOST
// address, which the testbench (tb/tb_core.v) watches:
//   1               pass
//   (TESTNUM << 1) | 1  fail in test case TESTNUM
// The core only has to treat FENCE as a no-op.

#ifndef _ENV_BARE_RV32I_TEST_H
#define _ENV_BARE_RV32I_TEST_H

#define TOHOST 0x80000000

#define TESTNUM gp

#define RVTEST_RV32U \
  .macro init;       \
  .endm

#define RVTEST_RV64U RVTEST_RV32U

#define INIT_XREG                                                       \
  li x1, 0;  li x2, 0;  li x3, 0;  li x4, 0;  li x5, 0;  li x6, 0;      \
  li x7, 0;  li x8, 0;  li x9, 0;  li x10, 0; li x11, 0; li x12, 0;     \
  li x13, 0; li x14, 0; li x15, 0; li x16, 0; li x17, 0; li x18, 0;     \
  li x19, 0; li x20, 0; li x21, 0; li x22, 0; li x23, 0; li x24, 0;     \
  li x25, 0; li x26, 0; li x27, 0; li x28, 0; li x29, 0; li x30, 0;     \
  li x31, 0;

#define RVTEST_CODE_BEGIN \
  .section .text.init;    \
  .align 2;               \
  .globl _start;          \
_start:                   \
  INIT_XREG;              \
  init;

#define RVTEST_CODE_END \
  unimp

// Stop by spinning; the testbench ends the simulation when TOHOST is written.
#define RVTEST_PASS \
  fence;            \
  li TESTNUM, 1;    \
  li t0, TOHOST;    \
  sw TESTNUM, 0(t0); \
1: j 1b;

// TESTNUM == 0 would encode as "pass", so hang instead (the testbench times out).
#define RVTEST_FAIL          \
  fence;                     \
1: beqz TESTNUM, 1b;         \
  sll TESTNUM, TESTNUM, 1;   \
  or TESTNUM, TESTNUM, 1;    \
  li t0, TOHOST;             \
  sw TESTNUM, 0(t0);         \
2: j 2b;

#define RVTEST_DATA_BEGIN \
  .align 4;               \
  .global begin_signature; \
begin_signature:

#define RVTEST_DATA_END \
  .align 4;             \
  .global end_signature; \
end_signature:

#endif
