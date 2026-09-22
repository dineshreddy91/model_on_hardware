"""Independent reference sanity tests; CPU oracle results are never hardware results."""
from types import SimpleNamespace

import torch

from reference_graph import QuantizedReference
from schema import Opcode


def evaluate(opcode, src, parameters=(), flags=0):
    return QuantizedReference.evaluate(SimpleNamespace(opcode=opcode, parameters=parameters, flags=flags), src)


def test_exact_integer_accumulation():
    x = torch.tensor([[127, -128, 127, -128]], dtype=torch.int8)
    w = torch.tensor([[127, -128, -128, 127]], dtype=torch.int8)
    result, = evaluate(Opcode.LINEAR_I8, [x, w])
    assert result.dtype == torch.int32
    assert result.item() == 1


def test_zero_quantization_and_scale():
    values, scales = evaluate(Opcode.QUANTIZE, [torch.zeros(2, 32)])
    assert torch.equal(scales, torch.ones(2))
    assert torch.count_nonzero(values) == 0


def test_attention_mask_blocks_large_value():
    q = torch.ones(2, 1, 2)
    k = torch.ones(2, 1, 2)
    v = torch.tensor([[[2., 3.]], [[100., 200.]]])
    result, = evaluate(Opcode.ATTENTION, [q, k, v, torch.tensor([1, 0])], (2, 2, 2, 1, 1), 3)
    torch.testing.assert_close(result, torch.tensor([[[2., 3.]], [[2., 3.]]]))


def test_recurrent_one_token_closed_form():
    q = k = torch.ones(1, 1, 1)
    result, state = QuantizedReference.recurrence(q, k, torch.full_like(q, 2), torch.zeros(1, 1), torch.full((1, 1), .5))
    torch.testing.assert_close(state, torch.full_like(state, 1 / (1 + 1e-6)**.5))
    torch.testing.assert_close(result, torch.full_like(result, 1 / (1 + 1e-6)))


def test_interpolation_and_raw_int8_scales():
    result, = evaluate(Opcode.INTERPOLATE, [torch.tensor([[2, 4], [-2, 6]], dtype=torch.int8),
        torch.tensor([.5, .25], dtype=torch.float16), torch.tensor([[0, 1, 0, 1]]), torch.full((1, 4), .25)])
    torch.testing.assert_close(result, torch.tensor([[.25, 1.75]]))
