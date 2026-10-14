#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

load_config() {
  local root cfg
  root="$(repo_root)"
  cfg="$root/config/local.env"
  [[ -f "$cfg" ]] || die "Missing $cfg (copy from config/example.env)"
  # shellcheck source=../config/local.env
  source "$cfg"

  [[ -n "${SIF_IMAGE:-}" ]] || die "SIF_IMAGE not set in config/local.env"
  [[ -n "${DATA_ROOT:-}" ]] || die "DATA_ROOT not set in config/local.env"
  [[ -n "${HDF5_ROOT:-}" ]] || die "HDF5_ROOT not set in config/local.env"
  [[ -n "${RUNS_ROOT:-}" ]] || die "RUNS_ROOT not set in config/local.env"

  HDF5_PREFIX="${HDF5_PREFIX:-${PREFIX:-}}"
  HDF5_CH_LABEL="${HDF5_CH_LABEL:-ch}"
  HDF5_SUFFIX="${HDF5_SUFFIX:-}"
  HDF5_EXT="${HDF5_EXT:-.h5}"
  VCF_1240K_SUFFIX="${VCF_1240K_SUFFIX:-.1240k.vcf.gz}"
  BP_MAXJOBS="${BP_MAXJOBS:-0}"
  MERGE_CH_ALL="${MERGE_CH_ALL:-0}"
}

tpl() {
  local template="$1" ch="$2"
  echo "${template//\{CH\}/$ch}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

abs_path() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd)
  else
    local dir base
    dir="$(dirname "$p")"
    base="$(basename "$p")"
    (cd "$dir" && printf '%s/%s\n' "$(pwd)" "$base")
  fi
}

require_batchpair_requests() {
  [[ -n "${BP_REQUEST_CPUS:-}" ]] || die "BP_REQUEST_CPUS not set in config/local.env"
  [[ -n "${BP_REQUEST_MEMORY:-}" ]] || die "BP_REQUEST_MEMORY not set in config/local.env"
  [[ -n "${BP_REQUEST_DISK:-}" ]] || die "BP_REQUEST_DISK not set in config/local.env"
}

data_root_norm() {
  echo "${DATA_ROOT%/}"
}

hdf5_root_norm() {
  echo "${HDF5_ROOT%/}"
}

rel_under_data() {
  local p="$1" root
  root="$(data_root_norm)"
  case "$p" in
    "$root"/*) printf '%s\n' "${p#"$root"/}" ;;
    *) die "Path is not under DATA_ROOT ($root): $p" ;;
  esac
}

rel_under_hdf5() {
  local p="$1" root
  root="$(hdf5_root_norm)"
  case "$p" in
    "$root"/*) printf '%s\n' "${p#"$root"/}" ;;
    *) die "Path is not under HDF5_ROOT ($root): $p" ;;
  esac
}

parse_ch_range() {
  local r="$1"
  [[ "$r" =~ ^[0-9]+-[0-9]+$ ]] || die "Invalid chromosome range (expected N-M): $r"
  local a="${r%-*}" b="${r#*-}"
  (( a >= 1 && b >= a && b <= 22 )) || die "Chromosome range out of bounds (1-22): $r"
  echo "$a $b"
}

h5_path_for_ch() {
  local ch="$1"
  if [[ -n "${HDF5_TEMPLATE:-}" ]]; then
    tpl "$HDF5_TEMPLATE" "$ch"
  else
    echo "${HDF5_ROOT%/}/${HDF5_PREFIX}${HDF5_CH_LABEL}${ch}${HDF5_SUFFIX}${HDF5_EXT}"
  fi
}

vcf_1240k_path_for_ch() {
  local ch="$1"
  if [[ -n "${VCF_1240K_TEMPLATE:-}" ]]; then
    tpl "$VCF_1240K_TEMPLATE" "$ch"
  else
    echo "${HDF5_ROOT%/}/${HDF5_PREFIX}${HDF5_CH_LABEL}${ch}${HDF5_SUFFIX}${VCF_1240K_SUFFIX}"
  fi
}

find_h5_for_iids() {
  local ch_range="${CH_RANGE:-20-20}"
  local any_h5="" h5="" c
  local ch_start ch_end

  read -r ch_start ch_end < <(parse_ch_range "$ch_range")
  for ((c=ch_start; c<=ch_end; c++)); do
    h5="$(h5_path_for_ch "$c")"
    if [[ -f "$h5" ]]; then
      printf '%s\n' "$h5"
      return 0
    fi
  done

  any_h5="$(find "$(hdf5_root_norm)" -maxdepth 2 -type f -name '*.h5' | head -n 1 || true)"
  [[ -n "$any_h5" ]] || die "No HDF5 files found under HDF5_ROOT ($(hdf5_root_norm))."
  printf '%s\n' "$any_h5"
}

# Filesystem safety for tools with several inputs and outputs. realpath -m
# resolves existing symlinks and normalises even not-yet-created output paths;
# -ef also catches hard links to an existing input or another output.
paths_alias() {
  local a="$1" b="$2"
  [[ "$(realpath -m -- "$a")" == "$(realpath -m -- "$b")" ]] || \
    [[ -e "$a" && -e "$b" && "$a" -ef "$b" ]]
}

# Usage: assert_distinct_io_paths INPUT... -- OUTPUT...
# All outputs must be different from all inputs AND other outputs. This check
# is mandatory even with --force; never clobber source data by accident.
assert_distinct_io_paths() {
  local -a inputs=() outputs=()
  local output_phase=0 path input
  for path in "$@"; do
    if [[ "$path" == '--' && "$output_phase" -eq 0 ]]; then
      output_phase=1
    elif [[ "$output_phase" -eq 0 ]]; then
      inputs+=("$path")
    else
      outputs+=("$path")
    fi
  done
  [[ "$output_phase" -eq 1 ]] || die 'Internal error: missing -- in path validation'
  for path in "${outputs[@]}"; do
    [[ ! -L "$path" ]] || die "Refusing to overwrite symlink output: $path"
    for input in "${inputs[@]}"; do
      if paths_alias "$path" "$input"; then
        die "Output path aliases input: $path (input: $input)"
      fi
    done
  done
  local i j
  for ((i=0; i<${#outputs[@]}; i++)); do
    for ((j=i+1; j<${#outputs[@]}; j++)); do
      if paths_alias "${outputs[$i]}" "${outputs[$j]}"; then
        die "Output paths alias each other: ${outputs[$i]} and ${outputs[$j]}"
      fi
    done
  done
}

# Helpers may be invoked directly, not only through guarded prod commands.
# Completed work must never be reinterpreted by regenerating its plan/IID list.
assert_run_unpopulated_for_metadata() {
  local run_dir="$1"
  [[ ! -e "$run_dir/DONE" ]] || die "Run is DONE; refusing to change scientific metadata: $run_dir"
  if [[ -d "$run_dir/out" ]] && [[ -n "$(find "$run_dir/out" -mindepth 1 -print -quit)" ]]; then
    die "Run has job outputs; refusing to change scientific metadata: $run_dir/out"
  fi
  if [[ -d "$run_dir/work" ]] && [[ -n "$(find "$run_dir/work" -mindepth 1 -print -quit)" ]]; then
    die "Run work directory is populated; refusing to change scientific metadata: $run_dir/work"
  fi
  [[ ! -e "$run_dir/meta/pairjobs.tsv" ]] || die "Run already has a pairjob plan: $run_dir"
}

# A failed bcftools command should never remove the preceding valid output.
# Generate/index/check a temporary BCF in the destination directory, then
# replace the final BCF and its CSI only after successful validation.
new_staged_bcf() {
  local out="$1"
  mktemp "$(dirname "$out")/.$(basename "$out").tmp.XXXXXXXX.bcf"
}

publish_staged_bcf() {
  local staged="$1" out="$2"
  [[ -s "$staged" && -s "$staged.csi" ]] || die "Staged BCF/index missing: $staged"
  mv -f -- "$staged" "$out"
  mv -f -- "$staged.csi" "$out.csi"
  rm -f -- "$out.tbi"  # stale index from a previous version (if present)
}
