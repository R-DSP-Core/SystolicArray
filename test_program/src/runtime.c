// SPDX-License-Identifier: Apache-2.0

#include "runtime.h"

#define UART_ADDR   0x10000000u
#define TOHOST_ADDR 0x10000004u

static uint64_t perf_cycle_start;
static uint64_t perf_instret_start;

void tb_putchar(char c)
{
    *(volatile uint8_t *)UART_ADDR = (uint8_t)c;
}

void tb_puts(const char *text)
{
    while (*text != '\0') {
        tb_putchar(*text++);
    }
    tb_putchar('\n');
}

void tb_print_dec(int value)
{
    char buffer[12];
    unsigned int magnitude;
    int index = 0;

    if (value < 0) {
        tb_putchar('-');
        magnitude = (unsigned int)(-(value + 1)) + 1u;
    } else {
        magnitude = (unsigned int)value;
    }

    do {
        buffer[index++] = (char)('0' + (magnitude % 10u));
        magnitude /= 10u;
    } while (magnitude != 0u);

    while (index != 0) {
        tb_putchar(buffer[--index]);
    }
}

void tb_print_hex(uint32_t value)
{
    static const char digits[] = "0123456789abcdef";
    int shift;

    tb_putchar('0');
    tb_putchar('x');
    for (shift = 28; shift >= 0; shift -= 4) {
        tb_putchar(digits[(value >> shift) & 0xfu]);
    }
}

uint64_t tb_read_mcycle(void)
{
    uint32_t high_before;
    uint32_t low;
    uint32_t high_after;

    do {
        __asm__ volatile ("csrr %0, mcycleh" : "=r"(high_before) :: "memory");
        __asm__ volatile ("csrr %0, mcycle"  : "=r"(low) :: "memory");
        __asm__ volatile ("csrr %0, mcycleh" : "=r"(high_after) :: "memory");
    } while (high_before != high_after);

    return ((uint64_t)high_after << 32) | low;
}

uint64_t tb_read_minstret(void)
{
    uint32_t high_before;
    uint32_t low;
    uint32_t high_after;

    do {
        __asm__ volatile ("csrr %0, minstreth" : "=r"(high_before) :: "memory");
        __asm__ volatile ("csrr %0, minstret"  : "=r"(low) :: "memory");
        __asm__ volatile ("csrr %0, minstreth" : "=r"(high_after) :: "memory");
    } while (high_before != high_after);

    return ((uint64_t)high_after << 32) | low;
}

static void tb_print_u64_hex(uint64_t value)
{
    static const char digits[] = "0123456789abcdef";
    uint32_t high = (uint32_t)(value >> 32);
    uint32_t low = (uint32_t)value;
    int shift;

    tb_putchar('0');
    tb_putchar('x');
    for (shift = 28; shift >= 0; shift -= 4) {
        tb_putchar(digits[(high >> shift) & 0xfu]);
    }
    for (shift = 28; shift >= 0; shift -= 4) {
        tb_putchar(digits[(low >> shift) & 0xfu]);
    }
}

static void tb_print_cpi(uint64_t cycles, uint64_t instructions)
{
    uint32_t cycle_high = (uint32_t)(cycles >> 32);
    uint32_t inst_high = (uint32_t)(instructions >> 32);
    uint32_t cycle_low = (uint32_t)cycles;
    uint32_t inst_low = (uint32_t)instructions;
    uint32_t whole;
    uint32_t fraction;

    if ((cycle_high != 0u) || (inst_high != 0u) || (inst_low == 0u)) {
        tb_puts("n/a");
        return;
    }

    whole = cycle_low / inst_low;
    fraction = ((cycle_low % inst_low) * 1000u) / inst_low;
    tb_print_dec((int)whole);
    tb_putchar('.');
    if (fraction < 100u) tb_putchar('0');
    if (fraction < 10u) tb_putchar('0');
    tb_print_dec((int)fraction);
    tb_putchar('\n');
}

void tb_perf_start(void)
{
    /* CV32E40X resets mcountinhibit with CY and IR set, so explicitly
       enable the architectural cycle and retired-instruction counters. */
    __asm__ volatile ("csrwi mcountinhibit, 0" ::: "memory");
    perf_cycle_start = tb_read_mcycle();
    perf_instret_start = tb_read_minstret();
}

void tb_perf_stop(void)
{
    uint64_t cycles = tb_read_mcycle() - perf_cycle_start;
    uint64_t instructions = tb_read_minstret() - perf_instret_start;

    tb_puts("RTL performance counters (main):");
    tb_puts("  mcycle delta:");
    tb_print_u64_hex(cycles);
    tb_putchar('\n');
    tb_puts("  minstret delta:");
    tb_print_u64_hex(instructions);
    tb_putchar('\n');
    tb_puts("  CPI:");
    tb_print_cpi(cycles, instructions);
}

void tb_exit(int code)
{
    uint32_t status = code == 0 ? 1u : (0x80000000u | (uint32_t)code);
    *(volatile uint32_t *)TOHOST_ADDR = status;
    for (;;) {
        __asm__ volatile ("wfi");
    }
}
