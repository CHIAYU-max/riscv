// Memory-mapped I/O (see README "Memory map")
#ifndef MMIO_H
#define MMIO_H

#define MMIO_TOHOST (*(volatile unsigned int *)0x80000000u)  // write: end of program / test result
#define MMIO_LED    (*(volatile unsigned int *)0x80000004u)  // write: LED[15:0]
#define MMIO_SEG    (*(volatile unsigned int *)0x80000008u)  // write: hex digits on the 7-segment display (Basys3: bits [15:0], Nexys A7: all 32)
#define MMIO_SW     (*(volatile unsigned int *)0x8000000Cu)  // read: switches SW[15:0]
#define MMIO_PUTC   (*(volatile unsigned int *)0x80000010u)  // write: one character, bits [7:0] (simulation only; the boards ignore it)

// Text output for simulation (tb_core.v and sw/iss.py print each line as "OUT <name>: <text>").
// On the boards the stores are ignored, so a program that prints still runs there.
static inline void sim_putc(char c) { MMIO_PUTC = (unsigned char)c; }

static inline void sim_puts(const char *s)
{
    while (*s)
        sim_putc(*s++);
}

static inline void sim_puthex(unsigned int v)
{
    for (int shift = 28; shift >= 0; shift -= 4)
        sim_putc("0123456789abcdef"[(v >> shift) & 0xF]);
}

#endif
