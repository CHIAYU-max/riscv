// One U-Net encoder block on a small tile: 3x3 convolution (+ bias) -> requantize with ReLU -> 2x2 max pooling,
// INT8 in HWC layout (data from sw/c/gen_block.py). Built four ways from this file:
//   block_ref   plain RV32I: products through __mulsi3, requant through __muldi3, byte-wise pooling
//   block_mul   RV32IM (golden model only): the same C code with hardware mul / mulh
//   block_dot4  -DUSE_DOT4: dot4 for the convolution, the rest as in block_ref
//   block_nn    -DUSE_NNOPS: dot4, requant and max4 (four channels per instruction)
//   block_rb    -DUSE_RB: as block_nn, with register blocking in the convolution: 2 output pixels x 4 output
//               channels at a time, so each loaded activation word feeds 4 dot4s and each weight word 2
//               (6 loads per 8 dot4s instead of 16)
// The three phases are separate functions so that sw/iss.py --profile can count each one.
// Returns 0 when the pooled output matches the one gen_block.py computed.
#include "block_data.h"
#include "../dot4.h"
#include "../nnops.h"
#ifdef USE_RB
#define USE_NNOPS
#endif
#ifdef USE_NNOPS
#define USE_DOT4
#endif

static int acc_buf[OH * OW * COUT];
static unsigned char act_out[OH * OW * COUT] __attribute__((aligned(4)));
static unsigned char pooled[(OH / 2) * (OW / 2) * COUT] __attribute__((aligned(4)));

#ifdef USE_RB
// 2 x 4 register block: outputs (oy, ox) and (oy, ox + 1) for channels oc .. oc + 3 (OW and COUT are even / multiples
// of 4, checked by gen_block.py). 8 accumulators, 2 activation and 4 weight words live in registers.
__attribute__((noinline)) static void conv(void)
{
    for (int oy = 0; oy < OH; oy++)
        for (int ox = 0; ox < OW; ox += 2)
            for (int oc = 0; oc < COUT; oc += 4) {
                int s00 = bias[oc], s01 = bias[oc + 1], s02 = bias[oc + 2], s03 = bias[oc + 3];
                int s10 = s00, s11 = s01, s12 = s02, s13 = s03;
                for (int ky = 0; ky < 3; ky++)
                    for (int kx = 0; kx < 3; kx++) {
                        const unsigned *a0 = (const unsigned *)&act[((oy + ky) * (OW + 2) + (ox + kx)) * CIN];
                        const unsigned *a1 = a0 + CIN / 4;                   // next pixel to the right
                        const unsigned *w0 = (const unsigned *)&wgt[((oc * 3 + ky) * 3 + kx) * CIN];
                        const unsigned *w1 = w0 + 9 * CIN / 4, *w2 = w1 + 9 * CIN / 4, *w3 = w2 + 9 * CIN / 4;
                        for (int c = 0; c < CIN / 4; c++) {
                            unsigned x0 = a0[c], x1 = a1[c];
                            unsigned y0 = w0[c], y1 = w1[c], y2 = w2[c], y3 = w3[c];
                            s00 += dot4(x0, y0); s01 += dot4(x0, y1); s02 += dot4(x0, y2); s03 += dot4(x0, y3);
                            s10 += dot4(x1, y0); s11 += dot4(x1, y1); s12 += dot4(x1, y2); s13 += dot4(x1, y3);
                        }
                    }
                int *o0 = &acc_buf[(oy * OW + ox) * COUT + oc], *o1 = o0 + COUT;
                o0[0] = s00; o0[1] = s01; o0[2] = s02; o0[3] = s03;
                o1[0] = s10; o1[1] = s11; o1[2] = s12; o1[3] = s13;
            }
}
#else
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
#endif

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
