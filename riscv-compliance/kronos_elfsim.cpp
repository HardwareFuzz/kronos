// Simple Verilator runner that loads an ELF32 (RV32) into the
// generic_spram inside kronos_compliance_top and runs for a
// configurable number of cycles. Optionally dumps VCD.
//
// Usage:
//   kronos_elfsim <program.elf> [--vcd out.vcd] [--max-cycles N] [--mem-kb KB]
//
// Notes:
// - Works with kronos_compliance_top (generic_spram default 8KB).
// - The memory is mirrored across the address space; addresses are
//   indexed by low bits only (addr[2+:NWORDS_WIDTH]) just like the SV.

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <verilated.h>
#include <verilated_vcd_c.h>
#include <verilated_cov.h>

#include "kronos_compliance_top.h"
#include "kronos_compliance_top___024root.h"

using std::cerr;
using std::cout;
using std::endl;
using std::ifstream;
using std::runtime_error;
using std::string;
using std::vector;

// ELF32 structures (little-endian)
struct Elf32_Ehdr {
  unsigned char e_ident[16];
  uint16_t e_type;
  uint16_t e_machine;
  uint32_t e_version;
  uint32_t e_entry;
  uint32_t e_phoff;
  uint32_t e_shoff;
  uint32_t e_flags;
  uint16_t e_ehsize;
  uint16_t e_phentsize;
  uint16_t e_phnum;
  uint16_t e_shentsize;
  uint16_t e_shnum;
  uint16_t e_shstrndx;
};

struct Elf32_Phdr {
  uint32_t p_type;
  uint32_t p_offset;
  uint32_t p_vaddr;
  uint32_t p_paddr;
  uint32_t p_filesz;
  uint32_t p_memsz;
  uint32_t p_flags;
  uint32_t p_align;
};

static const uint32_t PT_LOAD = 1;
static const uint8_t ELFMAG0 = 0x7f;
static const uint8_t ELFMAG1 = 'E';
static const uint8_t ELFMAG2 = 'L';
static const uint8_t ELFMAG3 = 'F';
static const uint8_t ELFCLASS32 = 1;
static const uint8_t ELFDATA2LSB = 1;
static const uint16_t EM_RISCV = 243; // for reference only

class Sim {
 public:
  explicit Sim(uint32_t mem_kb)
      : top_(new kronos_compliance_top),
        trace_(nullptr),
        ticks_(0),
        mem_words_(256u * mem_kb),
        mem_mask_(mem_words_ - 1u),
        log_reg_(false),
        log_mem_(false),
        log_trap_(false),
        debug_reg_(false),
        log_out_(&std::cout) {
    top_->clk = 0;
    top_->rstz = 1;
  }

  ~Sim() { delete top_; }

  void reset(unsigned cycles = 5) {
    top_->rstz = 0;
    for (unsigned i = 0; i < cycles; ++i) tick();
    top_->rstz = 1;
    for (unsigned i = 0; i < cycles; ++i) tick();
  }

  void start_trace(const string &vcd_file) {
    if (vcd_file.empty()) return;
    Verilated::traceEverOn(true);
    trace_ = new VerilatedVcdC;
    top_->trace(trace_, 99);
    trace_->open(vcd_file.c_str());
  }

  void stop_trace() {
    if (trace_) {
      trace_->close();
      delete trace_;
      trace_ = nullptr;
    }
  }

  void tick() {
    top_->clk = !top_->clk;
    top_->eval();
    // sample after posedge
    if (top_->clk) log_sample_posedge_();
    if (trace_) trace_->dump(ticks_);
    ++ticks_;
  }

  uint64_t ticks() const { return ticks_; }

  // Load ELF PT_LOAD segments into internal memory array.
  // The SV memory uses word addressing of low bits only; we mirror via mask.
  void load_elf(const string &elf_path) {
    ifstream f(elf_path, std::ios::binary);
    if (!f) throw runtime_error("Failed to open ELF: " + elf_path);

    Elf32_Ehdr eh{};
    f.read(reinterpret_cast<char *>(&eh), sizeof(eh));
    if (!f) throw runtime_error("Failed to read ELF header");

    if (!(eh.e_ident[0] == ELFMAG0 && eh.e_ident[1] == ELFMAG1 &&
          eh.e_ident[2] == ELFMAG2 && eh.e_ident[3] == ELFMAG3))
      throw runtime_error("Not an ELF file");
    if (eh.e_ident[4] != ELFCLASS32)
      throw runtime_error("Unsupported ELF class (need 32-bit)");
    if (eh.e_ident[5] != ELFDATA2LSB)
      throw runtime_error("Unsupported ELF endianness (need little-endian)");

    // Load each PT_LOAD segment
    if (eh.e_phentsize != sizeof(Elf32_Phdr))
      throw runtime_error("Unexpected phdr size");

    for (uint16_t i = 0; i < eh.e_phnum; ++i) {
      f.seekg(eh.e_phoff + i * sizeof(Elf32_Phdr), std::ios::beg);
      Elf32_Phdr ph{};
      f.read(reinterpret_cast<char *>(&ph), sizeof(ph));
      if (!f) throw runtime_error("Failed to read program header");
      if (ph.p_type != PT_LOAD) continue;

      const uint32_t base = (ph.p_paddr ? ph.p_paddr : ph.p_vaddr);
      if (ph.p_filesz) {
        vector<uint8_t> buf(ph.p_filesz);
        f.seekg(ph.p_offset, std::ios::beg);
        f.read(reinterpret_cast<char *>(buf.data()), ph.p_filesz);
        if (!f) throw runtime_error("Failed to read segment data");

        // Write into MEM as little-endian words
        for (uint32_t off = 0; off < ph.p_filesz; off += 4) {
          uint32_t word = 0;
          for (int b = 0; b < 4 && (off + b) < ph.p_filesz; ++b) {
            word |= static_cast<uint32_t>(buf[off + b]) << (8 * b);
          }
          write_mem_word(base + off, word);
        }
      }

      // Zero BSS region beyond p_filesz up to p_memsz
      if (ph.p_memsz > ph.p_filesz) {
        const uint32_t sz = ph.p_memsz - ph.p_filesz;
        const uint32_t start = base + ph.p_filesz;
        for (uint32_t off = 0; off < sz; off += 4) {
          write_mem_word(start + off, 0);
        }
      }
    }
  }

  void run(uint64_t max_cycles, bool watch_tohost, uint32_t tohost_addr, uint32_t pass_value) {
    for (uint64_t i = 0; i < max_cycles; ++i) {
      tick();
      // Sample tohost on posedge.
      // Use architectural store events (per-core) instead of the top-level bus to avoid
      // coupling to memory arbitration/latency details.
      if (watch_tohost && top_->clk) {
        auto& R = *(top_->rootp);
        for (int h = 0; h < 2; ++h) {
          if (!R.kronos_compliance_top__DOT__trace_mem_vld[h]) continue;
          const uint32_t addr = R.kronos_compliance_top__DOT__trace_mem_addr[h];
          const uint32_t data = R.kronos_compliance_top__DOT__trace_mem_data[h];
          const uint32_t mask = R.kronos_compliance_top__DOT__trace_mem_mask[h] & 0xF;
          if (addr == tohost_addr && mask == 0xF && data == pass_value) {
            cout << "TOHOST write detected at 0x" << std::hex << tohost_addr
                 << " value=0x" << pass_value << std::dec << " at tick " << ticks_ << "\n";
            return;
          }
        }
      }
    }
  }

  void enable_logging(bool log_reg, bool log_mem, bool log_trap, bool debug_reg, const string& logfile) {
    log_reg_ = log_reg;
    log_mem_ = log_mem;
    log_trap_ = log_trap;
    debug_reg_ = debug_reg;
    if (!logfile.empty()) {
      log_of_ = std::make_unique<std::ofstream>(logfile);
      log_out_ = log_of_.get();
    }
  }

 private:
   void log_sample_posedge_() {
     if (!(log_reg_ || log_mem_ || log_trap_)) return;
     auto& R = *(top_->rootp);

     // The SV top exposes per-core trace signals via `public_flat` arrays.
     // We log each event as a single line, keeping the same format expected
     // by riscv_fuzz_test's Kronos parser.
     for (int h = 0; h < 2; ++h) {
        if (log_reg_ && R.kronos_compliance_top__DOT__trace_reg_vld[h]) {
          const uint32_t pc = R.kronos_compliance_top__DOT__trace_reg_pc[h];
          const uint32_t rd = R.kronos_compliance_top__DOT__trace_reg_rd[h] & 0x1f;
          const uint32_t val = R.kronos_compliance_top__DOT__trace_reg_data[h];
          const uint32_t ir = R.kronos_compliance_top__DOT__trace_reg_ir[h];
          if (rd != 0) {
            (*log_out_) << "[REG] pc=0x" << std::hex << pc
                        << " x" << std::dec << rd
                        << " <= 0x" << std::hex << val
                        << " instr=0x" << ir;

            if (debug_reg_) {
              const uint32_t op1 = R.kronos_compliance_top__DOT__trace_reg_op1[h];
              const uint32_t op2 = R.kronos_compliance_top__DOT__trace_reg_op2[h];
              (*log_out_) << " op1=0x" << std::hex << op1
                          << " op2=0x" << std::hex << op2;
            }

            (*log_out_) << std::dec << "\n";
          }
        }

       if (log_mem_ && R.kronos_compliance_top__DOT__trace_mem_vld[h]) {
         const uint32_t pc = R.kronos_compliance_top__DOT__trace_mem_pc[h];
         const uint32_t addr = R.kronos_compliance_top__DOT__trace_mem_addr[h];
         const uint32_t data = R.kronos_compliance_top__DOT__trace_mem_data[h];
         const uint32_t mask = R.kronos_compliance_top__DOT__trace_mem_mask[h] & 0xF;
         (*log_out_) << "[MEMW] pc=0x" << std::hex << pc
                     << " addr=0x" << addr
                     << " data=0x" << data
                     << " mask=0x" << mask << std::dec << "\n";
       }

       if (log_trap_ && R.kronos_compliance_top__DOT__trace_trap_vld[h]) {
         const uint32_t pc = R.kronos_compliance_top__DOT__trace_trap_pc[h];
         const uint32_t cause = R.kronos_compliance_top__DOT__trace_trap_cause[h];
         (*log_out_) << "[TRAP] pc=0x" << std::hex << pc
                     << " cause=0x" << cause << std::dec << "\n";
       }
     }
   }

  void write_mem_word(uint32_t addr, uint32_t data) {
    // Word addressing; low bits used per generic_spram (addr[2+:NWORDS_WIDTH])
    const uint32_t idx = ((addr >> 2) & mem_mask_);
    top_->rootp->kronos_compliance_top__DOT__u_mem__DOT__MEM[idx] = data;
  }

  kronos_compliance_top *top_;
  VerilatedVcdC *trace_;
  uint64_t ticks_;
  uint32_t mem_words_;
  uint32_t mem_mask_;
  bool log_reg_;
  bool log_mem_;
  bool log_trap_;
  bool debug_reg_;
   std::ostream* log_out_;
   std::unique_ptr<std::ofstream> log_of_;
};

static void print_usage() {
  cout << "Usage:\n"
           "  kronos_elfsim <program.elf> [--vcd out.vcd] [--max-cycles N] "
           "[--mem-kb KB] [--covfile path] [--debug-reg]\n";
}

int main(int argc, char **argv) {
  if (argc < 2) {
    print_usage();
    return 1;
  }

  Verilated::commandArgs(argc, argv);

  string elf = argv[1];
  string vcd;
  uint64_t max_cycles = 100000;   // reasonable default for smoke runs
  uint32_t mem_kb = 8;            // matches kronos_compliance_top generic_spram
  bool watch_tohost = false;
  uint32_t tohost_addr = 0;
  uint32_t pass_value = 1;
  bool log_reg=false, log_mem=false, log_trap=false;
  bool debug_reg=false;
  string log_file;
  string cov_file = "logs/coverage.dat";
  bool cov_file_cli = false;  // track if user passed --covfile

  for (int i = 2; i < argc; ++i) {
    string a = argv[i];
    if (a == "--vcd" && (i + 1) < argc) {
      vcd = argv[++i];
    } else if (a == "--max-cycles" && (i + 1) < argc) {
      max_cycles = std::stoull(argv[++i]);
    } else if (a == "--mem-kb" && (i + 1) < argc) {
      mem_kb = static_cast<uint32_t>(std::stoul(argv[++i]));
    } else if (a == "--tohost" && (i + 1) < argc) {
      string s = argv[++i];
      watch_tohost = true;
      tohost_addr = static_cast<uint32_t>(std::stoul(s, nullptr, 0));
    } else if (a == "--pass-value" && (i + 1) < argc) {
      string s = argv[++i];
      pass_value = static_cast<uint32_t>(std::stoul(s, nullptr, 0));
    } else if (a == "--log" && (i + 1) < argc) {
      string s = argv[++i];
      std::stringstream ss(s);
      string item;
      while (std::getline(ss, item, ',')) {
        if (item == "all") { log_reg=log_mem=log_trap=true; }
        else if (item == "reg") log_reg = true;
        else if (item == "mem") log_mem = true;
        else if (item == "trap") log_trap = true;
      }
    } else if (a == "--log-file" && (i + 1) < argc) {
      log_file = argv[++i];
    } else if (a == "--debug-reg") {
      debug_reg = true;
    } else if (a == "--covfile" && (i + 1) < argc) {
      cov_file = argv[++i];
      cov_file_cli = true;
    } else {
      cerr << "Unknown or incomplete option: " << a << endl;
      print_usage();
      return 1;
    }
  }

#if !VM_COVERAGE
  (void)cov_file;
#endif

  try {
#if VM_COVERAGE
    // Honor +covfile=<path> only if user did not pass --covfile.
    if (!cov_file_cli) {
      if (const char* cov_arg = Verilated::commandArgsPlusMatch("covfile=")) {
        const char* val = cov_arg + std::strlen("+covfile=");
        if (*val) cov_file = val;
      }
    }
    // Emit the final coverage path so it is obvious which file will be written.
    cout << "Coverage output: " << cov_file << endl;
    const auto slash_pos = cov_file.find_last_of('/');
    if (slash_pos != std::string::npos && slash_pos != 0) {
      Verilated::mkdir(cov_file.substr(0, slash_pos).c_str());
    } else {
      Verilated::mkdir("logs");
    }
    Verilated::threadContextp()->coveragep()->zero();
#endif

    Sim sim(mem_kb);
    sim.start_trace(vcd);
    sim.reset();
    sim.enable_logging(log_reg, log_mem, log_trap, debug_reg, log_file);
    sim.load_elf(elf);
    sim.run(max_cycles, watch_tohost, tohost_addr, pass_value);
    sim.stop_trace();
    cout << "Done. Ticks: " << sim.ticks() << endl;
    cout << "Cycles: " << (sim.ticks() / 2) << endl;
#if VM_COVERAGE
    Verilated::threadContextp()->coveragep()->write(cov_file.c_str());
    cout << "Coverage: " << cov_file << endl;
#endif
  } catch (const std::exception &e) {
    cerr << "Error: " << e.what() << endl;
    return 2;
  }
  return 0;
}
