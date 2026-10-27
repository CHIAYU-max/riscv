// dot4 custom instruction (custom-0 opcode 0001011, R-type, funct3 = 0, funct7 = 0):
// rd = rs1[7:0]*rs2[7:0] + rs1[15:8]*rs2[15:8] + rs1[23:16]*rs2[23:16] + rs1[31:24]*rs2[31:24]
// Each operand's signedness follows DOT4_RS1_SIGNED / DOT4_RS2_SIGNED in sw/iss.py; keep them in sync.
#ifndef DOT4_H
#define DOT4_H

#ifndef DOT4_RS1_SIGNED
#define DOT4_RS1_SIGNED 1
#endif
#ifndef DOT4_RS2_SIGNED
#define DOT4_RS2_SIGNED 1
#endif

static inline int dot4(unsigned a, unsigned b)
{
    int r;
    __asm__ volatile(".insn r 0x0B, 0, 0, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}

static inline int byte_lane(unsigned word, int i, int is_signed)
{
    unsigned v = word >> (8 * i) & 0xFF;
    return is_signed ? (int)(signed char)v : (int)v;
}

// Plain RV32I version of the same operation (GCC calls __mulsi3 for each product)
static inline int dot4_ref(unsigned a, unsigned b)
{
    int sum = 0;
    for (int i = 0; i < 4; i++)
        sum += byte_lane(a, i, DOT4_RS1_SIGNED) * byte_lane(b, i, DOT4_RS2_SIGNED);
    return sum;
}

#endif
