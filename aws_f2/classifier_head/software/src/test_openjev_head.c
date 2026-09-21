#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <fpga_pci.h>
#include <fpga_mgmt.h>

#include "openjev_head_fixture.h"

#define SLOT_ID 0
#define PF_ID FPGA_APP_PF
#define BAR_ID APP_PF_BAR0
#define ADDR_ACTIVATION 0x00
#define ADDR_CONTROL 0x04
#define ADDR_ACCUMULATOR0 0x08
#define ADDR_ACCUMULATOR1 0x0c
#define ADDR_ACCUMULATOR2 0x10
#define ADDR_STATUS 0x14

int main(void) {
    pci_bar_handle_t handle = PCI_BAR_HANDLE_INIT;
    int rc = fpga_mgmt_init();
    if (rc) {
        fprintf(stderr, "fpga_mgmt_init failed: %d\n", rc);
        return 1;
    }
    rc = fpga_pci_attach(SLOT_ID, PF_ID, BAR_ID, 0, &handle);
    if (rc) {
        fprintf(stderr, "fpga_pci_attach failed: %d\n", rc);
        return 1;
    }

    fpga_pci_poke(handle, ADDR_CONTROL, 2);
    for (int i = 0; i < 1024; i += 4) {
        uint32_t word = 0;
        memcpy(&word, &openjev_activation[i], sizeof(word));
        rc = fpga_pci_poke(handle, ADDR_ACTIVATION, word);
        if (rc) {
            fprintf(stderr, "activation write %d failed: %d\n", i, rc);
            return 1;
        }
    }
    rc = fpga_pci_poke(handle, ADDR_CONTROL, 1);
    if (rc) {
        fprintf(stderr, "start failed: %d\n", rc);
        return 1;
    }

    uint32_t status = 0;
    for (int poll = 0; poll < 10000; ++poll) {
        fpga_pci_peek(handle, ADDR_STATUS, &status);
        if (status & 2) break;
        usleep(10);
    }
    if (!(status & 2)) {
        fprintf(stderr, "timeout, status=0x%08x\n", status);
        return 1;
    }

    int failed = 0;
    const uint64_t addresses[3] = {
        ADDR_ACCUMULATOR0, ADDR_ACCUMULATOR1, ADDR_ACCUMULATOR2
    };
    for (int label = 0; label < 3; ++label) {
        uint32_t raw = 0;
        fpga_pci_peek(handle, addresses[label], &raw);
        int32_t actual = (int32_t)raw;
        printf("label %d: FPGA=%" PRId32 " expected=%" PRId32 "%s\n",
               label, actual, openjev_expected[label],
               actual == openjev_expected[label] ? " PASS" : " FAIL");
        failed |= actual != openjev_expected[label];
    }
    fpga_pci_detach(handle);
    return failed;
}
