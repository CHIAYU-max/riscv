// Sparse dot-product instructions for 2:4 weights (golden model only, branch sparse-dot; see docs/design-notes.md,
// "Ideas taken from UT Austin work", item 2). Keep in sync with sw/iss.py. A 2:4 group is four consecutive input
// channels of which two weights are non-zero; each non-zero carries a 2-bit index (0..3) of its channel.
//   sdot4  custom-0, R-type, funct3 = 3, funct7 = 0. One group per instruction:
//          rs1 = four u8 activations, rs2 = {12'b0, i1[19:18], i0[17:16], w1[15:8], w0[7:0]} (w s8),
//          rd = rs1[i0] * w0 + rs1[i1] * w1
//   sidx   custom-0, R-type, funct3 = 4, funct7 = 0, rd = x0: loads the index register IDX = rs1
//   sdot8  custom-1 (opcode 0101011), R4-type, funct3 = 0, funct2 = 0. Two groups per instruction:
//          rs1 / rs2 = activations of group 0 / 1, rs3 = {w3, w2, w1, w0} (s8; w0, w1 in group 0, w2, w3 in group 1),
//          indices i0..i3 = IDX[1:0], IDX[3:2], IDX[5:4], IDX[7:6];
//          rd = rs1[i0] * w0 + rs1[i1] * w1 + rs2[i2] * w2 + rs2[i3] * w3, then IDX >>= 8 (four sdot8 per sidx)
#ifndef SDOT_H
#define SDOT_H

static inline int sdot4(unsigned a, unsigned w)
{
    int r;
    __asm__ volatile(".insn r 0x0B, 3, 0, %0, %1, %2" : "=r"(r) : "r"(a), "r"(w));
    return r;
}

static inline void sidx(unsigned idx)
{
    __asm__ volatile(".insn r 0x0B, 4, 0, x0, %0, x0" : : "r"(idx) : "memory");
}

static inline int sdot8(unsigned a0, unsigned a1, unsigned w)
{
    int r;
    __asm__ volatile(".insn r4 0x2B, 0, 0, %0, %1, %2, %3" : "=r"(r) : "r"(a0), "r"(a1), "r"(w) : "memory");
    return r;
}

#endif
