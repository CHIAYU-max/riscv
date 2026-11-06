// max4 and requant custom instructions (custom-0 opcode 0001011, R-type, funct7 = 0); keep in sync with sw/iss.py.
//   max4    funct3 = 1: rd[i] = max(rs1[i], rs2[i]) per unsigned byte lane (2x2 max pooling on u8 activations)
//   requant funct3 = 2: rd = clamp(((acc * M + round) >> shift) + zp, 0, 255), acc = rs1 (signed 32-bit),
//                       rs2 = REQUANT_PARAMS(M, shift, zp); round = 1 << (shift - 1), or 0 when shift = 0
//                       (round half up). With zp = 0 the clamp at 0 is the ReLU.
#ifndef NNOPS_H
#define NNOPS_H

#define REQUANT_PARAMS(m, shift, zp) \
    (((unsigned)(zp) & 0xFFu) << 24 | ((unsigned)(shift) & 31u) << 16 | ((unsigned)(m) & 0xFFFFu))

static inline unsigned max4(unsigned a, unsigned b)
{
    unsigned r;
    __asm__ volatile(".insn r 0x0B, 1, 0, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}

static inline unsigned requant(int acc, unsigned params)
{
    unsigned r;
    __asm__ volatile(".insn r 0x0B, 2, 0, %0, %1, %2" : "=r"(r) : "r"(acc), "r"(params));
    return r;
}

// Plain RV32I versions of the same operations
static inline unsigned max4_ref(unsigned a, unsigned b)
{
    unsigned r = 0;
    for (int i = 0; i < 4; i++) {
        unsigned x = a >> (8 * i) & 0xFF, y = b >> (8 * i) & 0xFF;
        r |= (x > y ? x : y) << (8 * i);
    }
    return r;
}

static inline unsigned requant_ref(int acc, unsigned params)
{
    unsigned m = params & 0xFFFF, shift = params >> 16 & 31;
    int zp = params >> 24 & 0xFF;
    long long t = (long long)acc * m;    // __muldi3 on RV32I
    if (shift)
        t = (t + (1LL << (shift - 1))) >> shift;
    t += zp;
    return t < 0 ? 0 : t > 255 ? 255 : (unsigned)t;
}

#endif
