// Memory-mapped I/O (see README "Memory map")
#ifndef MMIO_H
#define MMIO_H

#define MMIO_TOHOST (*(volatile unsigned int *)0x80000000u)  // write: end of program / test result
#define MMIO_LED    (*(volatile unsigned int *)0x80000004u)  // write: LED[15:0]
#define MMIO_SEG    (*(volatile unsigned int *)0x80000008u)  // write: hex digits on the 7-segment display (Basys3: bits [15:0], Nexys A7: all 32)
#define MMIO_SW     (*(volatile unsigned int *)0x8000000Cu)  // read: switches SW[15:0]

#endif
