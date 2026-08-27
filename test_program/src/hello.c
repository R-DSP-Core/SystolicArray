// SPDX-License-Identifier: Apache-2.0

#include "runtime.h"

int main(void)
{
    volatile int a = 20;
    volatile int b = 22;
    // int answer = a + b;
    int x;

    asm volatile(
        ".insn r CUSTOM_0, 1, 2, %[rd], %[rs1], %[rs2]"
        : [rd] "=r" (x)
        : [rs1] "r" (a),
          [rs2] "r" (b)
    );

    tb_puts("Hello from CV32E40X!");
    tb_puts("The answer should be 42:");
    tb_print_dec(x);
    tb_putchar('\n');

    return x == 42 ? 0 : 1;
}
