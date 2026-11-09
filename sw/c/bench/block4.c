// INT4 version of the U-Net block benchmark (sw/c/bench/block.c): 3x3 convolution (+ bias) -> requantize with ReLU
// -> 2x2 max pooling on the same tile, with u4 activations and s4 weights packed two per byte (low nibble = even
// channel, data from sw/c/gen_block.py --bits 4). Golden model only: dot8 is not in the RTL.
//   block_q4    dot8 for the convolution (8 MACs per instruction), requant + clamp to 15, max4 on one value per
//               byte, then the pooled output is packed back into nibbles for the next layer
//   block_q4rb  -DUSE_RB: as block_q4, with the same 2 x 4 register blocking as block_rb
// requant clamps to 255, so the clamp to 15 is done in software; the pool phase includes the nibble packing.
// Returns 0 when the packed pooled output matches the one gen_block.py computed.
#include "block4_data.h"
#include "../dot8.h"
#include "../nnops.h"

#define CW (CIN / 8)    // 32-bit words per pixel (8 channels per word)

static int acc_buf[OH * OW * COUT];
static unsigned char act_out[OH * OW * COUT] __attribute__((aligned(4)));
static unsigned char pooled[(OH / 2) * (OW / 2) * COUT / 2] __attribute__((aligned(4)));

#ifdef USE_RB
__attribute__((noinline)) static void conv(void)
{
    for (int oy = 0; oy < OH; oy++)
        for (int ox = 0; ox < OW; ox += 2)
            for (int oc = 0; oc < COUT; oc += 4) {
                int s00 = bias[oc], s01 = bias[oc + 1], s02 = bias[oc + 2], s03 = bias[oc + 3];
                int s10 = s00, s11 = s01, s12 = s02, s13 = s03;
                for (int ky = 0; ky < 3; ky++)
                    for (int kx = 0; kx < 3; kx++) {
                        const unsigned *a0 = (const unsigned *)act + ((oy + ky) * (OW + 2) + (ox + kx)) * CW;
                        const unsigned *a1 = a0 + CW;                        // next pixel to the right
                        const unsigned *w0 = (const unsigned *)wgt + ((oc * 3 + ky) * 3 + kx) * CW;
                        const unsigned *w1 = w0 + 9 * CW, *w2 = w1 + 9 * CW, *w3 = w2 + 9 * CW;
                        for (int c = 0; c < CW; c++) {
                            unsigned x0 = a0[c], x1 = a1[c];
                            unsigned y0 = w0[c], y1 = w1[c], y2 = w2[c], y3 = w3[c];
                            s00 += dot8(x0, y0); s01 += dot8(x0, y1); s02 += dot8(x0, y2); s03 += dot8(x0, y3);
                            s10 += dot8(x1, y0); s11 += dot8(x1, y1); s12 += dot8(x1, y2); s13 += dot8(x1, y3);
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
                        const unsigned *a = (const unsigned *)act + ((oy + ky) * (OW + 2) + (ox + kx)) * CW;
                        const unsigned *w = (const unsigned *)wgt + ((oc * 3 + ky) * 3 + kx) * CW;
                        for (int c = 0; c < CW; c++)
                            acc += dot8(a[c], w[c]);
                    }
                acc_buf[(oy * OW + ox) * COUT + oc] = acc;
            }
}
#endif

__attribute__((noinline)) static void requantize(void)
{
    for (int i = 0; i < OH * OW * COUT; i++) {
        unsigned r = requant(acc_buf[i], rq_params[i % COUT]);
        act_out[i] = r > 15 ? 15 : r;
    }
}

// four byte lanes, each 0..15, to four nibbles in bits [15:0]
static inline unsigned pack_nibbles(unsigned w)
{
    return (w & 0xF) | (w >> 4 & 0xF0) | (w >> 8 & 0xF00) | (w >> 12 & 0xF000);
}

__attribute__((noinline)) static void maxpool(void)
{
    const unsigned *in = (const unsigned *)act_out;
    unsigned *out = (unsigned *)pooled;
    for (int py = 0; py < OH / 2; py++)
        for (int px = 0; px < OW / 2; px++) {
            const int p00 = ((2 * py) * OW + 2 * px) * COUT / 4, p01 = p00 + COUT / 4;
            const int p10 = p00 + OW * COUT / 4, p11 = p10 + COUT / 4;
            const int o = (py * (OW / 2) + px) * COUT / 8;
            for (int c = 0; c < COUT / 8; c++) {
                unsigned lo = max4(max4(in[p00 + 2 * c], in[p01 + 2 * c]), max4(in[p10 + 2 * c], in[p11 + 2 * c]));
                unsigned hi = max4(max4(in[p00 + 2 * c + 1], in[p01 + 2 * c + 1]),
                                   max4(in[p10 + 2 * c + 1], in[p11 + 2 * c + 1]));
                out[o + c] = pack_nibbles(lo) | pack_nibbles(hi) << 16;
            }
        }
}

int main(void)
{
    conv();
    requantize();
    maxpool();
    for (int i = 0; i < (OH / 2) * (OW / 2) * COUT / 2; i++)
        if (pooled[i] != expected[i])
            return i + 1;
    return 0;
}
