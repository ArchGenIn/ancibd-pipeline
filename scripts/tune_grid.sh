#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/tune_grid.sh
  CH_RANGE=2-2 PCOL=AF_ALL DURATION_SEC=120 ./scripts/tune_grid.sh
  ./scripts/tune_grid.sh --help

Purpose:
  Sweep a small grid of BATCH_SIZE and BP_MAXJOBS values against the prod
  workflow for a fixed time budget per grid point. Each point submits a DAG,
  waits DURATION_SEC, records progress, and then removes the DAG.

What it modifies:
  - edits config/local.env temporarily
  - restores the original config on exit
  - writes a summary TSV under runs/tuning/

Important environment variables:
  CH_RANGE              chromosome range to submit for each grid point
  PCOL                  AF_ALL, RAF, or AF_REF
  DURATION_SEC          wall-clock budget per grid point
  SLEEP_AFTER_RM_SEC    pause after condor_rm before sampling progress

Grid definition:
  Edit BATCH_SIZES and MAXJOBS_LIST in this script.

Resource derivation:
  request_cpus/request_memory/request_disk are derived from the minimum node
  resources reported by condor_status, then written into config/local.env for
  each grid point so the requested concurrency is packable in practice.
USAGE
}

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

# --- knobs you may want to change ---
CH_RANGE="${CH_RANGE:-2-2}"
PCOL="${PCOL:-AF_ALL}"
DURATION_SEC="${DURATION_SEC:-120}"
SLEEP_AFTER_RM_SEC="${SLEEP_AFTER_RM_SEC:-10}"

# Example 3x3 grid.
BATCH_SIZES=(100 300 500)
MAXJOBS_LIST=(1 16 32)

CFG="$ROOT/config/local.env"

CPU_SAFETY_NUM="${CPU_SAFETY_NUM:-9}"
CPU_SAFETY_DEN="${CPU_SAFETY_DEN:-10}"
MEM_SAFETY_NUM="${MEM_SAFETY_NUM:-9}"
MEM_SAFETY_DEN="${MEM_SAFETY_DEN:-10}"
DISK_SAFETY_NUM="${DISK_SAFETY_NUM:-8}"
DISK_SAFETY_DEN="${DISK_SAFETY_DEN:-10}"

DISK_MIN_MB="${DISK_MIN_MB:-1024}"
DISK_MAX_MB="${DISK_MAX_MB:-8192}"

FORCE_REQ_CPUS="${FORCE_REQ_CPUS:-}"
FORCE_REQ_DISK_MB="${FORCE_REQ_DISK_MB:-}"

ts_utc() { date -u +%Y%m%dT%H%M%SZ; }

die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

update_cfg_kv() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$CFG"; then
    perl -pi -e "s|^${key}=.*|${key}=\"${val}\"|g" "$CFG"
  else
    echo "${key}=\"${val}\"" >> "$CFG"
  fi
}

parse_cluster_id() {
  grep -Eo 'cluster[[:space:]]+[0-9]+' | awk '{print $2}' | tail -n 1
}

kill_dag_tree() {
  local dag_cluster="$1"
  local dag_jobid="${dag_cluster}.0"

  echo "Killing DAGMan cluster ${dag_cluster} and its children (DAGManJobId=${dag_jobid})..."

  condor_rm "${dag_cluster}" >/dev/null 2>&1 || true
  condor_rm -constraint "DAGManJobId == ${dag_jobid} || DAGManJobId == ${dag_cluster}" >/dev/null 2>&1 || true

  for _ in $(seq 1 60); do
    if ! condor_q -constraint "DAGManJobId == ${dag_jobid} || DAGManJobId == ${dag_cluster}" -af ClusterId ProcId 2>/dev/null | grep -q '[0-9]'; then
      break
    fi
    sleep 5
  done
}

summarize_progress() {
  local run_id="$1"
  local out
  out="$(RUN_ID="$run_id" "$ROOT/scripts/check_batch_status.sh" 2>/dev/null || true)"

  local expected complete percent
  expected="$(echo "$out" | awk '/^Expected:/ {print $2}' | head -n1)"
  complete="$(echo "$out" | awk '/^Complete:/ {print $2}' | head -n1)"
  percent="$(echo "$out" | awk -F'[()]' '/^Complete:/ {gsub(/[% ]/,"",$2); print $2}' | head -n1)"

  expected="${expected:-NA}"
  complete="${complete:-NA}"
  percent="${percent:-NA}"

  echo -e "${expected}\t${complete}\t${percent}"
}

get_node_baseline() {
  local out
  out="$(condor_status -constraint 'PartitionableSlot == True' -af Name Cpus TotalMemory Disk 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    out="$(condor_status -af Name Cpus TotalMemory Disk 2>/dev/null | awk '$1 ~ /^slot1@/' || true)"
  fi
  [[ -n "$out" ]] || die "Could not query execute slots (condor_status returned nothing)."

  echo "$out" | awk '
    BEGIN { n=0; minc=-1; minm=-1; mind_mb=-1; }
    {
      n++;
      c=$2; m=$3; d_kb=$4; d_mb=int(d_kb/1024);
      if (minc<0 || c<minc) minc=c;
      if (minm<0 || m<minm) minm=m;
      if (mind_mb<0 || d_mb<mind_mb) mind_mb=d_mb;
    }
    END { print n, minc, minm, mind_mb; }
  '
}

derive_requests() {
  local mj="$1" nodes="$2" nc="$3" nm="$4" nd="$5"

  local jpn=$(( (mj + nodes - 1) / nodes ))
  [[ "$jpn" -ge 1 ]] || jpn=1

  local req_cpus=$(( (nc * CPU_SAFETY_NUM) / (CPU_SAFETY_DEN * jpn) ))
  [[ "$req_cpus" -ge 1 ]] || req_cpus=1
  if [[ -n "${FORCE_REQ_CPUS:-}" ]]; then req_cpus="$FORCE_REQ_CPUS"; fi

  local req_mem_mb=$(( (nm * MEM_SAFETY_NUM) / (MEM_SAFETY_DEN * jpn) ))
  [[ "$req_mem_mb" -ge 256 ]] || req_mem_mb=256

  local req_disk_mb=$(( (nd * DISK_SAFETY_NUM) / (DISK_SAFETY_DEN * jpn) ))
  if [[ "$req_disk_mb" -lt "$DISK_MIN_MB" ]]; then req_disk_mb="$DISK_MIN_MB"; fi
  if [[ "$req_disk_mb" -gt "$DISK_MAX_MB" ]]; then req_disk_mb="$DISK_MAX_MB"; fi
  if [[ -n "${FORCE_REQ_DISK_MB:-}" ]]; then req_disk_mb="$FORCE_REQ_DISK_MB"; fi

  echo "$jpn $req_cpus $req_mem_mb $req_disk_mb"
}

main() {
  require_cmd perl
  require_cmd condor_submit_dag
  require_cmd condor_rm
  require_cmd condor_q
  require_cmd condor_status

  [[ -f "$CFG" ]] || die "Missing $CFG (copy from config/example.env)"

  local bak="${CFG}.bak.$(ts_utc)"
  cp -- "$CFG" "$bak"
  cleanup() { cp -- "$bak" "$CFG" || true; }
  trap cleanup EXIT

  read -r nodes node_cpus node_mem_mb node_disk_mb < <(get_node_baseline)
  echo "Pool baseline (min across $nodes execute nodes): CPUs=$node_cpus  Mem=${node_mem_mb}MB  Disk=${node_disk_mb}MB"
  echo "Safety ratios: CPU=${CPU_SAFETY_NUM}/${CPU_SAFETY_DEN}  Mem=${MEM_SAFETY_NUM}/${MEM_SAFETY_DEN}  Disk=${DISK_SAFETY_NUM}/${DISK_SAFETY_DEN}"
  echo

  local summary_dir="$ROOT/runs/tuning"
  mkdir -p "$summary_dir"

  local summary="$summary_dir/grid_$(ts_utc).tsv"
  echo -e "ts_utc\tbatch_size\tbp_maxjobs\tjobs_per_node\treq_cpus\treq_mem_mb\treq_disk_mb\trun_id\tdag_cluster\texpected\tcomplete\tpercent\tch_range\tduration_sec" > "$summary"

  echo "Writing summary to: $summary"
  echo "CH_RANGE=$CH_RANGE  PCOL=$PCOL  DURATION_SEC=$DURATION_SEC"
  echo

  for mj in "${MAXJOBS_LIST[@]}"; do
    read -r jpn req_cpus req_mem_mb req_disk_mb < <(derive_requests "$mj" "$nodes" "$node_cpus" "$node_mem_mb" "$node_disk_mb")

    for bs in "${BATCH_SIZES[@]}"; do
      local tag="tune_bs${bs}_mj${mj}"
      echo "=== Grid point: BATCH_SIZE=$bs  BP_MAXJOBS=$mj  (jobs/node~$jpn; req: ${req_cpus}cpu, ${req_mem_mb}MB, ${req_disk_mb}MB disk)  tag=$tag ==="

      update_cfg_kv "BATCH_SIZE" "$bs"
      update_cfg_kv "BP_MAXJOBS" "$mj"
      update_cfg_kv "BP_REQUEST_CPUS" "$req_cpus"
      update_cfg_kv "BP_REQUEST_MEMORY" "${req_mem_mb}MB"
      update_cfg_kv "BP_REQUEST_DISK" "${req_disk_mb}MB"

      local run_id
      run_id="$("$ROOT/ancibd-pipeline" new-run "$tag")"
      export RUN_ID="$run_id"

      local submit_log="$ROOT/runs/$run_id/logs/tuning_submit.log"
      mkdir -p "$(dirname "$submit_log")"

      echo "RUN_ID=$run_id"
      echo "Submitting DAG..."
      set +e
      "$ROOT/ancibd-pipeline" prod "$CH_RANGE" --pcol "$PCOL" 2>&1 | tee "$submit_log"
      local submit_rc=${PIPESTATUS[0]}
      set -e
      if [[ $submit_rc -ne 0 ]]; then
        echo "Submit failed (rc=$submit_rc). Continuing to next grid point."
        echo -e "$(ts_utc)\t$bs\t$mj\t$jpn\t$req_cpus\t$req_mem_mb\t$req_disk_mb\t$run_id\tNA\tNA\tNA\tNA\t$CH_RANGE\t$DURATION_SEC" >> "$summary"
        unset RUN_ID
        continue
      fi

      local dag_cluster
      dag_cluster="$(parse_cluster_id < "$submit_log")"
      dag_cluster="${dag_cluster:-NA}"
      echo "DAG cluster: $dag_cluster"

      echo "Sleeping ${DURATION_SEC}s..."
      sleep "$DURATION_SEC"

      if [[ "$dag_cluster" != "NA" ]]; then
        kill_dag_tree "$dag_cluster"
        sleep "$SLEEP_AFTER_RM_SEC"
      fi

      local stats expected complete percent
      stats="$(summarize_progress "$run_id")"
      expected="$(echo "$stats" | cut -f1)"
      complete="$(echo "$stats" | cut -f2)"
      percent="$(echo "$stats" | cut -f3)"

      echo "Progress after budget: expected=$expected complete=$complete percent=$percent"
      echo -e "$(ts_utc)\t$bs\t$mj\t$jpn\t$req_cpus\t$req_mem_mb\t$req_disk_mb\t$run_id\t$dag_cluster\t$expected\t$complete\t$percent\t$CH_RANGE\t$DURATION_SEC" >> "$summary"

      unset RUN_ID
      echo
    done
  done

  echo "Done. Summary: $summary"
}

main "$@"
