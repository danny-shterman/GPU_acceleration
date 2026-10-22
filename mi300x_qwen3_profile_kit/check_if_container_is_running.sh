#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${1:-mi300x-qwen3-profile}"

# Check Docker daemon availability
if ! command -v docker &>/dev/null; then
    echo "Error: docker command not found."
    exit 2
fi

# Verify running state
is_running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)

if [ "$is_running" = "true" ]; then
    echo "Status: Container '$CONTAINER_NAME' is RUNNING."
    exit 0
else
    # Check if the container exists at all but is stopped/exited
    if docker inspect "$CONTAINER_NAME" &>/dev/null; then
        status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")
        echo "Status: Container '$CONTAINER_NAME' exists but is NOT running (State: $status)."
    else
        echo "Status: Container '$CONTAINER_NAME' does not exist."
    fi
    exit 1
fi

