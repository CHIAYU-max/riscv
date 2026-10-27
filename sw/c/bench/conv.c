// INT8 3x3 convolution tile, the inner loop of the U-Net layers (HWC layout, channels contiguous).
// Built twice from this file: conv_ref (plain RV32I, one multiply per MAC through __mulsi3)
// and conv_dot4 (-DUSE_DOT4, four MACs per dot4 on 32-bit loads). Both must reproduce the
// checksum that sw/c/gen_conv.py computed on the host; compare their cycle counts with make bench.
#include "conv_data.h"
#ifdef USE_DOT4
#include "../dot4.h"
#endif

int main(void)
{
    unsigned sum = 0;
    for (int oc = 0; oc < COUT; oc++)
        for (int oy = 0; oy < OH; oy++)
            for (int ox = 0; ox < OW; ox++) {
                int acc = 0;
                for (int ky = 0; ky < 3; ky++)
                    for (int kx = 0; kx < 3; kx++) {
                        const ACT_T *a = &act[((oy + ky) * (OW + 2) + (ox + kx)) * CIN];
                        const signed char *w = &wgt[((oc * 3 + ky) * 3 + kx) * CIN];
#ifdef USE_DOT4
                        const unsigned *a4 = (const unsigned *)a, *w4 = (const unsigned *)w;
                        for (int c = 0; c < CIN / 4; c++)
                            acc += dot4(a4[c], w4[c]);
#else
                        for (int c = 0; c < CIN; c++)
                            acc += a[c] * w[c];
#endif
                    }
                sum = (sum << 5) - sum + (unsigned)acc;   // sum * 31 + acc without a multiply
            }
    return sum == EXPECTED ? 0 : 1;
}
