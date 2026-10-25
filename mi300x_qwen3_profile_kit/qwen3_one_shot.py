from transformers import AutoTokenizer
from vllm import LLM, SamplingParams
from vllm.inputs import TokensPrompt

MODEL = "Qwen/Qwen3-32B"
TARGET_INPUT_TOKENS = 2048

# Build an exact-length deterministic token sequence.
tokenizer = AutoTokenizer.from_pretrained(MODEL)

seed_text = (
    "Analyze this deterministic systems performance workload. "
    "The purpose of this prompt is GPU profiling of transformer "
    "prefill execution on AMD MI300X. "
)

seed_ids = tokenizer.encode(seed_text, add_special_tokens=False)

prompt_ids = (
    seed_ids
    * ((TARGET_INPUT_TOKENS + len(seed_ids) - 1) // len(seed_ids))
)[:TARGET_INPUT_TOKENS]

assert len(prompt_ids) == TARGET_INPUT_TOKENS

llm = LLM(
    model=MODEL,
    tensor_parallel_size=1,
    dtype="bfloat16",
    max_model_len=32768,
    gpu_memory_utilization=0.90,
    enable_prefix_caching=False,
)

sampling_params = SamplingParams(
    temperature=0.0,
    max_tokens=1,
)

outputs = llm.generate(
    TokensPrompt(prompt_token_ids=prompt_ids),
    sampling_params,
    use_tqdm=False,
)

output = outputs[0]

print("input_tokens:", len(prompt_ids))
print("output_tokens:", len(output.outputs[0].token_ids))
print("generated_token_ids:", output.outputs[0].token_ids)
