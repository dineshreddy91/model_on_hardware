"""Offline tests for hardware-test input integrity; no FPGA access."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from test_hbm_matvec import F2Device, Fixture


class ReadyDevice(F2Device):
    def __init__(self, engine_status=0x10):
        self.engine_status = engine_status

    def read(self, address):
        return {0x300: 0x6, 0x504: self.engine_status}[address]

    def write(self, address, value):
        raise AssertionError("An already calibrated HBM must not be reset")


class CalibrationTests(unittest.TestCase):
    def test_both_stacks_ready_with_reserved_bit_zero(self):
        ReadyDevice().initialize_hbm()

    def test_engine_must_also_report_ready(self):
        with self.assertRaisesRegex(RuntimeError, "readiness disagree"):
            ReadyDevice(engine_status=0).initialize_hbm()


class FixtureValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.payload = bytes((i*37+i//256) % 256 for i in range(8192))
        (self.root / "metadata.json").write_text(json.dumps({"tensor": "test", "rows": 8, "columns": 1024}))
        (self.root / "hbm_manifest.json").write_text(json.dumps({
            "bank_count": 32, "burst_bytes": 256,
            "tensors": [{"name": "test", "base_address": 4096,
                         "sha256": hashlib.sha256(self.payload).hexdigest()}]}))
        (self.root / "weights.mem").write_text("\n".join(self.payload[i:i+32][::-1].hex() for i in range(0,8192,32)))
        (self.root / "activations.mem").write_text("\n".join(["00"*32]*32))
        (self.root / "expected.mem").write_text("00000000\n"*8)
        for bank in range(32):
            (self.root / f"hbm_bank_{bank:02d}.bin").write_bytes(bytes(4096)+self.payload[bank*256:(bank+1)*256])

    def test_little_endian_words_and_all_banks(self):
        fixture = Fixture(self.root,self.root)
        self.assertEqual(fixture.weights,self.payload)
        for bank in range(32):
            self.assertEqual(fixture.banks[bank],self.payload[bank*256:(bank+1)*256])

    def test_changed_weights_rejected(self):
        path = self.root / "weights.mem"
        text = path.read_text()
        path.write_text(("ff" if text[:2] != "ff" else "00") + text[2:])
        with self.assertRaisesRegex(ValueError,"checksum"):
            Fixture(self.root,self.root)

    def test_changed_hbm_rejected(self):
        path = self.root / "hbm_bank_17.bin"
        path.write_bytes(bytes(4352))
        with self.assertRaisesRegex(ValueError,"packed HBM"):
            Fixture(self.root,self.root)

    def test_truncated_activations_rejected(self):
        (self.root / "activations.mem").write_text("00"*32)
        with self.assertRaisesRegex(ValueError,"shape/checksum"):
            Fixture(self.root,self.root)


if __name__ == "__main__":
    unittest.main()
