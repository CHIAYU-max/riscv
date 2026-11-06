// max4 and requant against their plain C references (sw/c/nnops.h), plus a few hand-computed requant results
// so that the reference itself is checked. Returns 0 when all agree, otherwise the number of the first
// failing case (reported via TOHOST).
#include "../nnops.h"

static unsigned lcg(unsigned *state)
{
    *state = *state * 1664525u + 1013904223u;
    return *state;
}

int main(void)
{
    int n = 1;

    // Hand-computed requant results: scale 0.5 (M = 0x8000, shift = 16)
    static const struct { int acc; unsigned params, expect; } known[] = {
        {100, REQUANT_PARAMS(0x8000, 16, 0), 50},
        {3, REQUANT_PARAMS(0x8000, 16, 0), 2},        // 1.5 rounds up
        {-3, REQUANT_PARAMS(0x8000, 16, 10), 9},      // -1.5 rounds up to -1, + zp 10
        {-5, REQUANT_PARAMS(0x8000, 16, 0), 0},       // ReLU
        {1000, REQUANT_PARAMS(0x8000, 16, 0), 255},   // saturates
        {7, REQUANT_PARAMS(1, 0, 3), 10},             // shift 0: no rounding
        {0x7FFFFFFF, REQUANT_PARAMS(0xFFFF, 31, 0), 255},
        {(int)0x80000000, REQUANT_PARAMS(0xFFFF, 31, 200), 0},
    };
    for (unsigned i = 0; i < sizeof known / sizeof known[0]; i++, n++)
        if (requant(known[i].acc, known[i].params) != known[i].expect ||
            requant_ref(known[i].acc, known[i].params) != known[i].expect)
            return n;

    // max4: edge-value pairs, then pseudo-random words
    static const unsigned edge[] = {
        0x00000000u, 0xFFFFFFFFu, 0x7F7F7F7Fu, 0x80808080u, 0x01020304u, 0x80FF7F01u, 0x00FF0080u, 0x12345678u,
    };
    const int n_edge = sizeof edge / sizeof edge[0];
    for (int i = 0; i < n_edge; i++)
        for (int j = 0; j < n_edge; j++, n++)
            if (max4(edge[i], edge[j]) != max4_ref(edge[i], edge[j]))
                return n;
    unsigned state = 1;
    for (int k = 0; k < 64; k++, n++) {
        unsigned a = lcg(&state), b = lcg(&state);
        if (max4(a, b) != max4_ref(a, b))
            return n;
    }

    // requant: edge accumulators x edge parameters, then pseudo-random ones
    static const int accs[] = {0, 1, -1, 255, -256, 0x12345, -0x12345, 0x7FFFFFFF, (int)0x80000000};
    static const unsigned ms[] = {0, 1, 0x8000, 0xFFFF};
    static const unsigned shifts[] = {0, 1, 8, 16, 31};
    static const unsigned zps[] = {0, 128, 255};
    for (unsigned a = 0; a < sizeof accs / sizeof accs[0]; a++)
        for (unsigned m = 0; m < sizeof ms / sizeof ms[0]; m++)
            for (unsigned s = 0; s < sizeof shifts / sizeof shifts[0]; s++)
                for (unsigned z = 0; z < sizeof zps / sizeof zps[0]; z++, n++) {
                    unsigned p = REQUANT_PARAMS(ms[m], shifts[s], zps[z]);
                    if (requant(accs[a], p) != requant_ref(accs[a], p))
                        return n;
                }
    for (int k = 0; k < 64; k++, n++) {
        int acc = (int)lcg(&state) >> (lcg(&state) & 15);   // spread the magnitudes
        unsigned p = lcg(&state);
        if (requant(acc, p) != requant_ref(acc, p))
            return n;
    }
    return 0;
}
