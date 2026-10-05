echo
echo "Waiting for server readiness..."

MAX_ATTEMPTS=300

for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do

    HTTP_CODE="$(
        docker exec "$CONTAINER_NAME" \
            curl -s -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:${PORT}/health" \
            2>/dev/null || true
    )"

    if [[ "$HTTP_CODE" == "200" ]]; then
        echo
        echo "vLLM server is READY."
        echo

        echo "Health:"
        docker exec "$CONTAINER_NAME" \
            curl -sS "http://127.0.0.1:${PORT}/health"

        echo
        echo "Models:"
        docker exec "$CONTAINER_NAME" \
            curl -sS "http://127.0.0.1:${PORT}/v1/models"

        echo
        echo
        echo "Server URL:"
        echo "  http://127.0.0.1:${PORT}"
        echo

        exit 0
    fi

    if (( attempt % 5 == 0 )); then
        echo "Still waiting... attempt ${attempt}/${MAX_ATTEMPTS}, HTTP=${HTTP_CODE:-none}"
    fi

    sleep 2
done

echo
echo "ERROR: vLLM did not become ready."
echo
echo "Last 100 lines of server log:"

docker exec "$CONTAINER_NAME" \
    bash -lc 'tail -n 100 /workspace/kit/results/vllm_server.log'

exit 1
