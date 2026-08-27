// SPDX-License-Identifier: Apache-2.0

#include "runtime.h"

static volatile uint32_t source[16];
static volatile uint32_t destination[16];

int main(void)
{
    uint32_t checksum = 0;
    int i;

    tb_puts("Running memory test...");
    for (i = 0; i < 16; ++i) {
        source[i] = (uint32_t)(i * i + 3);
        destination[i] = source[i];
    }

    for (i = 0; i < 16; ++i) {
        if (destination[i] != (uint32_t)(i * i + 3)) return i + 1;
        checksum += destination[i];
    }

    tb_puts("Memory checksum:");
    tb_print_hex(checksum);
    tb_putchar('\n');
    return checksum == 1288u ? 0 : 17;
}
