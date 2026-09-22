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

#include <emmintrin.h>
#include <fcntl.h>
#include <unistd.h>

extern "C" {
#include <fpga_mgmt.h>
#include <fpga_pci.h>
// The SDK's fpga_dma.h contains a C99-only static array parameter. These
// declarations mirror its exported ABI so this translation unit stays C++17.
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

class PciWindow {
public:
    explicit PciWindow(int slot) {
        const int status = fpga_pci_attach(slot, FPGA_APP_PF, APP_PF_BAR4, BURST_CAPABLE, &handle_);
        if (status != 0) throw std::runtime_error("BAR4 attach failed: " + std::to_string(status));
    }
    ~PciWindow() { fpga_pci_detach(handle_); }
    PciWindow(const PciWindow&) = delete;
    PciWindow& operator=(const PciWindow&) = delete;
    int write(std::uint8_t* data, std::size_t bytes, std::uint64_t address) const {
        if (bytes % 4) return -EINVAL;
        const int status = fpga_pci_write_burst(handle_, address, reinterpret_cast<std::uint32_t*>(data), bytes / 4);
        // The SDK burst function does not drain x86 write-combining buffers.
        _mm_sfence();
        return status;
    }
    int read(std::uint8_t* data, std::size_t bytes, std::uint64_t address) const {
        if (bytes % 8) return -EINVAL;
        for (std::size_t offset = 0; offset < bytes; offset += 8) {
            std::uint64_t value;
            const int status = fpga_pci_peek64(handle_, address + offset, &value);
            if (status != 0) return status;
            std::memcpy(data + offset, &value, sizeof(value));
        }
        return 0;
    }
private:
    pci_bar_handle_t handle_ = PCI_BAR_HANDLE_INIT;
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

    void load(bool verify, bool pci) const {
        if (fpga_mgmt_init() != 0) throw std::runtime_error("fpga_mgmt_init failed");
        std::unique_ptr<DmaQueue> write_queue, read_queue;
        std::unique_ptr<PciWindow> window;
        if (pci) window = std::make_unique<PciWindow>(slot_);
        else {
            write_queue = std::make_unique<DmaQueue>(slot_, false);
            if (verify) read_queue = std::make_unique<DmaQueue>(slot_, true);
        }
        std::cout << "transport=" << (pci ? "pci_bar4" : "xdma") << std::endl;
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
                const int write_status = pci ? window->write(write_buffer.get(), count, address)
                    : fpga_dma_burst_write(write_queue->get(), write_buffer.get(), count, address);
                if (write_status != 0) {
                    close(source);
                    throw std::runtime_error("HBM write failed at bank " + std::to_string(bank)
                        + " offset=" + std::to_string(offset) + " bytes=" + std::to_string(count)
                        + " status=" + std::to_string(write_status));
                }
                if (verify) {
                    const int read_status = pci ? window->read(read_buffer.get(), count, address)
                        : fpga_dma_burst_read(read_queue->get(), read_buffer.get(), count, address);
                    if (read_status != 0 || std::memcmp(write_buffer.get(), read_buffer.get(), count) != 0) {
                        close(source);
                        throw std::runtime_error("HBM verification failed at bank " + std::to_string(bank)
                            + " offset=" + std::to_string(offset) + " status=" + std::to_string(read_status));
                    }
                }
                offset += static_cast<std::uint64_t>(count);
            }
            close(source);
            std::cout << "loaded bank " << bank << std::endl;
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
    if (argc < 2 || argc > 6) {
        std::cerr << "usage: " << argv[0] << " IMAGE_DIRECTORY [--slot N] [--load|--verify] [--pci]\n";
        return 2;
    }
    fs::path directory = argv[1];
    int slot = 0;
    bool load = false;
    bool verify = false;
    bool pci = false;
    for (int index = 2; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--slot" && index + 1 < argc) slot = std::stoi(argv[++index]);
        else if (argument == "--pci") pci = true;
        else if (argument == "--load") load = true;
        else if (argument == "--verify") load = verify = true;
        else throw std::runtime_error("Unknown argument: " + argument);
    }
    try {
        OpenJevHbmLoader loader(slot, directory);
        const auto total = loader.validate();
        std::cout << "validated_bytes=" << total << '\n';
        if (load) loader.load(verify, pci);
    } catch (const std::exception& error) {
        std::cerr << "error: " << error.what() << '\n';
        return 1;
    }
    return 0;
}
