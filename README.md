# GPU_acceleration

First collect the machine state:
```
unzip mi300x_qwen3_profile_kit.zip
cd mi300x_qwen3_profile_kit

bash 00_collect_system.sh
```
You should now have:
```
system_snapshot/
    host.txt
    amd_smi_version.txt
    amd_smi_list.txt
    amd_smi_static_gpu0.txt
    amd_smi_metric_gpu0.txt
    amd_smi_topology.txt
    amd_smi_xgmi.txt
    amd_smi_partition.txt
    rocminfo.txt
    hipconfig.txt
    lspci.txt
    numactl.txt
    ...
```

```make_mi300x_qwen3_profile_kit.sh creates the complete directory, validates the generated files, generates the full DOT DFG, and produces mi300x_qwen3_profile_kit.zip on your machine.

cd mi300x_qwen3_profile_kit

cp .env.example .env
source .env

./01_start_container.sh
```

Then verify:
```
docker ps -a --filter name=mi300x-qwen3-profile
```
Exit docker if it works OK:
```
exit
```

Now:
```
docker exec -it mi300x-qwen3-profile bash
```

Once inside, verify that the MI300X is visible:
```
rocminfo | grep -E 'Name:|Marketing Name:'
```

and:
```
python3 - <<'PY'
import torch

print("PyTorch:", torch.__version__)
print("HIP:", torch.version.hip)
print("GPU available:", torch.cuda.is_available())
print("GPU count:", torch.cuda.device_count())

for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    print(f"GPU {i}: {p.name}")
    print(f"  memory = {p.total_memory / 1024**3:.2f} GiB")
PY
```

Exit the docker shell:
```
exit
```

From mi300x_qwen3_profile_kit:
```
source .env
./02_serve_qwen3_32b.sh
```

Check:
```
docker ps
```
and:
```
curl http://localhost:8000/v1/models
```
Then inspect the server log:
```
docker exec mi300x-qwen3-profile \
    tail -100 /workspace/kit/results/vllm_server.log
```
