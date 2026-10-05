#!/usr/bin/env python3

import json
import math
import os
from pathlib import Path

from transformers import AutoTokenizer

MODEL = os.environ.get("MODEL_ID", "Qwen/Qwen3-32B")
OUT = Path(os.environ.get("PROMPTS_DIR", "prompts"))
OUT.mkdir(parents=True, exist_ok=True)

tokenizer = AutoTokenizer.from_pretrained(MODEL)

SEED = (
    "Analyze the following synthetic systems-performance workload. "
    "Discuss memory hierarchy behavior, arithmetic intensity, cache locality, "
    "parallel execution, synchronization, scheduling, and bottlenecks. "
    "Use precise technical terminology and distinguish measured facts from "
    "engineering hypotheses. "
)

seed_ids = tokenizer.encode(SEED, add_special_tokens=False)
if not seed_ids:
    raise RuntimeError("seed tokenization produced zero tokens")


def exact_prompt(target):
    repeats = math.ceil((target + 32) / len(seed_ids))
    source = SEED * repeats

    ids = tokenizer.encode(source, add_special_tokens=False)

    while len(ids) < target:
        source += SEED
        ids = tokenizer.encode(source, add_special_tokens=False)

    ids = ids[:target]
    text = tokenizer.decode(
        ids,
        skip_special_tokens=False,
        clean_up_tokenization_spaces=False,
    )

    check = tokenizer.encode(text, add_special_tokens=False)

    if len(check) != target:
        raise RuntimeError(
            f"Tokenizer round-trip changed token count: "
            f"target={target}, actual={len(check)}"
        )

    return text


CASES = {
    "short": {
        "tokens": 128,
        "count": 16,
        "output_tokens": 1,
    },
    "medium": {
        "tokens": 2048,
        "count": 16,
        "output_tokens": 1,
    },
    "long": {
        "tokens": 16384,
        "count": 16,
        "output_tokens": 1,
    },
    "large_batch": {
        "tokens": 2048,
        "count": 64,
        "output_tokens": 1,
    },
    "decode": {
        "tokens": 256,
        "count": 32,
        "output_tokens": 512,
    },
}

manifest = {}

for name, cfg in CASES.items():
    prompt = exact_prompt(cfg["tokens"])
    actual = len(tokenizer.encode(prompt, add_special_tokens=False))

    path = OUT / f"{name}.jsonl"

    with path.open("w", encoding="utf-8") as f:
        for i in range(cfg["count"]):
            row = {
                "prompt": prompt,
                "output_tokens": cfg["output_tokens"],
                "case": name,
                "request_index": i,
            }
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    manifest[name] = {
        **cfg,
        "verified_input_tokens": actual,
        "file": str(path),
    }

with (OUT / "manifest.json").open("w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)

print(json.dumps(manifest, indent=2))
