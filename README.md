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
If while trying to run ./01_start_container.sh you get something like:
```
docker: Error response from daemon: Conflict. The container name "/mi300x-qwen3-profile" is already in use by container "bd88366f51003eee9ecdeb5acb638408dc27ed28de6f216b4e5106f8f178e885". You have to remove (or rename) that container to be able to reuse that name.
```
Then in order to kill the old docker use:
```
docker rm -f bd88366f51003eee9ecdeb5acb638408dc27ed28de6f216b4e5106f8f178e885
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

From mi300x_qwen3_profile_kit (02_serve_qwen3_32b.sh runs vllm serve '${MODEL_ID}'):
```
source .env
./02_serve_qwen3_32b.sh
```
It could take quite time till VLLM server will be ready.

Check the existing server from the host:
```
docker ps
```
and:
```
curl http://localhost:8000/v1/models
```
or from the container:
```
curl http://127.0.0.1:8000/health
```
Then inspect the server log (could be done from another terminal):
```
docker exec mi300x-qwen3-profile \
    tail -100 /workspace/kit/results/vllm_server.log
```

Now vllm serve is running. Perform:
```
vLLM READY (from 02_serve_qwen3_32b.sh)
   |
   +-- bash 05_monitor_amd_smi.sh (from Terminal 2)
   |
   +-- bash 03_bench_serving.sh (from Terminal 3)
   |
   +-- wait until 03_bench_serving.sh finishes
   |
   +-- stop 05_monitor_amd_smi.sh
```
and
```
vLLM READY (02_serve_qwen3_32b.sh)
   |
   +-- bash 05_monitor_amd_smi.sh (from Terminal 2)
   |
   +-- bash 04_bench_prefill.sh (from Terminal 3)
   |
   +-- wait until 04_bench_prefill.sh finishes
   |
   +-- stop 05_monitor_amd_smi.sh
```
03_bench_serving.sh generates bench_serving_<timestamp>.json and bench_serving_<timestamp>.log files. 
04_bench_prefill.sh generates prefill_[short|medium|long|large batch]_<timestamp>.json files.
05_monitor_amd_smi.sh generates amd_smi_monitor_<timestamp>.csv foe both scripts.
vllm_server.log is updated all the time.
03_bench_serving.sh and 04_bench_prefill.sh should not run at the 





From mi300x_qwen3_profile_kit in another terminal (03_bench_serving.sh runs vllm bench serve):
```
./03_bench_serving.sh
```
Now run (04_bench_prefill.sh runs vllm bench serve):
```
bash 04_bench_prefill.sh
```
python3 ./07_generate_prompts.py should be run from inside the docker:
```
docker exec mi300x-qwen3-profile \
  bash -lc 'cd /workspace/kit && python3 ./07_generate_prompts.py'
```
To kill vllm serve process running in docker use:
```
docker exec mi300x-qwen3-profile   bash -lc 'pkill -f "vllm serve" || true'
```
To check that vllm serve process doesn't run use:
```
docker exec mi300x-qwen3-profile   bash -lc 'ps -ef | grep -E "vllm|VLLM" | grep -v grep || true'
```
To kill vllm serve process running under rocprof in docker use:
```
docker exec mi300x-qwen3-profile   bash -lc 'pkill -f "rocprofv3" || true'
```
To check that vllm serve process under rocprof doesn't run use:
```
docker exec mi300x-qwen3-profile   bash -lc 'ps -ef | grep -E "vllm|VLLM" | grep -v grep || true'
```
To check peak GPU memory use:
```
bash 05_monitor_amd_smi.sh
```
it executes:
```
amd-smi monitor \
--gpu 0 \
--gfx \
--mem \
--vram-usage \
--pcie \
--watch 0.1 \
--csv \
--file amd_smi_monitor.csv
```
Take:
```
max(VRAM_USAGE)
```
over the measured interval.

To check HBM latency use:
```
bash 06_build_and_run_hbm_latency.sh
```
The build command is:
```
hipcc -O3 --offload-arch=gfx942 hbm_latency.hip -o hbm_latency
```
Then perform repeated 1-GiB measurements by using:
```
for i in $(seq 1 10); do
    ./hbm_latency $((1024*1024*1024)) 64
done
```
It also could be repeated with different strides:
```
./hbm_latency $((1024*1024*1024)) 64
./hbm_latency $((1024*1024*1024)) 128
./hbm_latency $((1024*1024*1024)) 256
```
This measures approximately:
    dependent, cache-missing GPU global-memory load-to-use latency
through the real MI300X memory hierarchy.

To generate a simplified DFG of Qwen-style transformer block run from inside the docker:
```
python3 /workspace/kit/08_static_dfg.py
```
This python reads the model configuration and emits:
    qwen3_block_dfg.dot
which you can render with Graphviz:
```
dot -Tsvg qwen3_block_dfg.dot -o qwen3_block_dfg.svg
```
The files are generated in docker /app directory.
Copy this file to host from host terminal by using:
```
docker cp mi300x-qwen3-profile:/app ./docker_app_copy
```
That command copies everything from docker /app directory to ./docker_app_copy directory on the host.

If there is this error:
```
ValueError: Free memory on device cuda:0 (22.34/191.69 GiB)
on startup is less than desired GPU memory utilization
(0.9, 172.52 GiB).
```
when running vllm serve then solve it as follows (check GPU VRAM state):
```
rocm-smi --showpids; rocm-smi --showmeminfo vram
```
and
```
docker exec mi300x-qwen3-profile \
  bash -lc "ps -eo pid,ppid,stat,cmd | grep -E '[v]llm|[p]ython|[r]ocprof' || true"
```
If you there are orphaned multiprocessing.spawn / Python GPU processes, terminate them:
```
docker exec mi300x-qwen3-profile \
  bash -lc "
    pkill -TERM -f '[v]llm' || true
    pkill -TERM -f 'multiprocessing.spawn' || true
    pkill -TERM -f '[r]ocprofv3' || true
  "
```
wait 10 seconds and check again until the problematic process is gone.





