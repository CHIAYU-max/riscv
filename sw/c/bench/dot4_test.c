// dot4 against its plain C reference: edge values first, then pseudo-random words.
// Returns 0 when all agree, otherwise the number of the first failing case (reported via TOHOST).
#include "../dot4.h"

static unsigned lcg(unsigned *state)
{
    *state = *state * 1664525u + 1013904223u;
    return *state;
}

int main(void)
{
    static const unsigned edge[] = {
        0x00000000u, 0xFFFFFFFFu, 0x7F7F7F7Fu, 0x80808080u, 0x01020304u, 0x80FF7F01u, 0x00FF0080u, 0x12345678u,
    };
    const int n_edge = sizeof edge / sizeof edge[0];
    int n = 1;
    for (int i = 0; i < n_edge; i++)
        for (int j = 0; j < n_edge; j++, n++)
            if (dot4(edge[i], edge[j]) != dot4_ref(edge[i], edge[j]))
                return n;
    unsigned state = 1;
    for (int k = 0; k < 64; k++, n++) {
        unsigned a = lcg(&state), b = lcg(&state);
        if (dot4(a, b) != dot4_ref(a, b))
            return n;
    }
    return 0;
}
