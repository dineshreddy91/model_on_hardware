#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def tensor_group(tensors: list[dict], prefix: str) -> list[str]:
    return [tensor["name"] for tensor in tensors if tensor["name"].startswith(prefix)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("hbm_manifest", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    manifest = json.loads(args.hbm_manifest.read_text())
    tensors = manifest["tensors"]
    text = config["text_config"]
    vision = config["vision_config"]
    operations = [
        {
            "stage": "vision_patch_embedding",
            "engine": "conv3d_int8",
            "tensors": tensor_group(tensors, "model.visual.patch_embed"),
        },
        {
            "stage": "vision_position_embedding",
            "engine": "embedding_lookup",
            "tensors": tensor_group(tensors, "model.visual.pos_embed"),
        }
    ]
    for layer in range(vision["depth"]):
        prefix = f"model.visual.blocks.{layer}."
        operations.append(
            {
                "stage": f"vision_block_{layer}",
                "engine": "vision_transformer",
                "hidden_size": vision["hidden_size"],
                "heads": vision["num_heads"],
                "intermediate_size": vision["intermediate_size"],
                "tensors": tensor_group(tensors, prefix),
            }
        )
    operations.extend(
        [
            {
                "stage": "vision_merger",
                "engine": "vision_merger",
                "tensors": tensor_group(tensors, "model.visual.merger"),
            },
            {
                "stage": "token_embedding",
                "engine": "embedding_lookup",
                "tensors": tensor_group(tensors, "model.language_model.embed_tokens"),
            },
        ]
    )
    for layer, layer_type in enumerate(text["layer_types"]):
        prefix = f"model.language_model.layers.{layer}."
        operations.append(
            {
                "stage": f"language_layer_{layer}",
                "engine": "gated_delta_block" if layer_type == "linear_attention" else "full_attention_block",
                "hidden_size": text["hidden_size"],
                "intermediate_size": text["intermediate_size"],
                "tensors": tensor_group(tensors, prefix),
            }
        )
    operations.extend(
        [
            {
                "stage": "final_norm",
                "engine": "rms_norm",
                "tensors": tensor_group(tensors, "model.language_model.norm"),
            },
            {
                "stage": "classifier",
                "engine": "int8_gemm",
                "tensors": tensor_group(tensors, "score."),
            },
        ]
    )
    used = {name for operation in operations for name in operation["tensors"]}
    all_names = {tensor["name"] for tensor in tensors}
    plan = {
        "format": "openjev-execution-plan-v1",
        "model": config.get("_name_or_path", "qwen3.5-0.8b-nli-v2s-long"),
        "target": "aws-f2-vu47p",
        "precision": {"matrix": "int8", "accumulator": "int32", "vector": "fp16_or_bf16"},
        "operations": operations,
        "covered_tensors": len(used),
        "unassigned_tensors": sorted(all_names - used),
    }
    args.output.write_text(json.dumps(plan, indent=2) + "\n")
    print(json.dumps({"operations": len(operations), "covered": len(used), "unassigned": len(all_names - used)}, indent=2))


if __name__ == "__main__":
    main()
