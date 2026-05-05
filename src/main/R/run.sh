#!/bin/bash --login
#SBATCH --partition=cpu-genoa
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=192
#SBATCH --time=00:30:00
#SBATCH --job-name=rust-qsim-run
#SBATCH --output=logs/rust-qsim-run_%j.log
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
PCT=${PCT:-1}
BIN_SIZE=${BIN_SIZE:-900}
BATCH_SIZE=${BATCH_SIZE:-10000}
MODE=${MODE:-bin}

WORKBASE=/scratch/usr/bemhaber/MATSimBA
RUST_BASE=${RUST_BASE:-$WORKBASE/parallel_qsim_rust}
SHARED_DATA_BASE=${SHARED_DATA_BASE:-$WORKBASE/shared-data}

echo "Effective configuration:"
echo "  SIM_CPUS        = $SIM_CPUS"
echo "  HORIZON         = $HORIZON"
echo "  WORKER_THREADS  = $WORKER_THREADS"
echo "  PCT             = $PCT"
echo "  BIN_SIZE        = $BIN_SIZE"
echo "  BATCH_SIZE      = $BATCH_SIZE"
echo "  MODE            = $MODE"
echo "  RUST_BASE       = $RUST_BASE"
echo "  SHARED_DATA_BASE= $SHARED_DATA_BASE"

LOG_DIR="$PWD/logs"
mkdir -p "$LOG_DIR"
JOB_SUFFIX=${SLURM_JOB_ID:-$(date +%s)}

CONFIG_TAG="sim${SIM_CPUS}_hor${HORIZON}_w${WORKER_THREADS}_bin${BIN_SIZE}_batch${BATCH_SIZE}_${PCT}pct"
echo "Log configuration tag: $CONFIG_TAG"

source /home/$USER/miniforge3/etc/profile.d/conda.sh
conda activate routing

export WORKBASE
export MAVEN_USER_HOME="$WORKBASE/.m2"
export MAVEN_OPTS="-Dmaven.repo.local=$WORKBASE/.m2/repository"
export CARGO_HOME="$WORKBASE/.cargo"
export RUSTUP_HOME="$WORKBASE/.rustup"
export CARGO_TARGET_DIR="$WORKBASE/.cargo-target"
export XDG_CONFIG_HOME="$WORKBASE/.config"
export PATH="$CARGO_HOME/bin:$PATH"
export NO_COLOR=1
export RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN:-stable-x86_64-unknown-linux-gnu}

mkdir -p "$WORKBASE/.m2/repository" \
         "$WORKBASE/.cargo" \
         "$WORKBASE/.rustup" \
         "$WORKBASE/.cargo-target" \
         "$WORKBASE/.config" \
         "$WORKBASE/logs"

echo "Java:  $(which java)"
java -version
echo "Cargo: $(which cargo)"
cargo --version || true

ARGS=""
ARGS+=" --set computational_setup.adapter_worker_threads=${WORKER_THREADS}"
ARGS+=" --set output.output_dir=/scratch/usr/bemhaber/MATSimBA/parallel-qsim-berlin/output/v6.4/${CONFIG_TAG}"

if [[ -n "${EXTRA_ARGS:-}" ]]; then
  ARGS+=" ${EXTRA_ARGS}"
fi

echo "Final ARGS: $ARGS"

cd /scratch/usr/bemhaber/MATSimBA/parallel-qsim-berlin

srun -N1 -n1 --cpus-per-task="$SIM_CPUS" \
  --output="$LOG_DIR/${CONFIG_TAG}_${JOB_SUFFIX}_run.log" \
  make run \
    N="$SIM_CPUS" \
    RUST_BASE="$RUST_BASE" \
    SHARED_DATA_BASE="$SHARED_DATA_BASE" \
    MODE="$MODE" \
    PCT="$PCT" \
    ARGS="$ARGS"

echo "Run completed for configuration: $CONFIG_TAG"