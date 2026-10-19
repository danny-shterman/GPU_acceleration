#!/usr/bin/env bash
echo 'Check vllm serve process'
docker exec mi300x-qwen3-profile   bash -lc "pgrep -af '^/usr/bin/python3 /usr/local/bin/vllm serve ' || true"
echo 'Check rocprofv3|vllm serve|rocpd2csv|rocpd2pftrace processes'
docker exec mi300x-qwen3-profile   bash -lc "pgrep -af 'rocprofv3|vllm serve|rocpd2csv|rocpd2pftrace' || true"
