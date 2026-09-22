"""Offline integrity checks for reconstruction of a previously validated model."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import torch
from safetensors.torch import load_file, save_file

from restore_quantized_checkpoint import CheckpointRestorer


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.safetensors"
        self.output = self.root / "restored.safetensors"
        self.manifest = self.root / "manifest.json"
        save_file({"weight": torch.tensor([[-1., 0., 1.], [.5, -.5, 0.]]),
                   "norm": torch.tensor([1., 2.])}, str(self.source))
        self.expected = {"weight": torch.tensor([[-127, 0, 127], [127, -127, 0]], dtype=torch.int8),
                         "weight.scale": torch.tensor([1/127, .5/127], dtype=torch.float16),
                         "norm": torch.tensor([1., 2.], dtype=torch.float16)}
        self.entries = [{"name": name, "shape": list(value.shape),
                         "dtype": str(value.dtype).removeprefix("torch."),
                         "sha256": hashlib.sha256(value.numpy().tobytes()).hexdigest()}
                        for name, value in self.expected.items()]
        self.manifest.write_text(json.dumps({"tensors": self.entries}))

    def test_exact_restore(self):
        CheckpointRestorer(self.manifest).restore(self.source, self.output)
        actual = load_file(str(self.output))
        self.assertEqual(actual.keys(), self.expected.keys())
        for name, value in self.expected.items():
            self.assertTrue(torch.equal(value, actual[name]))

    def test_changed_tensor_rejected_before_output(self):
        self.entries[0]["sha256"] = "0"*64
        self.manifest.write_text(json.dumps({"tensors": self.entries}))
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            CheckpointRestorer(self.manifest).restore(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_convolution_shape_and_zero_channel(self):
        source = torch.tensor([[[0.,0.],[0.,0.]], [[-2.,0.],[2.,0.]]])
        quantized, scale = CheckpointRestorer.quantize(source)
        self.assertEqual(quantized.shape, source.shape)
        self.assertTrue(torch.equal(quantized[0], torch.zeros((2,2), dtype=torch.int8)))
        self.assertEqual(quantized[1,0,0].item(), -127)
        self.assertEqual(quantized[1,1,0].item(), 127)
        self.assertEqual(scale.shape, (2,))


if __name__ == "__main__":
    unittest.main()
