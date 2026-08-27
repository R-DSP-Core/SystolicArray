// SPDX-License-Identifier: Apache-2.0

#ifndef CV32E40X_VERILATOR_RUNTIME_H
#define CV32E40X_VERILATOR_RUNTIME_H

typedef unsigned char uint8_t;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;

void tb_putchar(char c);
void tb_puts(const char *text);
void tb_print_dec(int value);
void tb_print_hex(uint32_t value);
uint64_t tb_read_mcycle(void);
uint64_t tb_read_minstret(void);
void tb_perf_start(void);
void tb_perf_stop(void);
void tb_exit(int code) __attribute__((noreturn));

#endif
