// SPDX-License-Identifier: Apache-2.0

#include "runtime.h"

static volatile int a[2][2] = {{1, 2}, {3, 4}};
static volatile int b[2][2] = {{5, 6}, {7, 8}};
static volatile int c[2][2];

int main(void)
{
    static const int expected[2][2] = {{19, 22}, {43, 50}};
    int i;
    int j;
    int k;

    tb_puts("Running 2x2 matrix multiplication...");
    for (i = 0; i < 2; ++i) {
        for (j = 0; j < 2; ++j) {
            int sum = 0;
            for (k = 0; k < 2; ++k) {
                sum += a[i][k] * b[k][j];
            }
            c[i][j] = sum;
        }
    }

    for (i = 0; i < 2; ++i) {
        for (j = 0; j < 2; ++j) {
            if (c[i][j] != expected[i][j]) return i * 2 + j + 1;
        }
    }

    tb_puts("Matrix result: [19 22; 43 50]");
    return 0;
}
