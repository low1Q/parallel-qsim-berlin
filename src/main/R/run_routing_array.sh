#!/bin/bash --login
#SBATCH --partition=cpu-genoa
#SBATCH --nodes=2
#SBATCH --cpus-per-task=192
#SBATCH --time=00:30:00
#SBATCH --job-name=ba_rust_qsim_routing_add_missing-to-fullrun
#SBATCH --output=logs/add_missing-to-fullrun_ba_rust_qsim_routing_horizons_%A_%a.log
#SBATCH --mail-user=sven.habermann@campus.tu-berlin.de
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --array=12-15,84-87,132-135,156-159,168-175,176,179,180,183,184,187,192-199,200,203,204,207,208,211,228-231,240-247,248,251,252,255,256,259,276-279,300-303,312-319,320,323,324,327,328,331,336-343,344,347,348,351,352,355,372-375,384-391,392,395,396,399,400,403,420-423,444-447,456-463,464,467,468,471,472,475,480-487,488,491,492,495,496,499,516-519,528-535,536,539,540,543,544,547,564-567%4

set -euo pipefail

BATCH_SIZES=(500 10000 25000 45000)
ROUTER_THREADS_LIST=(1 8 24 48 96 192)
PARTITIONS_LIST=(1 16 32 64 128 192)
HORIZONS=(0 200 600 1800)

#BATCH_SIZES=(500 10000 25000 45000)
#ROUTER_THREADS_LIST=(1 8 24 48 96)
#ROUTER_THREADS_LIST=(48)
#PARTITIONS_LIST=(1 64 192)
#PARTITIONS_LIST=(16 32 128)
#HORIZONS=(0 200 600 1800)

#BATCH_SIZES=(500 5000 15000)
#ROUTER_THREADS_LIST=(1 96 192)
#PARTITIONS_LIST=(1 32 128 192)
#HORIZONS=(0 200 600)

#BATCH_SIZES=(5000)
#ROUTER_THREADS_LIST=(96 192)
#PARTITIONS_LIST=(16 32 192)
#HORIZONS=(200 600 1800)

WORKER_THREADS=4
BIN_SIZE=900
PCT=1

idx="${SLURM_ARRAY_TASK_ID}"

num_batch=${#BATCH_SIZES[@]}
num_router=${#ROUTER_THREADS_LIST[@]}
num_parts=${#PARTITIONS_LIST[@]}
num_horizon=${#HORIZONS[@]}

horizon_idx=$(( idx / (num_parts * num_router * num_batch) ))
rem0=$(( idx % (num_parts * num_router * num_batch) ))

part_idx=$(( rem0 / (num_router * num_batch) ))
rem1=$(( rem0 % (num_router * num_batch) ))

router_idx=$(( rem1 / num_batch ))
batch_idx=$(( rem1 % num_batch ))

HORIZON="${HORIZONS[$horizon_idx]}"
SIM_CPUS="${PARTITIONS_LIST[$part_idx]}"
ROUTER_THREADS="${ROUTER_THREADS_LIST[$router_idx]}"
BATCH_SIZE="${BATCH_SIZES[$batch_idx]}"

echo "Array task id:   $idx"
echo "SIM_CPUS:        $SIM_CPUS"
echo "ROUTER_THREADS:  $ROUTER_THREADS"
echo "HORIZON:         $HORIZON"
echo "BIN_SIZE:        $BIN_SIZE"
echo "BATCH_SIZE:      $BATCH_SIZE"
echo "WORKER_THREADS:  $WORKER_THREADS"
echo "PCT:             $PCT"

bash run-routing.sh \
  SIM_CPUS="${SIM_CPUS}" \
  ROUTER_THREADS="${ROUTER_THREADS}" \
  HORIZON="${HORIZON}" \
  BIN_SIZE="${BIN_SIZE}" \
  BATCH_SIZE="${BATCH_SIZE}" \
  WORKER_THREADS="${WORKER_THREADS}" \
  PCT="${PCT}"