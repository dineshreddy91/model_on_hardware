#include <array>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

#include <fcntl.h>
#include <unistd.h>

extern "C" {
#include <fpga_mgmt.h>
enum fpga_dma_driver { FPGA_DMA_EDMA, FPGA_DMA_XDMA };
int fpga_dma_open_queue(enum fpga_dma_driver which_driver, int slot_id, int channel, bool is_read);
int fpga_dma_burst_read(int fd, std::uint8_t* buffer, std::size_t xfer_size, std::size_t address);
int fpga_dma_burst_write(int fd, std::uint8_t* buffer, std::size_t xfer_size, std::size_t address);
}

namespace fs = std::filesystem;

class DmaQueue {
public:
    DmaQueue(int slot, bool read) : fd_(fpga_dma_open_queue(FPGA_DMA_XDMA, slot, 0, read)) {
        if (fd_ < 0) throw std::runtime_error("Unable to open FPGA DMA queue");
    }
    ~DmaQueue() { close(fd_); }
    DmaQueue(const DmaQueue&) = delete;
    DmaQueue& operator=(const DmaQueue&) = delete;
    int get() const { return fd_; }

private:
    int fd_;
};

class AlignedBuffer {
public:
    explicit AlignedBuffer(std::size_t bytes) : bytes_(bytes) {
        void* pointer = nullptr;
        if (posix_memalign(&pointer, 4096, bytes) != 0) {
            throw std::bad_alloc();
        }
        data_.reset(static_cast<std::uint8_t*>(pointer));
    }
    std::uint8_t* get() { return data_.get(); }
    std::size_t size() const { return bytes_; }

private:
    struct FreeDeleter {
        void operator()(std::uint8_t* pointer) const { free(pointer); }
    };
    std::unique_ptr<std::uint8_t, FreeDeleter> data_;
    std::size_t bytes_;
};

class OpenJevHbmLoader {
public:
    static constexpr int kBankCount = 32;
    static constexpr std::uint64_t kHbmPcisBase = 4ULL << 34;
    static constexpr std::uint64_t kBankStride = 0x20000000ULL;
    static constexpr std::size_t kTransferBytes = 4ULL << 20;

    OpenJevHbmLoader(int slot, fs::path image_directory)
        : slot_(slot), image_directory_(std::move(image_directory)) {}

    std::uint64_t validate() const {
        std::uint64_t total = 0;
        for (int bank = 0; bank < kBankCount; ++bank) {
            const auto path = bank_path(bank);
            if (!fs::is_regular_file(path)) {
                throw std::runtime_error("Missing HBM image: " + path.string());
            }
            const auto bytes = fs::file_size(path);
            if (bytes > kBankStride) {
                throw std::runtime_error("HBM bank image exceeds 512 MiB: " + path.string());
            }
            total += bytes;
            std::cout << "bank " << bank << " bytes=" << bytes << " address=0x"
                      << std::hex << bank_address(bank) << std::dec << '\n';
        }
        return total;
    }

    void load(bool verify) const {
        if (fpga_mgmt_init() != 0) throw std::runtime_error("fpga_mgmt_init failed");
        DmaQueue write_queue(slot_, false);
        std::unique_ptr<DmaQueue> read_queue;
        if (verify) read_queue = std::make_unique<DmaQueue>(slot_, true);
        AlignedBuffer write_buffer(kTransferBytes);
        AlignedBuffer read_buffer(kTransferBytes);
        for (int bank = 0; bank < kBankCount; ++bank) {
            const auto path = bank_path(bank);
            const int source = open(path.c_str(), O_RDONLY);
            if (source < 0) throw std::runtime_error("open failed: " + path.string());
            std::uint64_t offset = 0;
            while (true) {
                const auto count = read(source, write_buffer.get(), write_buffer.size());
                if (count < 0) {
                    close(source);
                    throw std::runtime_error("read failed: " + path.string());
                }
                if (count == 0) break;
                const auto address = bank_address(bank) + offset;
                if (fpga_dma_burst_write(write_queue.get(), write_buffer.get(), count, address) != 0) {
                    close(source);
                    throw std::runtime_error("DMA write failed at bank " + std::to_string(bank));
                }
                if (verify) {
                    if (fpga_dma_burst_read(read_queue->get(), read_buffer.get(), count, address) != 0
                        || std::memcmp(write_buffer.get(), read_buffer.get(), count) != 0) {
                        close(source);
                        throw std::runtime_error("DMA verification failed at bank " + std::to_string(bank));
                    }
                }
                offset += static_cast<std::uint64_t>(count);
            }
            close(source);
            std::cout << "loaded bank " << bank << '\n';
        }
    }

private:
    fs::path bank_path(int bank) const {
        std::array<char, 32> name{};
        std::snprintf(name.data(), name.size(), "hbm_bank_%02d.bin", bank);
        return image_directory_ / name.data();
    }
    static std::uint64_t bank_address(int bank) {
        return kHbmPcisBase + static_cast<std::uint64_t>(bank) * kBankStride;
    }

    int slot_;
    fs::path image_directory_;
};

int main(int argc, char** argv) {
    if (argc < 2 || argc > 5) {
        std::cerr << "usage: " << argv[0] << " IMAGE_DIRECTORY [--slot N] [--load|--verify]\n";
        return 2;
    }
    fs::path directory = argv[1];
    int slot = 0;
    bool load = false;
    bool verify = false;
    for (int index = 2; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--slot" && index + 1 < argc) slot = std::stoi(argv[++index]);
        else if (argument == "--load") load = true;
        else if (argument == "--verify") load = verify = true;
        else throw std::runtime_error("Unknown argument: " + argument);
    }
    try {
        OpenJevHbmLoader loader(slot, directory);
        const auto total = loader.validate();
        std::cout << "validated_bytes=" << total << '\n';
        if (load) loader.load(verify);
    } catch (const std::exception& error) {
        std::cerr << "error: " << error.what() << '\n';
        return 1;
    }
    return 0;
}
