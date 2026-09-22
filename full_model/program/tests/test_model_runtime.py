"""Host protocol tests with an explicit register device, not model inference."""
import struct
from types import SimpleNamespace

import pytest

from full_model.host.model_runtime import FullModelDevice


class RegisterDevice(FullModelDevice):
    def __init__(self):
        self.registers = {0x504: 16, 0x544: 4096, 0x548: 4096, 0x540: 1, 0x53C: 0xFFFFFE,
                          0x534: 1, 0x52C: 42, 0x530: 2}
        self.writes = []
        self.uploads = []
        self.output = struct.pack('<3f', 0.25, 0.25, 0.5)

    def read(self, address):
        return self.registers.get(address, 0)

    def write(self, address, value):
        self.writes.append((address, value))
        if address == 0x500:
            self.registers[0x504] = 18

    def upload_input(self, tensor, payload):
        self.uploads.append((tensor.id, payload))

    def download_output(self, tensor):
        return self.output


def test_configuration_record_order():
    device = RegisterDevice()
    device.configure(struct.pack('<16I', *range(16)), bytes(128), bytes(32))
    assert device.writes[:2] == [(0x508, 1), (0x50C, 1)]
    assert [(address, word) for address, word in device.writes if address == 0x514] == [(0x514, i) for i in range(16)]
    assert [address for address, _ in device.writes if address in (0x528, 0x518, 0x520)] == [0x528, 0x518, 0x520]


@pytest.mark.parametrize('instructions,descriptors,metadata', [(b'', bytes(128), bytes(32)),
    (bytes(63), bytes(128), bytes(32)), (bytes(64), bytes(127), bytes(32)), (bytes(64), bytes(128), bytes(31))])
def test_incomplete_configuration_never_writes(instructions, descriptors, metadata):
    device = RegisterDevice()
    with pytest.raises(ValueError):
        device.configure(instructions, descriptors, metadata)
    assert not device.writes


@pytest.mark.parametrize('address,value', [(0x540, 2), (0x53C, 2), (0x504, 17), (0x504, 20)])
def test_configuration_rejects_incompatible_or_active_device(address, value):
    device = RegisterDevice()
    device.registers[address] = value
    with pytest.raises(RuntimeError):
        device.configure(bytes(64), bytes(128), bytes(32))
    assert not device.writes


def make_graph():
    return SimpleNamespace(input_ids=(0,), instructions=(object(), object()), outputs=(1,),
        tensors=[SimpleNamespace(id=0, logical_bytes=4), SimpleNamespace(name='probabilities')])


def test_complete_retirement_and_64_bit_cycles():
    device = RegisterDevice()
    result = device.execute(make_graph(), {0: bytes(4)})
    assert result['device_cycles'] == (2 << 32) + 42
    assert result['outputs']['probabilities'] == [0.25, 0.25, 0.5]
    assert result['cpu_model_fallback'] is False
    assert device.uploads == [(0, bytes(4))]


@pytest.mark.parametrize('payloads', [{}, {0: bytes(3)}, {0: bytes(4), 1: bytes(4)}])
def test_invalid_inputs_never_start(payloads):
    device = RegisterDevice()
    with pytest.raises(ValueError):
        device.execute(make_graph(), payloads)
    assert not device.writes and not device.uploads


def test_incomplete_retirement_is_not_a_result():
    device = RegisterDevice()
    device.registers[0x534] = 0
    with pytest.raises(RuntimeError, match='incomplete graph retirement'):
        device.execute(make_graph(), {0: bytes(4)})


def test_nonfinite_is_not_a_result():
    device = RegisterDevice()
    device.output = struct.pack('<f', float('nan'))
    with pytest.raises(RuntimeError, match='Nonfinite'):
        device.execute(make_graph(), {0: bytes(4)})


def test_hbm_striping_boundaries():
    assert FullModelDevice.address(0x2000000, 0) == 0x1002000000
    assert FullModelDevice.address(0x2000000, 256) == 0x1022000000
    assert FullModelDevice.address(0x2000000, 8192) == 0x1002000100
