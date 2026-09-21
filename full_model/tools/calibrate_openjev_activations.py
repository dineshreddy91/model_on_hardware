#!/usr/bin/env python3
import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path

import torch
from PIL import Image
from transformers import AutoImageProcessor, AutoModelForSequenceClassification, AutoTokenizer


@dataclass
class ActivationStats:
    calls: int = 0
    elements: int = 0
    input_absmax: float = 0.0
    output_absmax: float = 0.0
    input_shape: list[int] | None = None
    output_shape: list[int] | None = None


class ActivationCalibrator:
    def __init__(self, model: torch.nn.Module):
        self.stats: dict[str, ActivationStats] = {}
        self.handles = []
        for name, module in model.named_modules():
            if isinstance(module, torch.nn.Linear):
                self.stats[name] = ActivationStats()
                self.handles.append(module.register_forward_hook(self._hook(name)))

    def _hook(self, name: str):
        def record(_module, arguments, output):
            source = arguments[0].detach().float()
            target = output.detach().float()
            stats = self.stats[name]
            stats.calls += 1
            stats.elements += source.numel()
            stats.input_absmax = max(stats.input_absmax, float(source.abs().max()))
            stats.output_absmax = max(stats.output_absmax, float(target.abs().max()))
            stats.input_shape = list(source.shape)
            stats.output_shape = list(target.shape)
        return record

    def close(self):
        for handle in self.handles:
            handle.remove()

    def result(self) -> dict:
        layers = {}
        for name, stats in self.stats.items():
            entry = asdict(stats)
            entry["input_int8_scale"] = stats.input_absmax / 127 if stats.input_absmax else 1.0
            layers[name] = entry
        return {"format": "openjev-activation-calibration-v1", "linear_layers": layers}


def build_inputs(model, tokenizer, processor, image_path: Path, width: int):
    image = Image.open(image_path).convert("RGB")
    if image.width != width:
        image = image.resize((width, round(image.height * width / image.width)))
    visual = processor(images=[image], return_tensors="pt")
    image_tokens = int(visual["image_grid_thw"].prod()) // processor.merge_size**2
    image_block = "<|vision_start|>" + "<|image_pad|>" * image_tokens + "<|vision_end|>"
    text = model.config.nli_template.format(
        premise=f"{image_block}\nCamera frame.",
        hypothesis="A person is visible in the camera frame.",
    )
    tokenized = tokenizer(text, add_special_tokens=False, return_tensors="pt")
    return {
        **tokenized,
        "pixel_values": visual["pixel_values"],
        "image_grid_thw": visual["image_grid_thw"],
        "mm_token_type_ids": (tokenized["input_ids"] == model.config.image_token_id).long(),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--width", type=int, default=448)
    args = parser.parse_args()
    torch.set_num_threads(12)
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    processor = AutoImageProcessor.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model, dtype=torch.float32).eval()
    calibrator = ActivationCalibrator(model)
    inputs = build_inputs(model, tokenizer, processor, args.image, args.width)
    with torch.inference_mode():
        logits = model(**inputs).logits[0].float()
    calibrator.close()
    result = calibrator.result()
    result.update(
        {
            "image": str(args.image),
            "image_width": args.width,
            "logits": [float(value) for value in logits],
            "executed_linear_layers": sum(stats["calls"] > 0 for stats in result["linear_layers"].values()),
        }
    )
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"layers": len(result["linear_layers"]), "executed": result["executed_linear_layers"], "logits": result["logits"]}, indent=2))


if __name__ == "__main__":
    main()
