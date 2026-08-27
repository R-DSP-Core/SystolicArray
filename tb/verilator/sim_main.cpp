// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#include "Vcv32e40x_verilator_top.h"

#include <verilated.h>
#if VM_TRACE
#include <verilated_vcd_c.h>
#endif

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kMemoryBytes = 64u * 1024u;
constexpr uint32_t kMemoryWords = kMemoryBytes / 4u;
constexpr uint32_t kUartAddress = 0x10000000u;
constexpr uint32_t kTohostAddress = 0x10000004u;
constexpr uint64_t kTimeoutCycles = 10000u;
constexpr uint32_t kNop = 0x00000013u;

struct BusResponse {
    bool valid = false;
    uint32_t data = 0;
    bool error = false;
};

class Simulator {
  public:
    Simulator(int argc, char **argv)
        : context_(std::make_unique<VerilatedContext>()),
          top_(std::make_unique<Vcv32e40x_verilator_top>(context_.get())),
          memory_(kMemoryWords, kNop) {
        context_->commandArgs(argc, argv);
        initialize_inputs();
    }

    ~Simulator() {
#if VM_TRACE
        if (trace_) {
            trace_->close();
        }
#endif
        top_->final();
    }

    void load_builtin_smoke_test() {
        // 5 + 7 == 12; store/load; 5 * 7 == 35; then write PASS.
        static constexpr std::array<uint32_t, 18> program = {
            0x00500093, 0x00700113, 0x002081b3, 0x00001237,
            0x00322023, 0x00022283, 0x00c00313, 0x00629e63,
            0x022083b3, 0x02300413, 0x00839863, 0x10000537,
            0x00100593, 0x00b52223, 0x10000537, 0x00200593,
            0x00b52223, 0x0000006f,
        };
        std::copy(program.begin(), program.end(), memory_.begin());
    }

    bool load_firmware(const std::string &path) {
        std::ifstream input(path);
        if (!input) {
            std::cerr << "Unable to open firmware: " << path << '\n';
            return false;
        }

        std::fill(memory_.begin(), memory_.end(), kNop);
        uint64_t word = 0;
        std::size_t index = 0;
        while (input >> std::hex >> word) {
            if (word > 0xffffffffull) {
                std::cerr << "Invalid word in firmware: 0x" << std::hex << word << '\n';
                return false;
            }
            if (index == memory_.size()) {
                std::cerr << "Firmware exceeds 64 KiB memory\n";
                return false;
            }
            memory_[index++] = static_cast<uint32_t>(word);
        }
        if (!input.eof()) {
            std::cerr << "Malformed hexadecimal firmware: " << path << '\n';
            return false;
        }
        std::cout << "Loading firmware: " << path << '\n';
        return true;
    }

    bool enable_trace(const std::string &path) {
#if VM_TRACE
        context_->traceEverOn(true);
        trace_ = std::make_unique<VerilatedVcdC>();
        top_->trace(trace_.get(), 99);
        trace_->open(path.c_str());
        return true;
#else
        (void)path;
        std::cerr << "Tracing was requested, but the model was built without --trace\n";
        return false;
#endif
    }

    int run() {
        // Hold reset for eight complete clock cycles.
        for (int i = 0; i < 8; ++i) {
            tick(false);
        }
        top_->rst_ni = 1;

        while (!finished_ && cycle_count_ < kTimeoutCycles) {
            tick(true);
            ++cycle_count_;
        }

        if (!finished_) {
            std::cerr << "CV32E40X VERILATOR C++ TEST: TIMEOUT\n";
            return 1;
        }
        if (exit_status_ != 1u) {
            std::cerr << "CV32E40X VERILATOR C++ TEST: FAIL (code=0x"
                      << std::hex << exit_status_ << ")\n";
            return 1;
        }

        std::cout << "CV32E40X VERILATOR C++ TEST: PASS (cycles="
                  << std::dec << cycle_count_ << ")\n";
        return 0;
    }

  private:
    void initialize_inputs() {
        top_->clk_i = 0;
        top_->rst_ni = 0;
        top_->scan_cg_en_i = 1;
        top_->boot_addr_i = 0x00000000u;
        top_->dm_exception_addr_i = 0x00000180u;
        top_->dm_halt_addr_i = 0x00000100u;
        top_->mhartid_i = 0;
        top_->mimpid_patch_i = 0;
        top_->mtvec_addr_i = 0;
        top_->instr_gnt_i = 0;
        top_->instr_rvalid_i = 0;
        top_->instr_rdata_i = kNop;
        top_->instr_err_i = 0;
        top_->data_gnt_i = 0;
        top_->data_rvalid_i = 0;
        top_->data_rdata_i = 0;
        top_->data_err_i = 0;
        top_->data_exokay_i = 1;
        top_->time_i = 0;
        top_->irq_i = 0;
        top_->wu_wfe_i = 0;
        top_->clic_irq_i = 0;
        top_->clic_irq_id_i = 0;
        top_->clic_irq_level_i = 0;
        top_->clic_irq_priv_i = 0;
        top_->clic_irq_shv_i = 0;
        top_->fencei_flush_ack_i = 1;
        top_->debug_req_i = 0;
        top_->fetch_enable_i = 1;
    }

    void settle_grants() {
        // The memory accepts every request immediately. Re-evaluate once so
        // the combinational OBI grant is visible before the rising edge.
        top_->eval();
        top_->instr_gnt_i = top_->instr_req_o;
        top_->data_gnt_i = top_->data_req_o;
        top_->eval();
    }

    BusResponse make_instruction_response(bool request, uint32_t address) const {
        BusResponse response;
        response.valid = request;
        response.error = request &&
                         (address >= kMemoryBytes || (address & 3u) != 0u);
        response.data = address < kMemoryBytes ? memory_[address >> 2] : kNop;
        return response;
    }

    BusResponse make_data_response(bool request, bool write,
                                   uint32_t address) const {
        BusResponse response;
        response.valid = request;
        const bool mmio = address == kUartAddress || address == kTohostAddress;
        response.error = request && address >= kMemoryBytes && !mmio;
        if (request && !write && address < kMemoryBytes) {
            response.data = memory_[address >> 2];
        }
        return response;
    }

    void handle_accepted_data_request(bool request, bool write, uint32_t address,
                                      uint8_t byte_enable, uint32_t write_data) {
        if (!request || !write) {
            return;
        }

        if (address < kMemoryBytes) {
            uint32_t &word = memory_[address >> 2];
            for (unsigned byte = 0; byte < 4; ++byte) {
                if ((byte_enable >> byte) & 1u) {
                    const uint32_t mask = 0xffu << (byte * 8u);
                    word = (word & ~mask) | (write_data & mask);
                }
            }
            return;
        }

        if (address == kUartAddress) {
            unsigned byte = 0;
            while (byte < 4 && ((byte_enable >> byte) & 1u) == 0u) {
                ++byte;
            }
            if (byte == 4) {
                byte = 0;
            }
            std::cout.put(static_cast<char>((write_data >> (byte * 8u)) & 0xffu));
            std::cout.flush();
        } else if (address == kTohostAddress) {
            exit_status_ = write_data;
            finished_ = true;
        }
    }

    void drive_response_inputs() {
        top_->instr_rvalid_i = instr_response_.valid;
        top_->instr_rdata_i = instr_response_.data;
        top_->instr_err_i = instr_response_.error;
        top_->data_rvalid_i = data_response_.valid;
        top_->data_rdata_i = data_response_.data;
        top_->data_err_i = data_response_.error;
    }

    void evaluate_and_dump() {
        top_->eval();
#if VM_TRACE
        if (trace_) {
            trace_->dump(context_->time());
        }
#endif
    }

    void half_cycle(bool clock_high) {
        top_->clk_i = clock_high;
        evaluate_and_dump();
        context_->timeInc(5);
    }

    void tick(bool count_time) {
        top_->clk_i = 0;
        top_->time_i = cycle_count_;
        drive_response_inputs();
        settle_grants();

        const bool instr_request = top_->instr_req_o && top_->instr_gnt_i;
        const uint32_t instr_address = top_->instr_addr_o;
        const bool data_request = top_->data_req_o && top_->data_gnt_i;
        const bool data_write = top_->data_we_o;
        const uint32_t data_address = top_->data_addr_o;
        const uint8_t data_be = top_->data_be_o;
        const uint32_t data_wdata = top_->data_wdata_o;

        half_cycle(true);
        handle_accepted_data_request(data_request, data_write, data_address,
                                     data_be, data_wdata);

        instr_response_ = make_instruction_response(instr_request, instr_address);
        data_response_ = make_data_response(data_request, data_write, data_address);
        if (!count_time) {
            instr_response_ = {};
            data_response_ = {};
        }
        half_cycle(false);
    }

    std::unique_ptr<VerilatedContext> context_;
    std::unique_ptr<Vcv32e40x_verilator_top> top_;
    std::vector<uint32_t> memory_;
    BusResponse instr_response_;
    BusResponse data_response_;
    uint64_t cycle_count_ = 0;
    uint32_t exit_status_ = 0;
    bool finished_ = false;
#if VM_TRACE
    std::unique_ptr<VerilatedVcdC> trace_;
#endif
};

std::string argument_value(int argc, char **argv, const std::string &prefix) {
    for (int i = 1; i < argc; ++i) {
        const std::string argument(argv[i]);
        if (argument.rfind(prefix, 0) == 0) {
            return argument.substr(prefix.size());
        }
    }
    return {};
}

bool has_argument(int argc, char **argv, const std::string &argument) {
    for (int i = 1; i < argc; ++i) {
        if (argv[i] == argument) {
            return true;
        }
    }
    return false;
}

}  // namespace

int main(int argc, char **argv) {
    Simulator simulator(argc, argv);

    const std::string firmware = argument_value(argc, argv, "+firmware=");
    if (firmware.empty()) {
        simulator.load_builtin_smoke_test();
    } else if (!simulator.load_firmware(firmware)) {
        return 1;
    }

    if (has_argument(argc, argv, "+trace") &&
        !simulator.enable_trace("build/verilator/cv32e40x_verilator_top.vcd")) {
        return 1;
    }

    return simulator.run();
}
