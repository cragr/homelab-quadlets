#!/usr/bin/env bash
set -euo pipefail

DEFAULT_INSTALL_DIR="/opt/containers"
BOLD="$(tput bold 2>/dev/null || true)"
RESET="$(tput sgr0 2>/dev/null || true)"

die() { echo "Error: $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root (e.g., sudo $0)"; }
check_systemd() { command -v systemctl >/dev/null 2>&1 || die "systemctl not found."; }

usage() {
  cat <<EOF
${BOLD}Quadlet Installer${RESET}

Usage:
  $0 [--manifest <URL_or_path>] [--install-dir <path>] [--non-interactive] [--select "<pat1,pat2,...>"]

Options:
  --manifest        URL (raw) or local path to a manifest listing .container sources (one per line).
                    Optional label per line using a pipe: URL|install-name.container
  --install-dir     Path injected into templates (default: ${DEFAULT_INSTALL_DIR}).
  --non-interactive Run without prompts. Requires --select (and optionally --install-dir).
  --select          Comma-separated numbers/ranges/filenames (or "all") to install.
EOF
}

MANIFEST=""
INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
NON_INTERACTIVE=0
SELECT_SPEC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --select) SELECT_SPEC="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_root
check_systemd

if [[ $NON_INTERACTIVE -eq 0 ]]; then
  read -rp "Install/data path [${INSTALL_DIR}]: " ans
  [[ -n "${ans}" ]] && INSTALL_DIR="${ans}"
fi
mkdir -p "$INSTALL_DIR"; chmod 755 "$INSTALL_DIR"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ----- Gather sources -----
# We'll build parallel arrays:
#   SRC_DESC[i]   - human-friendly description (basename or label + origin hint)
#   SRC_PATH[i]   - resolved local file path (download or local)
#   SRC_INSTALL[i]- destination basename for /etc/containers/systemd (e.g., heimdall.container)
SRC_DESC=()
SRC_PATH=()
SRC_INSTALL=()

# Helper: trim spaces and strip CRLF
trim_crlf() { printf '%s' "$1" | tr -d '\r' | xargs; }

if [[ -n "$MANIFEST" ]]; then
  echo "Using manifest: $MANIFEST"
  MF="${WORKDIR}/manifest.txt"
  if [[ "$MANIFEST" =~ ^https?:// ]]; then
    command -v curl >/dev/null 2>&1 || die "curl required for remote manifest."
    curl -fsSL "$MANIFEST" -o "$MF" || die "Failed to download manifest."
  else
    [[ -f "$MANIFEST" ]] || die "Manifest not found: $MANIFEST"
    # Normalize CRLF to LF
    awk '{ sub(/\r$/,""); print }' "$MANIFEST" > "$MF"
  fi

  idx=0
  while IFS= read -r raw; do
    line="$(trim_crlf "${raw%%#*}")"
    [[ -z "$line" ]] && continue

    url="${line}"
    label=""
    if [[ "$line" == *"|"* ]]; then
      url="${line%%|*}"
      label="$(trim_crlf "${line#*|}")"
    fi
    [[ -z "$url" ]] && continue

    if [[ "$url" =~ ^https?:// ]]; then
      base="$(basename "$(trim_crlf "$url")")"
      [[ -z "$label" ]] && label="$base"
      # Ensure label ends with .container
      [[ "$label" != *.container ]] && label="${label}.container"

      idx=$((idx+1))
      dest="${WORKDIR}/$(printf '%02d' "$idx")_${base}"
      echo "Fetching ${base} ..."
      curl -fsSL "$url" -o "$dest" || die "Failed to download $url"

      SRC_PATH+=("$dest")
      SRC_INSTALL+=("$label")
      SRC_DESC+=("${label}  (from URL: ${base})")
    else
      # Local path in manifest
      [[ -f "$url" || -f "./$url" ]] || { echo "Warning: missing local file in manifest: $url"; continue; }
      full="$(readlink -f "${url#./}")"
      base="$(basename "$full")"
      [[ -z "$label" ]] && label="$base"
      [[ "$label" != *.container ]] && label="${label}.container"

      SRC_PATH+=("$full")
      SRC_INSTALL+=("$label")
      SRC_DESC+=("${label}  (from local: ${base})")
    fi
  done < "$MF"
else
  # Discover local .container files in current dir
  mapfile -t localfiles < <(find . -maxdepth 1 -type f -name "*.container" -printf "%f\n" | sort)
  [[ ${#localfiles[@]} -gt 0 ]] || die "No .container files found in current directory. Use --manifest to pull from GitHub."
  for f in "${localfiles[@]}"; do
    full="$(readlink -f "$f")"
    base="$(basename "$full")"
    SRC_PATH+=("$full")
    SRC_INSTALL+=("$base")
    SRC_DESC+=("${base}  (local)")
  done
fi

[[ ${#SRC_PATH[@]} -gt 0 ]] || die "No valid .container entries found (check manifest formatting)."

# ----- Selection -----
echo
echo "${BOLD}Discovered Quadlet entries:${RESET}"
for ((i=0; i<${#SRC_PATH[@]}; i++)); do
  printf "  [%d] %s\n" "$((i+1))" "${SRC_DESC[$i]}"
done

SELECTED_IDX=()

choose_files() {
  local input=""
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    input="$SELECT_SPEC"
  else
    echo
    read -rp "Select by number/comma, ranges (e.g. 1,3-4), filenames, or 'all': " input
  fi
  [[ -z "$input" ]] && die "Nothing selected."

  if [[ "$input" == "all" ]]; then
    for ((i=0;i<${#SRC_PATH[@]};i++)); do SELECTED_IDX+=("$i"); done
    return
  fi

  local picked=()
  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    part="$(echo "$part" | xargs)"; [[ -z "$part" ]] && continue
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      local start="${part%-*}" end="${part#*-}"
      for ((n=start;n<=end;n++)); do idx=$((n-1)); [[ $idx -ge 0 && $idx -lt ${#SRC_PATH[@]} ]] && picked+=("$idx"); done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      idx=$((part-1)); [[ $idx -ge 0 && $idx -lt ${#SRC_PATH[@]} ]] && picked+=("$idx")
    else
      # filename match against install names
      for ((i=0;i<${#SRC_INSTALL[@]};i++)); do
        if [[ "${SRC_INSTALL[$i]}" == "$part" ]]; then picked+=("$i"); fi
      done
    fi
  done
  [[ ${#picked[@]} -gt 0 ]] || die "Selection matched nothing."
  # unique indices
  local seen=""; local uniq=()
  for idx in "${picked[@]}"; do [[ ":$seen:" == *":$idx:"* ]] && continue; uniq+=("$idx"); seen="${seen}:$idx"; done
  SELECTED_IDX=("${uniq[@]}")
}
choose_files

TARGET_DIR="/etc/containers/systemd"
mkdir -p "$TARGET_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${TARGET_DIR}.bak-${STAMP}"
mkdir -p "$BACKUP_DIR"

# Create host dirs heuristic
create_host_dirs_from_unit() {
  local unit_file="$1"
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    local val="${line#*=}"
    for item in $val; do
      local host="${item%%:*}"
      [[ "$host" != /* ]] && continue
      host="${host/#\~/$HOME}"
      [[ -e "$host" ]] && continue
      local base="$(basename -- "$host")"
      if [[ "$base" == *.* ]]; then
        mkdir -p -- "$(dirname -- "$host")"
      else
        mkdir -p -- "$host"
      fi
    done
  done < <(grep -E '^\s*(Volume|Bind(ReadOnly)?)=' "$unit_file" || true)
}

echo
echo "Injecting install dir, ensuring host paths exist, and installing to ${TARGET_DIR} ..."
TMP_UNITS=()
DEST_BASENAMES=()
for idx in "${SELECTED_IDX[@]}"; do
  src="${SRC_PATH[$idx]}"
  install_bn="${SRC_INSTALL[$idx]}"
  tmp="${WORKDIR}/${install_bn}.tmp"
  cp "$src" "$tmp"

  # Replace tokens
  sed -i \
    -e "s#{{INSTALL_DIR}}#${INSTALL_DIR//\//\\/}#g" \
    -e "s#%%INSTALL_DIR%%#${INSTALL_DIR//\//\\/}#g" \
    "$tmp"

  # Ensure host paths exist
  create_host_dirs_from_unit "$tmp"

  dest="${TARGET_DIR}/${install_bn}"
  if [[ -f "$dest" ]]; then
    echo "  Backing up existing ${install_bn} -> ${BACKUP_DIR}/${install_bn}"
    mv -f "$dest" "${BACKUP_DIR}/${install_bn}"
  fi
  install -m 0644 "$tmp" "$dest"
  TMP_UNITS+=("$dest")
  DEST_BASENAMES+=("$install_bn")
done

echo
echo "Reloading systemd daemon ..."
systemctl daemon-reload

echo
echo "Starting, then enabling services ..."
STARTED=()
for bn in "${DEST_BASENAMES[@]}"; do
  svc="${bn%.container}.service"

  if systemctl start "$svc"; then
    STARTED+=("$svc")
  else
    echo "Warning: failed to start $svc (check logs: journalctl -u $svc). Continuing..."
  fi

  state="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
  case "$state" in
    enabled|static|indirect|generated|enabled-runtime)
      echo "Info: $svc already enabled/state=$state; skipping enable."
      ;;
    *)
      errfile="$(mktemp)"; trap 'rm -f "$errfile"' EXIT
      if ! systemctl enable "$svc" 2>"$errfile"; then
        if grep -qi 'transient or generated' "$errfile"; then
          echo "Info: $svc is a generated unit; enable not applicable. Continuing."
        else
          echo "Warning: failed to enable $svc:"; sed 's/^/  /' "$errfile"
        fi
      fi
      rm -f "$errfile"; trap - EXIT
      ;;
  esac
done

echo
echo "${BOLD}Done!${RESET}"
echo "Services started (attempted) and enabled/skipped as appropriate:"
for s in "${STARTED[@]}"; do echo "  - $s"; done

echo
echo "Manage with:"
for s in "${STARTED[@]}"; do echo "  systemctl status $s"; done
echo
echo "If you edit any .container units, run:  systemctl daemon-reload && systemctl restart <service>"
echo "Backups of replaced units (if any): ${BACKUP_DIR}"
