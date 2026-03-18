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
