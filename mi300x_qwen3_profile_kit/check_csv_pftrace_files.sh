#!/usr/bin/env bash
RUN=$(ls -1dt results/qwen3_sys_trace/* | head -1)

CSV_COUNT=$(find "$RUN/converted" -type f -name '*.csv' 2>/dev/null | wc -l)
PF_COUNT=$(find "$RUN/converted" -type f -name '*.pftrace' 2>/dev/null | wc -l)

if grep -q '^csv_conversion_exit_status=0$' "$RUN/profile_status.txt" 2>/dev/null &&
   grep -q '^pftrace_conversion_exit_status=0$' "$RUN/profile_status.txt" 2>/dev/null &&
   (( CSV_COUNT > 0 )) &&
   (( PF_COUNT > 0 ))
then
    echo "SUCCESS"
    echo "CSV files:     $CSV_COUNT"
    echo "PFTrace files: $PF_COUNT"
else
    echo "NOT COMPLETE"
fi