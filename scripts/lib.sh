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
  [[ -n "${RUNS_ROOT:-}" ]] || die "RUNS_ROOT not set in config/local.env"
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

parse_ch_range() {
  # Parse CH_RANGE like "1-22" into two numbers on stdout: "<start> <end>".
  local r="$1"
  [[ "$r" =~ ^[0-9]+-[0-9]+$ ]] || die "Invalid chromosome range (expected N-M): $r"
  local a="${r%-*}" b="${r#*-}"
  (( a >= 1 && b >= a && b <= 22 )) || die "Chromosome range out of bounds (1-22): $r"
  echo "$a $b"
}
