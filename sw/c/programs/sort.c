// Bubble sort of 16 words in .data, then check the order (loads, stores, branches).
static int data[16] = {37, -5, 12, 99, 0, 64, -128, 7, 7, 250, -1, 18, 3, 1000, -77, 42};

int main(void)
{
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 15 - i; j++)
            if (data[j] > data[j + 1]) {
                int t = data[j];
                data[j] = data[j + 1];
                data[j + 1] = t;
            }
    for (int i = 0; i < 15; i++)
        if (data[i] > data[i + 1])
            return i + 1;
    return data[0] == -128 && data[15] == 1000 ? 0 : 99;
}
