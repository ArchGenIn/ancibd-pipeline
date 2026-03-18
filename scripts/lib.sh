#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

load_config() {
  local root; root="$(repo_root)"
  local cfg="$root/config/local.env"
  [[ -f "$cfg" ]] || die "Missing $cfg (copy from config/example.env)"
  # ShellCheck can't follow dynamic paths; this is always the repo-local config.
  # shellcheck source=../config/local.env
  source "$cfg"

  [[ -n "${SIF_IMAGE:-}" ]] || die "SIF_IMAGE not set in config/local.env"
  [[ -n "${DATA_ROOT:-}" ]] || die "DATA_ROOT not set in config/local.env"
  [[ -n "${HDF5_ROOT:-}" ]] || die "HDF5_ROOT not set in config/local.env"
  [[ -n "${RUNS_ROOT:-}" ]] || die "RUNS_ROOT not set in config/local.env"

  # Backwards-compatible defaults for HDF5/VCF naming components.
  # Users may either set explicit *_TEMPLATE variables with {CH}, or configure
  # the naming via prefix/suffix/ch-label components.
  if [[ -z "${HDF5_PREFIX+x}" ]]; then
    if [[ -n "${PREFIX:-}" ]]; then
      HDF5_PREFIX="${PREFIX}."
    else
      HDF5_PREFIX=""
    fi
  fi
  HDF5_CH_LABEL="${HDF5_CH_LABEL:-ch}"
  HDF5_SUFFIX="${HDF5_SUFFIX:-}"
  HDF5_EXT="${HDF5_EXT:-.h5}"

  VCF_1240K_SUFFIX="${VCF_1240K_SUFFIX:-.1240k.vcf.gz}"

  # Optional standalone reference-AF template. The preferred config variable is
  # REF_AF_TEMPLATE; RAF_TEMPLATE remains available as a backward-compatible alias.
  if [[ -z "${REF_AF_TEMPLATE:-}" && -n "${RAF_TEMPLATE:-}" ]]; then
    REF_AF_TEMPLATE="$RAF_TEMPLATE"
  fi

  # --- HTCondor / DAGMan tuning ---
  # Optional global concurrency cap for prod batchpair nodes.
  # If BP_MAXJOBS is 0 or empty, no MAXJOBS line is emitted.
  BP_MAXJOBS="${BP_MAXJOBS:-0}"

  # Resource requests for batchpair jobs (partitionable slot friendly).
  # These can be overridden explicitly in config/local.env.
  BP_REQUEST_CPUS="${BP_REQUEST_CPUS:-1}"
  BP_REQUEST_DISK="${BP_REQUEST_DISK:-2GB}"

  if [[ -z "${BP_REQUEST_MEMORY:-}" ]]; then
    # Derive a conservative default request_memory from BATCH_SIZE.
    # Motivation: batchpair memory scales ~linearly with the number of loaded
    # individuals (~2*S), but *which* batchpair is worst-case is data-dependent.
    #
    # Empirical anchor (workstation timev, huge HDF5): some batchpairs reached
    # ~4.5 GiB at S=200 even when 0-1 was much smaller.
    # Use an anchor slightly above that (4800 MB at S=200) and a safety factor
    # of 1.4x, scaled linearly with S.
    #
    # Formula (in MB): ceil( 4800 * S * 1.4 / 200 )
    local s="${BATCH_SIZE:-300}"
    local anchor_mb=4800
    local num=7  # 1.4 = 7/5
    local den=5
    local denom=$((den * 200))
    local mem_mb=$(( (anchor_mb * s * num + denom - 1) / denom ))
    BP_REQUEST_MEMORY="${mem_mb}MB"
  fi
}

tpl() {
  # substitute "{CH}" placeholder
  local template="$1"
  local ch="$2"
  echo "${template//\{CH\}/$ch}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

data_root_norm() {
  # Trim trailing slash for reliable prefix checks.
  echo "${DATA_ROOT%/}"
}

hdf5_root_norm() {
  echo "${HDF5_ROOT%/}"
}

rel_under_data() {
  # Convert an absolute host path under $DATA_ROOT into a path relative to it.
  # This is handy for binding $DATA_ROOT read-only into the container.
  local p="$1"
  local root
  root="$(data_root_norm)"
  case "$p" in
    "$root"/*) printf '%s\n' "${p#"$root"/}" ;;
    *) die "Path is not under DATA_ROOT ($root): $p" ;;
  esac
}

rel_under_hdf5() {
  # Convert an absolute host path under $HDF5_ROOT into a path relative to it.
  local p="$1"
  local root
  root="$(hdf5_root_norm)"
  case "$p" in
    "$root"/*) printf '%s\n' "${p#"$root"/}" ;;
    *) die "Path is not under HDF5_ROOT ($root): $p" ;;
  esac
}

parse_ch_range() {
  # Parse CH_RANGE like "1-22" into two numbers on stdout: "<start> <end>".
  local r="$1"
  [[ "$r" =~ ^[0-9]+-[0-9]+$ ]] || die "Invalid chromosome range (expected N-M): $r"
  local a="${r%-*}" b="${r#*-}"
  (( a >= 1 && b >= a && b <= 22 )) || die "Chromosome range out of bounds (1-22): $r"
  echo "$a $b"
}

h5_path_for_ch() {
  # Resolve the expected host-side HDF5 path for a chromosome.
  # If HDF5_TEMPLATE is set (contains {CH}), it is used.
  # Otherwise, the path is assembled as:
  #   $HDF5_ROOT/${HDF5_PREFIX}${HDF5_CH_LABEL}${CH}${HDF5_SUFFIX}${HDF5_EXT}
  local ch="$1"
  if [[ -n "${HDF5_TEMPLATE:-}" ]]; then
    tpl "$HDF5_TEMPLATE" "$ch"
  else
    echo "${HDF5_ROOT%/}/${HDF5_PREFIX}${HDF5_CH_LABEL}${ch}${HDF5_SUFFIX}${HDF5_EXT}"
  fi
}

vcf_1240k_path_for_ch() {
  # Resolve the expected host-side filtered VCF path for a chromosome.
  # If VCF_1240K_TEMPLATE is set (contains {CH}), it is used.
  # Otherwise, the path is assembled similarly to HDF5s:
  #   $HDF5_ROOT/${HDF5_PREFIX}${HDF5_CH_LABEL}${CH}${HDF5_SUFFIX}${VCF_1240K_SUFFIX}
  local ch="$1"
  if [[ -n "${VCF_1240K_TEMPLATE:-}" ]]; then
    tpl "$VCF_1240K_TEMPLATE" "$ch"
  else
    echo "${HDF5_ROOT%/}/${HDF5_PREFIX}${HDF5_CH_LABEL}${ch}${HDF5_SUFFIX}${VCF_1240K_SUFFIX}"
  fi
}
