#!/usr/bin/env bash
while sleep 60; do
    LOG=results/vllm_rocprof_server.log

    if [ -f "$LOG" ]; then
        SIZE=$(stat -c %s "$LOG")

        if [ "$SIZE" -gt $((10 * 1024 * 1024 * 1024)) ]; then
            echo "Truncating $LOG at $(date), size=$SIZE"
            truncate -s 0 "$LOG"
        fi
    fi
done
