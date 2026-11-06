// One U-Net encoder block on a small tile: 3x3 convolution (+ bias) -> requantize with ReLU -> 2x2 max pooling,
// INT8 in HWC layout (data from sw/c/gen_block.py). Built four ways from this file:
//   block_ref   plain RV32I: products through __mulsi3, requant through __muldi3, byte-wise pooling
//   block_mul   RV32IM (golden model only): the same C code with hardware mul / mulh
//   block_dot4  -DUSE_DOT4: dot4 for the convolution, the rest as in block_ref
//   block_nn    -DUSE_NNOPS: dot4, requant and max4 (four channels per instruction)
// The three phases are separate functions so that sw/iss.py --profile can count each one.
// Returns 0 when the pooled output matches the one gen_block.py computed.
#include "block_data.h"
#include "../dot4.h"
#include "../nnops.h"
#ifdef USE_NNOPS
#define USE_DOT4
#endif

static int acc_buf[OH * OW * COUT];
static unsigned char act_out[OH * OW * COUT] __attribute__((aligned(4)));
static unsigned char pooled[(OH / 2) * (OW / 2) * COUT] __attribute__((aligned(4)));

__attribute__((noinline)) static void conv(void)
{
    for (int oy = 0; oy < OH; oy++)
        for (int ox = 0; ox < OW; ox++)
            for (int oc = 0; oc < COUT; oc++) {
                int acc = bias[oc];
                for (int ky = 0; ky < 3; ky++)
                    for (int kx = 0; kx < 3; kx++) {
                        const unsigned char *a = &act[((oy + ky) * (OW + 2) + (ox + kx)) * CIN];
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
                acc_buf[(oy * OW + ox) * COUT + oc] = acc;
            }
}

__attribute__((noinline)) static void requantize(void)
{
    for (int p = 0; p < OH * OW; p++)
        for (int oc = 0; oc < COUT; oc++)
#ifdef USE_NNOPS
            act_out[p * COUT + oc] = requant(acc_buf[p * COUT + oc], rq_params[oc]);
#else
            act_out[p * COUT + oc] = requant_ref(acc_buf[p * COUT + oc], rq_params[oc]);
#endif
}

__attribute__((noinline)) static void maxpool(void)
{
    for (int py = 0; py < OH / 2; py++)
        for (int px = 0; px < OW / 2; px++) {
            const int p00 = ((2 * py) * OW + 2 * px) * COUT, p01 = p00 + COUT;
            const int p10 = p00 + OW * COUT, p11 = p10 + COUT;
            const int o = (py * (OW / 2) + px) * COUT;
#ifdef USE_NNOPS
            const unsigned *in = (const unsigned *)act_out;
            unsigned *out = (unsigned *)pooled;
            for (int c = 0; c < COUT / 4; c++)
                out[o / 4 + c] = max4(max4(in[p00 / 4 + c], in[p01 / 4 + c]), max4(in[p10 / 4 + c], in[p11 / 4 + c]));
#else
            for (int c = 0; c < COUT; c++) {
                unsigned char m = act_out[p00 + c];
                if (act_out[p01 + c] > m) m = act_out[p01 + c];
                if (act_out[p10 + c] > m) m = act_out[p10 + c];
                if (act_out[p11 + c] > m) m = act_out[p11 + c];
                pooled[o + c] = m;
            }
#endif
        }
}

int main(void)
{
    conv();
    requantize();
    maxpool();
    for (int i = 0; i < (OH / 2) * (OW / 2) * COUT; i++)
        if (pooled[i] != expected[i])
            return i + 1;
    return 0;
}
