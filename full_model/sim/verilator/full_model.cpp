// Cycle-accurate RTL execution. Host code only loads/stores bytes and drives AXI.
#include "Vopenjev_model_core.h"
#include "verilated.h"
#include <array>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/mman.h>

namespace fs = std::filesystem;
using Bytes = std::vector<unsigned char>;
static Bytes read_file(const fs::path& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("Cannot read " + path.string());
    return Bytes(std::istreambuf_iterator<char>(f), {});
}
class Memory {
    static constexpr uint64_t span = 1ULL << 34;
    unsigned char* data;
public:
    Memory() {
        data = static_cast<unsigned char*>(mmap(nullptr, span, PROT_READ|PROT_WRITE,
                                               MAP_PRIVATE|MAP_ANONYMOUS, -1, 0));
        if (data == MAP_FAILED) throw std::runtime_error("mmap failed");
    }
    ~Memory() { munmap(data, span); }
    unsigned char* at(uint64_t address, size_t count) {
        constexpr uint64_t base = 0x1000000000ULL;
        if (address < base || address-base >= span || count > span-(address-base))
            throw std::runtime_error("HBM address out of bounds");
        return data + address-base;
    }
    void load(unsigned bank, uint64_t offset, const Bytes& bytes) {
        if (bank >= 32 || offset + bytes.size() > (1ULL<<29)) throw std::runtime_error("Bank bounds");
        memcpy(at(0x1000000000ULL + (uint64_t(bank)<<29) + offset, bytes.size()), bytes.data(), bytes.size());
    }
    void striped(uint64_t base, const Bytes& bytes) {
        for (size_t n=0;n<bytes.size();n+=256) {
            const size_t count=std::min(size_t(256),bytes.size()-n);
            memcpy(at(0x1000000000ULL + (((n>>8)%32)<<29) + base + (n>>13)*256, count),bytes.data()+n,count);
        }
    }
};
class Simulator {
    std::unique_ptr<VerilatedContext> context{new VerilatedContext};
    std::unique_ptr<Vopenjev_model_core> core{new Vopenjev_model_core(context.get())};
    Memory memory;
    bool read_pending=false,read_valid=false,write_response=false,have_aw=false,have_w=false;
    uint64_t read_address=0,write_address=0,strobe=0;
    unsigned read_delay=0,latency=0;
    std::array<uint32_t,16> read_data{},write_data{};
    uint64_t ticks=0,reads=0,writes=0;
    void tick() {
        auto& d=*core;
        d.clk=0;d.arready=!read_pending&&!read_valid;
        d.rvalid=read_valid;d.rlast=1;d.rid=0;d.rresp=0;
        memcpy(d.rdata.data(),read_data.data(),64);
        d.awready=!have_aw&&!write_response;d.wready=!have_w&&!write_response;
        d.bvalid=write_response;d.bid=0;d.bresp=0;
        d.eval();
        bool ar=d.arvalid&&d.arready, r=read_valid&&d.rready;
        bool aw=d.awvalid&&d.awready,w=d.wvalid&&d.wready,b=write_response&&d.bready;
        if (ar) {
            if(d.arlen||d.arsize!=6||d.arburst!=1||d.arid||(d.araddr&63)) throw std::runtime_error("Invalid AXI read");
            read_address=d.araddr;
        }
        if (aw) {
            if(d.awlen||d.awsize!=6||d.awburst!=1||d.awid||(d.awaddr&63)) throw std::runtime_error("Invalid AXI write");
            write_address=d.awaddr;
        }
        if (w) {
            if(!d.wlast) throw std::runtime_error("Missing WLAST");
            memcpy(write_data.data(),d.wdata.data(),64);strobe=d.wstrb;
        }
        d.clk=1;d.eval();context->timeInc(1);++ticks;
        if(r) read_valid=false;
        if(b) write_response=false;
        if(ar) {read_pending=true;read_delay=latency;++reads;}
        if(read_pending) {
            if(read_delay) --read_delay;
            else {memcpy(read_data.data(),memory.at(read_address,64),64);read_valid=true;read_pending=false;}
        }
        if(aw) have_aw=true;
        if(w) have_w=true;
        if(have_aw&&have_w&&!write_response) {
            auto* dst=memory.at(write_address,64);auto* src=reinterpret_cast<unsigned char*>(write_data.data());
            for(unsigned i=0;i<64;++i) if((strobe>>i)&1) dst[i]=src[i];
            have_aw=false;have_w=false;write_response=true;++writes;
        }
    }
public:
    int run(const fs::path& config, uint64_t limit, unsigned read_latency) {
        latency=read_latency;
        std::ifstream cfg(config);if(!cfg) throw std::runtime_error("Missing configuration");
        std::string program_dir,result_dir;cfg>>program_dir>>result_dir;
        fs::create_directories(result_dir);
        std::string command,path;unsigned bank;uint64_t base;
        std::vector<std::pair<uint64_t,unsigned>> outputs;
        while(cfg>>command) {
            if(command=="BANK") {cfg>>bank>>path;memory.load(bank,0,read_file(path));}
            else if(command=="INPUT") {cfg>>base>>path;memory.striped(base,read_file(path));}
            else if(command=="OUTPUT") {unsigned count;cfg>>base>>count;outputs.emplace_back(base,count);}
            else throw std::runtime_error("Unknown config directive");
        }
        auto programs=read_file(fs::path(program_dir)/"program.bin");
        auto metadata=read_file(fs::path(program_dir)/"kernel_metadata.bin");
        auto tensors=read_file(fs::path(program_dir)/"tensors.bin");
        if(programs.empty()||programs.size()%64||tensors.empty()||tensors.size()%128||metadata.size()!=programs.size()/2||programs.size()/64>4096||tensors.size()/128>4096)
            throw std::runtime_error("Invalid program tables");
        auto& d=*core;d.rst_n=0;for(int i=0;i<4;++i)tick();d.rst_n=1;tick();
        d.tensor_count=tensors.size()/128;d.program_length=programs.size()/64;
        for(unsigned i=0;i<d.tensor_count;++i) {
            if(!d.tensor_ready)throw std::runtime_error("Tensor port not ready");
            d.tensor_index=i;memcpy(d.tensor_data.data(),tensors.data()+128*i,128);d.tensor_valid=1;tick();
        }
        d.tensor_valid=0;
        for(unsigned i=0;i<d.program_length;++i) {
            if(!d.program_ready||!d.metadata_ready)throw std::runtime_error("Program port not ready");
            d.program_index=i;d.metadata_index=i;
            memcpy(d.program_data.data(),programs.data()+64*i,64);memcpy(d.metadata_data.data(),metadata.data()+32*i,32);
            d.program_valid=1;d.metadata_valid=1;tick();
        }
        d.program_valid=0;d.metadata_valid=0;tick();d.start=1;tick();d.start=0;
        const auto started=std::chrono::steady_clock::now();double reported=-10;
        while(!d.done&&!d.fault&&d.cycles<limit) {
            tick();
            if(ticks%100000==0) {
                double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count();
                if(seconds-reported>=10) {
                    std::cout<<"{\"cycles\":"<<d.cycles<<",\"instructions_retired\":"<<d.instructions_retired
                             <<",\"wall_seconds\":"<<seconds<<",\"cycles_per_second\":"<<d.cycles/seconds<<"}"<<std::endl;
                    reported=seconds;
                }
            }
        }
        double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count();
        bool complete=d.done&&!d.fault&&d.instructions_retired==d.program_length-1&&!read_pending&&!read_valid&&!write_response&&!have_aw&&!have_w;
        std::ofstream report(fs::path(result_dir)/"status.json");
        report<<"{\"execution\":\"full_graph_rtl_simulation\",\"complete\":"<<(complete?"true":"false")
              <<",\"fault\":"<<unsigned(d.fault)<<",\"fault_code\":"<<unsigned(d.fault_code)
              <<",\"cycles\":"<<d.cycles<<",\"instructions_retired\":"<<d.instructions_retired
              <<",\"wall_seconds\":"<<seconds<<",\"read_latency\":"<<latency
              <<",\"reads\":"<<reads<<",\"writes\":"<<writes<<",\"cpu_model_fallback\":false}"<<std::endl;
        if(complete) {
            std::ofstream out(fs::path(result_dir)/"outputs.bin",std::ios::binary);
            for(auto [address,count]:outputs)for(unsigned i=0;i<count;++i) {
                uint64_t offset=uint64_t(i)*4;
                out.write(reinterpret_cast<char*>(memory.at(0x1000000000ULL+(((offset>>8)%32)<<29)+address+(offset>>13)*256+(offset%256),4)),4);
            }
        }
        return complete?0:d.fault?2:3;
    }
};
int main(int argc,char**argv) {
    try {
        if(argc!=4)throw std::runtime_error("Usage: simulator CONFIG MAX_CYCLES READ_LATENCY");
        Simulator sim;return sim.run(argv[1],std::stoull(argv[2]),std::stoul(argv[3]));
    }catch(const std::exception& e){std::cerr<<e.what()<<std::endl;return 1;}
}
