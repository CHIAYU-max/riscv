// RV32I has no multiply / divide: GCC calls libgcc (__mulsi3, __divsi3, __modsi3),
// which are built from shifts, adds and branches.
int main(void)
{
    volatile int a = 1234, b = -56, c = 7;
    if (a * b != -69104) return 1;
    if (a / c != 176) return 2;
    if (a % c != 2) return 3;
    if (b / c != -8) return 4;
    return 0;
}
