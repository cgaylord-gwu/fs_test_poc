#!/usr/bin/env bash
# Submits the single-node IOR, multi-node IOR, and mdtest jobs in sequence
# (each waits for the prior to finish, so they don't contend with each
# other and skew results). Prints job IDs and tails output as it becomes
# available.

set -euo pipefail
cd "$(dirname "$0")"

echo "Submitting single-node IOR..."
JOB1=$(sbatch --parsable 01_ior_single_node.sh)
echo "  job ${JOB1}, waiting..."
srun --jobid="${JOB1}" --wait=0 true 2>/dev/null || true
while squeue -j "${JOB1}" -h | grep -q .; do sleep 10; done
echo "  done."

echo "Submitting multi-node IOR..."
JOB2=$(sbatch --parsable 02_ior_multi_node.sh)
echo "  job ${JOB2}, waiting..."
while squeue -j "${JOB2}" -h | grep -q .; do sleep 10; done
echo "  done."

echo "Submitting mdtest..."
JOB3=$(sbatch --parsable 03_mdtest_single_node.sh)
echo "  job ${JOB3}, waiting..."
while squeue -j "${JOB3}" -h | grep -q .; do sleep 10; done
echo "  done."

echo ""
echo "All three runs complete. Output files:"
ls -1t ior_single_node_*.txt ior_multi_node_*.txt mdtest_*.txt 2>/dev/null | head -3
echo ""
echo "Next: python3 parse_results.py"

