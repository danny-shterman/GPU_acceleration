#!/usr/bin/env bash
RUN=$(ls -1dt results/qwen3_sys_trace/* | head -1)

if grep -q '^csv_conversion_exit_status=0$' "$RUN/profile_status.txt" 2>/dev/null &&
   grep -q '^pftrace_conversion_exit_status=0$' "$RUN/profile_status.txt" 2>/dev/null &&
   grep -q 'ROCPD conversions completed successfully' "$RUN/conversion.log" 2>/dev/null
then
    echo "DONE: ROCPD + CSV + PFTrace completed successfully"
else
    echo "NOT FINISHED or FAILED"
fi