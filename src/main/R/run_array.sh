#!/bin/bash --login
#SBATCH --partition=cpu-genoa
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=192
#SBATCH --time=00:30:00
#SBATCH --job-name=ba_rust_qsim_run
#SBATCH --output=logs/ba_rust_qsim_run_%A_%a.log
#SBATCH --mail-user=sven.habermann@campus.tu-berlin.de
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --array=0-8%4

set -euo pipefail

SIM_CPUS_LIST=(1 8 16 32 64 96 128 164 192)

HORIZON=600
WORKER_THREADS=4
BIN_SIZE=900
PCT=1
MODE=bin

idx="${SLURM_ARRAY_TASK_ID}"

SIM_CPUS="${SIM_CPUS_LIST[$idx]}"

echo "Array task id:   $idx"
echo "SIM_CPUS:        $SIM_CPUS"
echo "HORIZON:         $HORIZON"
echo "BIN_SIZE:        $BIN_SIZE"
echo "WORKER_THREADS:  $WORKER_THREADS"
echo "PCT:             $PCT"
echo "MODE:            $MODE"

bash run.sh \
  SIM_CPUS="${SIM_CPUS}" \
  HORIZON="${HORIZON}" \
  BIN_SIZE="${BIN_SIZE}" \
  WORKER_THREADS="${WORKER_THREADS}" \
  PCT="${PCT}" \
  MODE="${MODE}"