// Untimed C++ driver, compatible with Verilator 4.x and 5.x.
#include "Vddr3.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>

using Word = std::array<uint32_t, 4>;
static Vddr3 *model = nullptr;
#define dut (*model)
static unsigned checks = 0, cycles = 0;
double sc_time_stamp() { return cycles * 8.0; }

static void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
    ++checks;
}
static Word pattern(unsigned number) {
    Word result{};
    for (unsigned lane = 0; lane < 16; ++lane)
        result[lane / 4] |= ((number * 37u ^ lane * 19u ^ (number >> 4)) & 255u)
                            << ((lane % 4) * 8);
    return result;
}
static void put(const Word &word) {
    for (int i = 0; i < 4; ++i) dut.axi_wdata[i] = word[i];
}
struct Sample {
    bool aw, ar, w, wl, r, rl;
    unsigned wid, rid;
    Word data;
};
static Sample tick() {
    if (++cycles > 500000) throw std::runtime_error("simulation timeout");
    dut.ref_clk = 0; dut.apb_clk = 0; dut.eval();
    Sample s{bool(dut.axi_awready && dut.axi_awvalid),
             bool(dut.axi_arready && dut.axi_arvalid),
             bool(dut.axi_wready), bool(dut.axi_wusero_last),
             bool(dut.axi_rvalid), bool(dut.axi_rlast),
             unsigned(dut.axi_wusero_id), unsigned(dut.axi_rid), {}};
    for (int i = 0; i < 4; ++i) s.data[i] = dut.axi_rdata[i];
    dut.ref_clk = 1; dut.apb_clk = 1; dut.eval();
    return s;
}
static void reset() {
    dut.resetn = 0; dut.apb_rst_n = 0;
    dut.axi_awvalid = 0; dut.axi_arvalid = 0;
    for (int i = 0; i < 5; ++i) tick();
    require(!dut.axi_wready && !dut.axi_rvalid && !dut.ddr_init_done, "reset outputs");
    dut.resetn = 1; dut.apb_rst_n = 1;
    while (!dut.ddr_init_done) tick();
}
static void aw(uint32_t address, unsigned count, unsigned id) {
    dut.axi_awaddr = address; dut.axi_awlen = count - 1;
    dut.axi_awuser_id = id; dut.axi_awuser_ap = id & 1; dut.axi_awvalid = 1;
    while (!tick().aw) {}
    dut.axi_awvalid = 0;
}
static void ar(uint32_t address, unsigned count, unsigned id) {
    dut.axi_araddr = address; dut.axi_arlen = count - 1;
    dut.axi_aruser_id = id; dut.axi_aruser_ap = id & 1; dut.axi_arvalid = 1;
    while (!tick().ar) {}
    dut.axi_arvalid = 0;
}
static void write(uint32_t address, unsigned count, unsigned number, unsigned id) {
    put(pattern(number));
    aw(address, count, id);
    for (unsigned beat = 0; beat < count;) {
        put(pattern(number + beat));
        Sample s = tick();
        if (s.w) {
            require(s.wid == id && s.wl == (beat == count - 1), "write ID/last");
            ++beat;
        }
    }
}
static void receive(const Word &expected, unsigned id, bool last) {
    Sample s;
    do { s = tick(); } while (!s.r);
    require(s.data == expected && s.rid == id && s.rl == last, "read data/ID/last");
}
static void read(uint32_t address, unsigned count, unsigned number, unsigned id) {
    ar(address, count, id);
    for (unsigned beat = 0; beat < count; ++beat)
        receive(pattern(number + beat), id, beat == count - 1);
}
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    try {
        model = new Vddr3;
        dut.dbg_ddrphy_rst_n = 1;
        dut.axi_wstrb = 0xffff;
        reset();
        for (unsigned length = 1; length <= 16; ++length) {
            write(length * 1024, length, length * 100, length - 1);
            read(length * 1024, length, length * 100, 16 - length);
        }
        write(0x400, 2, 7000, 3);
        read(0x408, 1, 7001, 11);
        write(0x8000400, 1, 8000, 4);
        read(0x400, 1, 7000, 2);
        read(0x8000400, 1, 8000, 14);
        write(0x3f8, 2, 9000, 15);
        read(0x3f8, 1, 9000, 1); read(0, 1, 9001, 2); read(0x400, 1, 7000, 3);
        write(0x9000, 1, 10000, 5);
        Word expected = pattern(10000);
        for (unsigned lane = 0; lane < 16; ++lane) {
            dut.axi_wstrb = 1u << lane;
            write(0x9000, 1, 10001 + lane, 6);
            const Word next = pattern(10001 + lane);
            const unsigned shift = (lane % 4) * 8, index = lane / 4;
            expected[index] = (expected[index] & ~(255u << shift)) | (next[index] & (255u << shift));
            ar(0x9000, 1, 7); receive(expected, 7, true);
        }
        dut.axi_wstrb = 0; write(0x9000, 1, 12345, 8);
        ar(0x9000, 1, 9); receive(expected, 9, true);
        dut.axi_wstrb = 0xffff;
        // Pipeline forty addresses while the independent W consumer advances.
        unsigned submitted = 0, completed = 0;
        while (completed < 40) {
            dut.axi_awvalid = submitted < 40;
            dut.axi_awaddr = 0x8000 + submitted * 8;
            dut.axi_awlen = 0; dut.axi_awuser_id = submitted & 15;
            put(pattern(20000 + completed));
            Sample s = tick();
            if (s.aw) ++submitted;
            if (s.w) {
                require(s.wl && s.wid == (completed & 15), "queued write ID/last");
                ++completed;
            }
        }
        dut.axi_awvalid = 0;
        submitted = 0; completed = 0;
        while (completed < 40) {
            dut.axi_arvalid = submitted < 40;
            dut.axi_araddr = 0x8000 + submitted * 8;
            dut.axi_arlen = 0; dut.axi_aruser_id = (submitted + 3) & 15;
            Sample s = tick();
            if (s.ar) ++submitted;
            if (s.r) {
                require(s.rl && s.rid == ((completed + 3) & 15) && s.data == pattern(20000 + completed),
                        "queued read data/ID/last");
                ++completed;
            }
        }
        dut.axi_arvalid = 0;
        reset();
        read(0x8000400, 1, 8000, 1);
        for (int i = 0; i < 40; ++i) {
            Sample s = tick();
            require(!s.w && !s.wl && !s.r && !s.rl, "extra beat after completion");
        }
        dut.final();
        delete model; model = nullptr;
        std::cout << "PASS verilator_ddr3 checks=" << checks << " cycles=" << cycles << '\n';
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL: " << e.what() << " cycle=" << cycles << '\n';
        return 1;
    }
}
