// SPDX-License-Identifier: Apache-2.0

#include "runtime.h"

int main(void)
{
    volatile int a = 84;
    volatile int b = 7;

    tb_puts("Running arithmetic test...");
    if (a + b != 91) return 1;
    if (a - b != 77) return 2;
    if (a * b != 588) return 3;
    if (a / b != 12) return 4;
    if (a % b != 0) return 5;
    if ((a & 15) != 4) return 6;
    if ((a | b) != 87) return 7;
    if ((a ^ b) != 83) return 8;
    if ((a << 2) != 336) return 9;
    if ((a >> 2) != 21) return 10;

    tb_puts("Arithmetic test passed.");
    return 0;
}
