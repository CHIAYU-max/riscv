// Loop and add: sum of 1..100 must be 5050.
int main(void)
{
    volatile int n = 100;
    int sum = 0;
    for (int i = 1; i <= n; i++)
        sum += i;
    return sum == 5050 ? 0 : 1;
}
