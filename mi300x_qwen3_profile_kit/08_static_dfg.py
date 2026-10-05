#!/usr/bin/env python3

import json
import os
from pathlib import Path

import torch
from torch.fx import symbolic_trace
from torch.fx.passes.shape_prop import ShapeProp
from transformers import AutoConfig, AutoModelForCausalLM

MODEL_ID = os.environ.get("MODEL_ID", "Qwen/Qwen3-32B")
SEQ = int(os.environ.get("DFG_SEQ_LEN", "128"))
BATCH = int(os.environ.get("DFG_BATCH", "1"))

OUT = Path("graphs")
OUT.mkdir(exist_ok=True)

cfg = AutoConfig.from_pretrained(MODEL_ID)

# Instantiate parameters on meta device: no 65-GB weight allocation.
with torch.device("meta"):
    model = AutoModelForCausalLM.from_config(cfg)

# MLP is intentionally selected because it is a useful, static,
# easily traceable Qwen3 transformer subgraph.
mlp = model.model.layers[0].mlp
gm = symbolic_trace(mlp)

x = torch.empty(
    (BATCH, SEQ, cfg.hidden_size),
    device="meta",
    dtype=torch.bfloat16,
)

ShapeProp(gm).propagate(x)

nodes = []

for n in gm.graph.nodes:
    tm = n.meta.get("tensor_meta")
    shape = list(tm.shape) if tm is not None else None
    dtype = str(tm.dtype) if tm is not None else None

    nodes.append({
        "name": n.name,
        "op": n.op,
        "target": str(n.target),
        "shape": shape,
        "dtype": dtype,
        "users": [u.name for u in n.users],
    })

json_path = OUT / "qwen3_layer0_mlp_dfg.json"
json_path.write_text(json.dumps(nodes, indent=2))

def esc(s):
    return str(s).replace("\\", "\\\\").replace('"', '\\"')

dot = [
    "digraph Qwen3MLP {",
    '  rankdir="LR";',
    '  graph [fontname="Helvetica"];',
    '  node [shape=box, fontname="Helvetica"];',
]

for n in gm.graph.nodes:
    tm = n.meta.get("tensor_meta")
    extra = ""
    if tm is not None:
        extra = f"\\nshape={list(tm.shape)}\\ndtype={tm.dtype}"

    label = esc(f"{n.name}\\n{n.op}\\n{n.target}{extra}")
    dot.append(f'  "{n.name}" [label="{label}"];')

for n in gm.graph.nodes:
    for u in n.users:
        dot.append(f'  "{n.name}" -> "{u.name}";')

dot.append("}")

dot_path = OUT / "qwen3_layer0_mlp_dfg.dot"
dot_path.write_text("\n".join(dot) + "\n")

print(json_path)
print(dot_path)
