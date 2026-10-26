// Recursive calls exercise jal / jalr and the stack: fib(15) = 610.
static int fib(int n)
{
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

int main(void)
{
    volatile int n = 15;
    return fib(n) == 610 ? 0 : 1;
}
