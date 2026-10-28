#include "Vboard_probe.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>

static double simulation_time = 0;
double sc_time_stamp() { return simulation_time; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vboard_probe model;
    model.sys_clk = 0;
    model.key0_n = 1;
    const std::uint64_t limit = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 600000000ULL;
    std::uint64_t sample_cycle = 0;
    unsigned int bit_index = 0;
    unsigned int received = 0;
    unsigned int characters = 0;
    bool receiving = false;
    bool previous_tx = true;
#ifdef ACORE_DUAL
    std::uint64_t first_retired = 0;
    std::uint64_t second_retired = 0;
    std::uint64_t start_cycle = 0;
    std::uint64_t start_retired = 0;
    std::uint64_t start_second = 0;
    std::uint64_t measured_cycles = 0;
    std::uint64_t measured_retired = 0;
    std::uint64_t measured_second = 0;
    unsigned int samples = 0;
#endif
    for (std::uint64_t cycle = 0; cycle < limit; ++cycle) {
        simulation_time = static_cast<double>(cycle) * 40;
        model.sys_clk = 0;
        model.eval();
        const bool exit_write = model.dev_we && model.dev_addr == 0x30000;
        const std::uint32_t exit_code = model.dev_data;
#ifdef ACORE_DUAL
        if (model.cycle_sample) {
            if (samples == 0) {
                start_cycle = cycle;
                start_retired = first_retired + second_retired;
                start_second = second_retired;
            } else if (samples == 1) {
                measured_cycles = cycle - start_cycle;
                measured_retired = first_retired + second_retired - start_retired;
                measured_second = second_retired - start_second;
            }
            ++samples;
        }
        first_retired += model.retire_first;
        second_retired += model.retire_second;
#endif
        simulation_time += 20;
        model.sys_clk = 1;
        model.eval();
        if (model.bus_error || model.led1) {
            std::cerr << "Unexpected bus error at cycle " << cycle << '\n';
            return 1;
        }
        const bool tx = model.uart_tx;
        if (!receiving && previous_tx && !tx) {
            receiving = true;
            bit_index = 0;
            received = 0;
            sample_cycle = cycle + 217 + 108;
        }
        if (receiving && cycle == sample_cycle) {
            if (bit_index < 8) {
                received |= static_cast<unsigned int>(tx) << bit_index;
                ++bit_index;
                sample_cycle += 217;
            } else {
                if (!tx) {
                    std::cerr << "UART stop bit failed\n";
                    return 1;
                }
                std::cout << static_cast<char>(received);
                ++characters;
                receiving = false;
            }
        }
        previous_tx = tx;
        if (exit_write) {
            if (exit_code != 0 || !model.led0 || characters < 100) {
                std::cerr << "CoreMark exit/LED/UART failed\n";
                return 1;
            }
            std::cout << "PASS: CoreMark board exit_code=0; " << characters
                      << " UART characters; " << cycle << " cycles\n";
#ifdef ACORE_DUAL
            std::cout << "DUAL RETIRED: " << first_retired << " first, " << second_retired << " second\n";
            std::cout << "BENCH COUNTERS: cycles=" << measured_cycles << " retired=" << measured_retired
                      << " second=" << measured_second << '\n';
            if (second_retired == 0 || samples != 2)
                return 1;
#endif
            model.final();
            return 0;
        }
        if (Verilated::gotFinish())
            break;
    }
    std::cerr << "CoreMark simulation timed out\n";
    return 1;
}
