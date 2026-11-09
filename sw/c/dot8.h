// dot8 custom instruction, INT4 experiment (custom-0 opcode 0001011, R-type, funct3 = 3, funct7 = 0; golden model
// only, not in the RTL): rd = sum over the eight nibble lanes of rs1[i] * rs2[i], lane i = bits [4i+3:4i],
// rs1 lanes unsigned (u4 activations), rs2 lanes signed (s4 weights). Keep in sync with sw/iss.py.
#ifndef DOT8_H
#define DOT8_H

static inline int dot8(unsigned a, unsigned b)
{
    int r;
    __asm__ volatile(".insn r 0x0B, 3, 0, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}

// Plain RV32I version of the same operation
static inline int dot8_ref(unsigned a, unsigned b)
{
    int sum = 0;
    for (int i = 0; i < 8; i++) {
        int x = a >> (4 * i) & 0xF;
        int y = (int)(b << (28 - 4 * i)) >> 28;     // sign-extend nibble i
        sum += x * y;
    }
    return sum;
}

#endif
