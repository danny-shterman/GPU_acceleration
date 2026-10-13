# GPU_acceleration

make_mi300x_qwen3_profile_kit.sh creates the complete directory, validates the generated files, generates the full DOT DFG, and produces mi300x_qwen3_profile_kit.zip on your machine.

cd mi300x_qwen3_profile_kit

cp .env.example .env
source .env

./01_start_container.sh

Then verify:

docker ps -a --filter name=mi300x-qwen3-profile

Now:

docker exec -it mi300x-qwen3-profile bash

Once inside, verify that the MI300X is visible:

```rocminfo | grep -E 'Name:|Marketing Name:'

and:

``` python3 - <<'PY'
import torch

print("PyTorch:", torch.__version__)
print("HIP:", torch.version.hip)
print("GPU available:", torch.cuda.is_available())
print("GPU count:", torch.cuda.device_count())

for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    print(f"GPU {i}: {p.name}")
    print(f"  memory = {p.total_memory / 1024**3:.2f} GiB")
```PY

Exit the interactive shell:

```exit
