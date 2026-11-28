/* convolver_safety_test.c — real FFTConvolver lifecycle/geometry regression.
 *
 * The production convolver and DFT codelets are compiled into this test.
 * The two FFT table helpers below are the only link support; they contain no
 * convolution logic. Cases are separate so CTest records a pre-fix crash in
 * one case without hiding guard failures in the others.
 */
#include "FFTConvolver.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
static int checks;

static void check_value(int condition, const char *message)
{
    ++checks;
    if (!condition)
    {
        ++failures;
        fprintf(stderr, "FAIL: %s\n", message);
    }
}

static int all_zero(const float *values, unsigned int count)
{
    for (unsigned int i = 0; i < count; ++i)
        if (values[i] != 0.0f)
            return 0;
    return 1;
}

static int all_close(const float *values, const float *expected, unsigned int count)
{
    for (unsigned int i = 0; i < count; ++i)
        if (!isfinite(values[i]) || fabsf(values[i] - expected[i]) > 1e-5f)
            return 0;
    return 1;
}

static void fill_ramp(float *values, unsigned int count)
{
    for (unsigned int i = 0; i < count; ++i)
        values[i] = ((int)(i % 13) - 6) * 0.0625f;
}

static void test_uninitialized(void)
{
    float input[20];
    float y1[20];
    float y2[20];
    fill_ramp(input, 20);

    FFTConvolver1x1 one;
    FFTConvolver2x2 two;
    FFTConvolver1x2 one_two;
    FFTConvolver2x4x2 two_four_two;
    memset(&one, 0, sizeof(one));
    memset(&two, 0, sizeof(two));
    memset(&one_two, 0, sizeof(one_two));
    memset(&two_four_two, 0, sizeof(two_four_two));

    for (unsigned int i = 0; i < 20; ++i) y1[i] = y2[i] = 42.0f;
    FFTConvolver1x1Process(&one, input, y1, 20);
    check_value(all_zero(y1, 20), "raw 1x1 Process zeroes output");
    for (unsigned int i = 0; i < 20; ++i) y1[i] = y2[i] = 42.0f;
    FFTConvolver2x2Process(&two, input, input, y1, y2, 20);
    check_value(all_zero(y1, 20) && all_zero(y2, 20),
                "raw 2x2 Process zeroes both outputs");
    for (unsigned int i = 0; i < 20; ++i) y1[i] = y2[i] = 42.0f;
    FFTConvolver1x2Process(&one_two, input, y1, y2, 20);
    check_value(all_zero(y1, 20) && all_zero(y2, 20),
                "raw 1x2 Process zeroes both outputs");
    for (unsigned int i = 0; i < 20; ++i) y1[i] = y2[i] = 42.0f;
    FFTConvolver2x4x2Process(&two_four_two, input, input, y1, y2, 20);
    check_value(all_zero(y1, 20) && all_zero(y2, 20),
                "raw 2x4x2 Process zeroes both outputs");

    FFTConvolver1x1Init(&one);
    FFTConvolver2x2Init(&two);
    FFTConvolver1x2Init(&one_two);
    FFTConvolver2x4x2Init(&two_four_two);
    for (unsigned int i = 0; i < 20; ++i) y1[i] = y2[i] = 42.0f;
    FFTConvolver1x1Process(&one, input, y1, 20);
    check_value(all_zero(y1, 20), "Init-only 1x1 Process zeroes output");
    for (unsigned int i = 0; i < 20; ++i) y1[i] = y2[i] = 42.0f;
    FFTConvolver2x2Process(&two, input, input, y1, y2, 20);
    check_value(all_zero(y1, 20) && all_zero(y2, 20),
                "Init-only 2x2 Process zeroes both outputs");
    for (unsigned int i = 0; i < 20; ++i) y1[i] = y2[i] = 42.0f;
    FFTConvolver1x2Process(&one_two, input, y1, y2, 20);
    check_value(all_zero(y1, 20) && all_zero(y2, 20),
                "Init-only 1x2 Process zeroes both outputs");
    for (unsigned int i = 0; i < 20; ++i) y1[i] = y2[i] = 42.0f;
    FFTConvolver2x4x2Process(&two_four_two, input, input, y1, y2, 20);
    check_value(all_zero(y1, 20) && all_zero(y2, 20),
                "Init-only 2x4x2 Process zeroes both outputs");

    FFTConvolver1x1Free(&one);
    FFTConvolver2x2Free(&two);
    FFTConvolver1x2Free(&one_two);
    FFTConvolver2x4x2Free(&two_four_two);
    for (unsigned int i = 0; i < 20; ++i) y1[i] = y2[i] = 42.0f;
    FFTConvolver1x1Process(&one, input, y1, 20);
    FFTConvolver2x2Process(&two, input, input, y1, y2, 20);
    FFTConvolver1x2Process(&one_two, input, y1, y2, 20);
    FFTConvolver2x4x2Process(&two_four_two, input, input, y1, y2, 20);
    check_value(all_zero(y1, 20) && all_zero(y2, 20),
                "Process after Free zeroes output for all variants");
}

static void test_oversized(void)
{
    const unsigned int oversized = 524289u;
    float ir[8] = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float ir_half[8] = {0.5f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float input[20];
    float expected[20];
    float y1[20];
    float y2[20];
    fill_ramp(input, 20);

    FFTConvolver1x1 one;
    FFTConvolver2x2 two;
    FFTConvolver1x2 one_two;
    FFTConvolver2x4x2 two_four_two;
    FFTConvolver1x1Init(&one);
    FFTConvolver2x2Init(&two);
    FFTConvolver1x2Init(&one_two);
    FFTConvolver2x4x2Init(&two_four_two);
    check_value(FFTConvolver1x1LoadImpulseResponse(&one, 8, ir, 8) == 1,
                "load valid 1x1 before oversized rejection");
    check_value(FFTConvolver2x2LoadImpulseResponse(&two, 8, ir, ir_half, 8) == 1,
                "load valid 2x2 before oversized rejection");
    check_value(FFTConvolver1x2LoadImpulseResponse(&one_two, 8, ir, ir_half, 8) == 1,
                "load valid 1x2 before oversized rejection");
    check_value(FFTConvolver2x4x2LoadImpulseResponse(
                    &two_four_two, 8, ir, ir_half, ir_half, ir_half, 8) == 1,
                "load valid 2x4x2 before oversized rejection");

    check_value(FFTConvolver1x1LoadImpulseResponse(&one, oversized, ir, 8) == 0,
                "1x1 rejects blockSize > 524288");
    check_value(FFTConvolver2x2LoadImpulseResponse(&two, oversized, ir, ir, 8) == 0,
                "2x2 rejects blockSize > 524288");
    check_value(FFTConvolver1x2LoadImpulseResponse(&one_two, oversized, ir, ir, 8) == 0,
                "1x2 rejects blockSize > 524288");
    check_value(FFTConvolver2x4x2LoadImpulseResponse(
                    &two_four_two, oversized, ir, ir, ir, ir, 8) == 0,
                "2x4x2 rejects blockSize > 524288");

    FFTConvolver1x1Process(&one, input, y1, 20);
    check_value(all_close(y1, input, 20),
                "1x1 keeps old IR after oversized Load");
    FFTConvolver2x2Process(&two, input, input, y1, y2, 20);
    check_value(all_close(y1, input, 20), "2x2 keeps old left IR");
    for (unsigned int i = 0; i < 20; ++i) expected[i] = input[i] * 0.5f;
    check_value(all_close(y2, expected, 20), "2x2 keeps old right IR");
    FFTConvolver1x2Process(&one_two, input, y1, y2, 20);
    check_value(all_close(y1, input, 20) && all_close(y2, expected, 20),
                "1x2 keeps old IR after oversized Load");
    FFTConvolver2x4x2Process(&two_four_two, input, input, y1, y2, 20);
    for (unsigned int i = 0; i < 20; ++i) expected[i] = input[i] * 1.5f;
    check_value(all_close(y1, expected, 20), "2x4x2 keeps old LL/RL IRs");
    check_value(all_close(y2, input, 20), "2x4x2 keeps old LR/RR IRs");

    FFTConvolver1x1Free(&one);
    FFTConvolver2x2Free(&two);
    FFTConvolver1x2Free(&one_two);
    FFTConvolver2x4x2Free(&two_four_two);
}

static void test_invalid_load(void)
{
    float ir[8] = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float bad[8] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, NAN};
    float input[20];
    float expected[20];
    float y1[20];
    float y2[20];
    fill_ramp(input, 20);

    FFTConvolver1x1 one;
    FFTConvolver2x2 two;
    FFTConvolver1x2 one_two;
    FFTConvolver2x4x2 two_four_two;
    FFTConvolver1x1Init(&one);
    FFTConvolver2x2Init(&two);
    FFTConvolver1x2Init(&one_two);
    FFTConvolver2x4x2Init(&two_four_two);
    check_value(FFTConvolver1x1LoadImpulseResponse(&one, 8, ir, 8) == 1,
                "invalid-load case starts with valid 1x1");
    check_value(FFTConvolver2x2LoadImpulseResponse(&two, 8, ir, ir, 8) == 1,
                "invalid-load case starts with valid 2x2");
    check_value(FFTConvolver1x2LoadImpulseResponse(&one_two, 8, ir, ir, 8) == 1,
                "invalid-load case starts with valid 1x2");
    check_value(FFTConvolver2x4x2LoadImpulseResponse(
                    &two_four_two, 8, ir, ir, ir, ir, 8) == 1,
                "invalid-load case starts with valid 2x4x2");

    check_value(FFTConvolver1x1LoadImpulseResponse(&one, 8, NULL, 8) == 0,
                "1x1 rejects NULL IR");
    check_value(FFTConvolver1x1LoadImpulseResponse(&one, 0, ir, 8) == 0,
                "1x1 rejects zero block");
    check_value(FFTConvolver1x1LoadImpulseResponse(&one, 8, ir, 0) == 0,
                "1x1 rejects zero IR length");
    check_value(FFTConvolver1x1LoadImpulseResponse(&one, 8, bad, 8) == 0,
                "1x1 rejects NaN IR");
    check_value(FFTConvolver2x2LoadImpulseResponse(&two, 8, NULL, ir, 8) == 0,
                "2x2 rejects NULL left IR");
    check_value(FFTConvolver2x2LoadImpulseResponse(&two, 8, ir, bad, 8) == 0,
                "2x2 rejects NaN right IR");
    check_value(FFTConvolver1x2LoadImpulseResponse(&one_two, 8, ir, NULL, 8) == 0,
                "1x2 rejects NULL right IR");
    check_value(FFTConvolver1x2LoadImpulseResponse(&one_two, 8, bad, ir, 8) == 0,
                "1x2 rejects NaN left IR");
    check_value(FFTConvolver2x4x2LoadImpulseResponse(
                    &two_four_two, 8, ir, ir, ir, NULL, 8) == 0,
                "2x4x2 rejects NULL IR");
    check_value(FFTConvolver2x4x2LoadImpulseResponse(
                    &two_four_two, 8, ir, ir, bad, ir, 8) == 0,
                "2x4x2 rejects NaN IR");

    FFTConvolver1x1Process(&one, input, y1, 20);
    check_value(all_close(y1, input, 20), "invalid Load keeps old 1x1 usable");
    FFTConvolver2x2Process(&two, input, input, y1, y2, 20);
    check_value(all_close(y1, input, 20) && all_close(y2, input, 20),
                "invalid Load keeps old 2x2 usable");
    FFTConvolver1x2Process(&one_two, input, y1, y2, 20);
    check_value(all_close(y1, input, 20) && all_close(y2, input, 20),
                "invalid Load keeps old 1x2 usable");
    FFTConvolver2x4x2Process(&two_four_two, input, input, y1, y2, 20);
    for (unsigned int i = 0; i < 20; ++i) expected[i] = input[i] * 2.0f;
    check_value(all_close(y1, expected, 20) && all_close(y2, expected, 20),
                "invalid Load keeps old 2x4x2 usable");

    FFTConvolver1x1Free(&one);
    FFTConvolver2x2Free(&two);
    FFTConvolver1x2Free(&one_two);
    FFTConvolver2x4x2Free(&two_four_two);
}

static void test_refresh(void)
{
    float ir[16] = {1.0f};
    float gain_two[16] = {2.0f};
    float bad[16] = {0.0f};
    bad[15] = NAN;
    float input[20];
    float expected[20];
    float y1[20];
    float y2[20];
    fill_ramp(input, 20);

    FFTConvolver1x1 one;
    FFTConvolver2x2 scratch;
    FFTConvolver2x2 two;
    FFTConvolver1x1Init(&one);
    FFTConvolver2x2Init(&scratch);
    FFTConvolver2x2Init(&two);
    check_value(FFTConvolver1x1LoadImpulseResponse(&one, 8, ir, 16) == 1,
                "refresh case loads 1x1");
    check_value(FFTConvolver2x2LoadImpulseResponse(&scratch, 8, ir, ir, 16) == 1,
                "refresh case loads 2x2 scratch");
    check_value(FFTConvolver2x2LoadImpulseResponse(&two, 8, ir, ir, 16) == 1,
                "refresh case loads 2x2 target");

    check_value(FFTConvolver1x1RefreshImpulseResponse(&one, 16, ir, 16) == 0,
                "1x1 Refresh rejects incompatible block geometry");
    check_value(FFTConvolver1x1RefreshImpulseResponse(&one, 8, ir, 17) == 0,
                "1x1 Refresh rejects incompatible IR geometry");
    check_value(FFTConvolver1x1RefreshImpulseResponse(&one, 8, NULL, 16) == 0,
                "1x1 Refresh rejects NULL IR");
    check_value(FFTConvolver1x1RefreshImpulseResponse(&one, 8, bad, 16) == 0,
                "1x1 Refresh rejects NaN IR");
    check_value(FFTConvolver1x1RefreshImpulseResponse(&one, 524289, ir, 16) == 0,
                "1x1 Refresh rejects oversized block");
    FFTConvolver1x1Process(&one, input, y1, 20);
    check_value(all_close(y1, input, 20),
                "1x1 rejected Refresh leaves old IR untouched");
    check_value(FFTConvolver1x1RefreshImpulseResponse(&one, 8, gain_two, 16) == 1,
                "1x1 compatible Refresh succeeds");
    FFTConvolver1x1Process(&one, input, y1, 20);
    for (unsigned int i = 0; i < 20; ++i) expected[i] = input[i] * 2.0f;
    check_value(all_close(y1, expected, 20), "1x1 compatible Refresh updates IR");

    FFTConvolver2x2RefreshImpulseResponse(&scratch, &two, NULL, ir, 16);
    FFTConvolver2x2RefreshImpulseResponse(&scratch, &two, ir, bad, 16);
    FFTConvolver2x2RefreshImpulseResponse(&scratch, &two, ir, ir, 17);
    FFTConvolver2x2Process(&two, input, input, y1, y2, 20);
    check_value(all_close(y1, input, 20) && all_close(y2, input, 20),
                "2x2 rejected Refresh leaves old IR untouched");
    FFTConvolver2x2RefreshImpulseResponse(&scratch, &two, gain_two, gain_two, 16);
    FFTConvolver2x2Process(&two, input, input, y1, y2, 20);
    check_value(all_close(y1, expected, 20) && all_close(y2, expected, 20),
                "2x2 compatible Refresh updates both IRs");

    FFTConvolver2x2Free(&two);
    check_value(FFTConvolver2x2LoadImpulseResponse(&two, 16, ir, ir, 16) == 1,
                "load mismatched 2x2 geometry");
    FFTConvolver2x2RefreshImpulseResponse(&scratch, &two, gain_two, gain_two, 16);
    FFTConvolver2x2Process(&two, input, input, y1, y2, 20);
    check_value(all_close(y1, input, 20) && all_close(y2, input, 20),
                "2x2 Refresh rejects mismatched convolver geometry");

    FFTConvolver1x1Free(&one);
    FFTConvolver2x2Free(&scratch);
    FFTConvolver2x2Free(&two);
}

static void test_normal(void)
{
    float ir[8] = {1.0f};
    float half[8] = {0.5f};
    float quarter[8] = {0.25f};
    float three_quarters[8] = {0.75f};
    float input1[20];
    float input2[20];
    float expected1[20];
    float y1[20];
    float y2[20];
    fill_ramp(input1, 20);
    fill_ramp(input2, 20);
    for (unsigned int i = 0; i < 20; ++i) input2[i] *= -0.5f;

    FFTConvolver1x1 one;
    FFTConvolver2x2 two;
    FFTConvolver1x2 one_two;
    FFTConvolver2x4x2 two_four_two;
    FFTConvolver1x1Init(&one);
    FFTConvolver2x2Init(&two);
    FFTConvolver1x2Init(&one_two);
    FFTConvolver2x4x2Init(&two_four_two);
    check_value(FFTConvolver1x1LoadImpulseResponse(&one, 8, ir, 8) == 1,
                "normal 1x1 load");
    check_value(FFTConvolver2x2LoadImpulseResponse(&two, 8, ir, half, 8) == 1,
                "normal 2x2 load");
    check_value(FFTConvolver1x2LoadImpulseResponse(&one_two, 8, ir, half, 8) == 1,
                "normal 1x2 load");
    check_value(FFTConvolver2x4x2LoadImpulseResponse(
                    &two_four_two, 8, ir, quarter, half, three_quarters, 8) == 1,
                "normal 2x4x2 load");

    FFTConvolver1x1Process(&one, input1, y1, 20);
    check_value(all_close(y1, input1, 20), "1x1 delta convolution is exact");
    FFTConvolver2x2Process(&two, input1, input2, y1, y2, 20);
    check_value(all_close(y1, input1, 20), "2x2 left delta convolution is exact");
    for (unsigned int i = 0; i < 20; ++i) expected1[i] = input2[i] * 0.5f;
    check_value(all_close(y2, expected1, 20), "2x2 right gain convolution is exact");
    memcpy(y1, input1, sizeof(y1));
    memcpy(y2, input2, sizeof(y2));
    FFTConvolver2x2Process(&two, y1, y2, y1, y2, 20);
    check_value(all_close(y1, input1, 20) && all_close(y2, expected1, 20),
                "2x2 in-place convolution is exact");
    FFTConvolver1x1Free(&one);
    FFTConvolver2x2Free(&two);
    FFTConvolver1x2Free(&one_two);
    FFTConvolver2x4x2Free(&two_four_two);
}

/* Link support for FFTConvolver.c's precomputed Hartley tables. */
void fhtbitReversalTbl(unsigned *dst, unsigned int n)
{
    unsigned int bits = 0;
    for (unsigned int value = n; value > 1; value >>= 1) ++bits;
    for (unsigned int i = 0; i < n; ++i)
    {
        unsigned int value = i;
        unsigned int reversed = 0;
        for (unsigned int bit = 0; bit < bits; ++bit)
        {
            reversed = (reversed << 1) | (value & 1u);
            value >>= 1;
        }
        dst[i] = reversed;
    }
}

void fhtsinHalfTblFloat(float *dst, unsigned int n)
{
    const double two_pi_over_n = 6.283185307179586476925286766559 / n;
    for (unsigned int i = 0; i < n; ++i)
        dst[i] = (float)sin(two_pi_over_n * i);
}

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s uninitialized|oversized|invalid|refresh|normal\n",
                argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "uninitialized") == 0) test_uninitialized();
    else if (strcmp(argv[1], "oversized") == 0) test_oversized();
    else if (strcmp(argv[1], "invalid") == 0) test_invalid_load();
    else if (strcmp(argv[1], "refresh") == 0) test_refresh();
    else if (strcmp(argv[1], "normal") == 0) test_normal();
    else
    {
        fprintf(stderr, "unknown case: %s\n", argv[1]);
        return 2;
    }

    if (failures)
    {
        fprintf(stderr, "convolver_safety %s: %d/%d checks FAILED\n",
                argv[1], failures, checks);
        return 1;
    }
    printf("convolver_safety %s: %d checks passed\n", argv[1], checks);
    return 0;
}
