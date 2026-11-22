// Text output (MMIO_PUTC): prints two lines and checks a value, as a failing test would report it.
// Expected simulation output:
//   OUT     putc: hello from rv32i
//   OUT     putc: sum = 000013ba
#include "../mmio.h"

int main(void)
{
    volatile int n = 100;
    int sum = 0;
    for (int i = 1; i <= n; i++)
        sum += i;
    sim_puts("hello from rv32i\n");
    sim_puts("sum = ");
    sim_puthex(sum);
    sim_putc('\n');
    return sum == 5050 ? 0 : 1;
}
