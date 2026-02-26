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
