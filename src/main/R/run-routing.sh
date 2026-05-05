#!/bin/bash --login
#SBATCH --partition=cpu-genoa
#SBATCH --nodes=2
#SBATCH --cpus-per-task=192
#SBATCH --time=00:15:00
#SBATCH --job-name=rust-qsim-routing
#SBATCH --output=logs/rust-qsim-routing_%j.log
#SBATCH --mail-user=sven.habermann@campus.tu-berlin.de
#SBATCH --mail-type=BEGIN,END,FAIL

set -euo pipefail

for ARGUMENT in "$@"; do
   KEY=$(echo "$ARGUMENT" | cut -f1 -d=)
   KEY_LENGTH=${#KEY}
   VALUE="${ARGUMENT:$KEY_LENGTH+1}"
   export "$KEY"="$VALUE"
   echo "Start script with argument: $KEY=$VALUE"
done

SIM_CPUS=${SIM_CPUS:-192}
HORIZON=${HORIZON:-600}
WORKER_THREADS=${WORKER_THREADS:-4}
ROUTER_THREADS=${ROUTER_THREADS:-8}
PCT=${PCT:-1}
BIN_SIZE=${BIN_SIZE:-900}
BATCH_SIZE=${BATCH_SIZE:-10000}

THREADS_PER_NODE=192
NUM_ROUTING_NODES=$(( (ROUTER_THREADS + THREADS_PER_NODE - 1) / THREADS_PER_NODE ))
THREADS_PER_SERVER=$(( (ROUTER_THREADS + NUM_ROUTING_NODES - 1) / NUM_ROUTING_NODES ))

echo "Effective configuration:"
echo "  SIM_CPUS           = $SIM_CPUS"
echo "  HORIZON            = $HORIZON"
echo "  WORKER_THREADS     = $WORKER_THREADS"
echo "  ROUTER_THREADS     = $ROUTER_THREADS"
echo "  PCT                = $PCT"
echo "  NUM_ROUTING_NODES  = $NUM_ROUTING_NODES"
echo "  THREADS_PER_SERVER = $THREADS_PER_SERVER"
echo "  BIN_SIZE           = $BIN_SIZE"
echo "  BATCH_SIZE         = $BATCH_SIZE"

N="$SIM_CPUS"

nodes=($(scontrol show hostnames "$SLURM_NODELIST"))
required_nodes=$((1 + NUM_ROUTING_NODES))

if (( ${#nodes[@]} < required_nodes )); then
    echo "ERROR: expected $required_nodes nodes (1 client + $NUM_ROUTING_NODES router), got ${#nodes[@]}"
    echo "SLURM_NODELIST=$SLURM_NODELIST"
    printf 'resolved nodes: %s
' "${nodes[@]}"
    exit 1
fi

client_node="${nodes[0]}"

server_nodes=()
server_urls=""
for (( i=1; i<=NUM_ROUTING_NODES; i++ )); do
    server_node="${nodes[$i]}"
    server_nodes+=("$server_node")
    server_host_ib="${server_node}.ib.hlrn.de"
    if [[ -n "$server_urls" ]]; then
        server_urls+=" "
    fi
    server_urls+="http://${server_host_ib}:50051"
done

echo "Current hostname: $(hostname)"
echo "Client node: $client_node"
echo "Server nodes: ${server_nodes[*]}"
echo "Server URLs: $server_urls"

LOG_DIR="$PWD/logs"
mkdir -p "$LOG_DIR"
JOB_SUFFIX=${SLURM_JOB_ID:-$(date +%s)}

CONFIG_TAG="sim${SIM_CPUS}_hor${HORIZON}_w${WORKER_THREADS}_r${ROUTER_THREADS}_bin${BIN_SIZE}_batch${BATCH_SIZE}"
echo "Log configuration tag: $CONFIG_TAG"

source /home/$USER/miniforge3/etc/profile.d/conda.sh
conda activate routing

export NO_COLOR=1

ARGS=""
ARGS+=" --set computational_setup.adapter_worker_threads=${WORKER_THREADS}"
ARGS+=" --set output.output_dir=/scratch/usr/bemhaber/MATSimBA/parallel-qsim-berlin/output/v6.4/${CONFIG_TAG}"
ARGS+=" --event-sharing-bin-size-secs ${BIN_SIZE}"
ARGS+=" --event-sharing-closed-bin-batch-size ${BATCH_SIZE}"
ARGS+=" --preplanning-horizon ${HORIZON}"
ARGS+=" --num-routing-threads ${ROUTER_THREADS}"

if [[ -n "${EXTRA_ARGS:-}" ]]; then
  ARGS+=" ${EXTRA_ARGS}"
fi

ROUTER_ARGS=""
ROUTER_ARGS+=" --binSize ${BIN_SIZE}"
ROUTER_ARGS+=" --pH ${HORIZON}"
ROUTER_ARGS+=" --batchSize ${BATCH_SIZE}"
ROUTER_ARGS+=" --partitionCount ${SIM_CPUS}"
ROUTER_ARGS+=" --addString ${CONFIG_TAG}"

echo "Final ARGS for Rust client: $ARGS"
echo "Final ARGS for Java router: $ROUTER_ARGS"

(
  cd parallel-qsim-berlin
  srun -N1 -n1 -w "$client_node" \
    --output="$LOG_DIR/${CONFIG_TAG}_${JOB_SUFFIX}_client.log" \
    make run-routing \
      N="$N" \
      HORIZON="$HORIZON" \
      RUST_BASE=/scratch/usr/bemhaber/MATSimBA/parallel_qsim_rust \
      SHARED_DATA_BASE=/scratch/usr/bemhaber/MATSimBA/shared-data \
      MODE=cargo \
      PCT="$PCT" \
      URL="$server_urls" \
      RUN_ID="${CONFIG_TAG}_sim" \
      ARGS="$ARGS"
) &

sleep 2

for (( i=0; i<NUM_ROUTING_NODES; i++ )); do
    server_node="${server_nodes[$i]}"
    (
      cd parallel-qsim-berlin
      srun -N1 -n1 -w "$server_node" \
        --output="$LOG_DIR/${CONFIG_TAG}_${JOB_SUFFIX}_server_${i}.log" \
        make router \
          SHARED_DATA_BASE=/scratch/usr/bemhaber/MATSimBA/shared-data \
          HORIZON="$HORIZON" \
          THREADS="$THREADS_PER_SERVER" \
          MEMORY=500G \
          PCT="$PCT" \
          RUN_ID="${CONFIG_TAG}_server${i}" \
          ARGS="$ROUTER_ARGS"
    ) &
done

wait
echo "Run completed for configuration: $CONFIG_TAG"