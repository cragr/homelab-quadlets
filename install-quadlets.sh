#!/usr/bin/env bash
set -euo pipefail

# Default install dir used to replace {{INSTALL_DIR}} or %%INSTALL_DIR%%
DEFAULT_INSTALL_DIR="/opt/containers"

# Colors (optional nicety)
BOLD="$(tput bold 2>/dev/null || true)"
RESET="$(tput sgr0 2>/dev/null || true)"

die() { echo "Error: $*" >&2; exit 1; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Please run as root (e.g., sudo $0 ...)"
  fi
}

check_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found. This script targets systemd hosts."
}

usage() {
  cat <<EOF
${BOLD}Quadlet Installer${RESET}

Usage:
  $0 [--manifest <URL_or_path>] [--install-dir <path>] [--non-interactive] [--select "<pat1,pat2,...>"]

Options:
  --manifest        URL (raw text) or local path to a manifest file listing .container sources.
                    Each line should be either a local file path or a raw URL to a .container file.
                    If omitted, the script uses all *.container files in the current directory.
  --install-dir     Path to inject into templates (defaults to ${DEFAULT_INSTALL_DIR}).
  --non-interactive Skips interactive prompts. Requires --select and (optionally) --install-dir.
  --select          Comma-separated globs or filenames to install (evaluated against discovered list).
                    Examples: "all"  or  "nginx.container,postgres*.container"

Manifest tip (GitHub):
  Put a text file in your repo (e.g., container-manifest.txt) with one raw URL per line:
    https://raw.githubusercontent.com/you/repo/main/quadlets/web.container
    https://raw.githubusercontent.com/you/repo/main/quadlets/db.container
EOF
}

# Parse args
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

# Ensure install dir exists or prompt/create
if [[ $NON_INTERACTIVE -eq 0 ]]; then
  read -rp "Install/data path [${INSTALL_DIR}]: " ans
  [[ -n "${ans}" ]] && INSTALL_DIR="${ans}"
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "Creating ${INSTALL_DIR} ..."
  mkdir -p "$INSTALL_DIR"
  chmod 755 "$INSTALL_DIR"
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

CONTAINER_SOURCES=()

# Load sources either from manifest or current directory
if [[ -n "$MANIFEST" ]]; then
  echo "Using manifest: $MANIFEST"
  if [[ "$MANIFEST" =~ ^https?:// ]]; then
    command -v curl >/dev/null 2>&1 || die "curl required for remote manifest mode."
    curl -fsSL "$MANIFEST" -o "${WORKDIR}/manifest.txt" || die "Failed to download manifest."
  else
    [[ -f "$MANIFEST" ]] || die "Manifest path not found: $MANIFEST"
    cp "$MANIFEST" "${WORKDIR}/manifest.txt"
  fi

  # Read non-empty, non-comment lines
  while IFS= read -r line; do
    line="${line%%#*}"           # strip comments
    line="$(echo "$line" | xargs)" # trim
    [[ -z "$line" ]] && continue
    CONTAINER_SOURCES+=("$line")
  done < "${WORKDIR}/manifest.txt"

  [[ ${#CONTAINER_SOURCES[@]} -gt 0 ]] || die "Manifest contains no .container sources."

else
  # Discover local .container files
  mapfile -t CONTAINER_SOURCES < <(find . -maxdepth 1 -type f -name "*.container" -printf "%f\n" | sort)
  [[ ${#CONTAINER_SOURCES[@]} -gt 0 ]] || die "No .container files found in current directory. Use --manifest to pull from GitHub."
fi

# Resolve / download all sources to WORKDIR, building a list of candidate files
CANDIDATES=()
for src in "${CONTAINER_SOURCES[@]}"; do
  if [[ "$src" =~ ^https?:// ]]; then
    base="$(basename "$src")"
    dest="${WORKDIR}/${base}"
    echo "Fetching ${base} ..."
    curl -fsSL "$src" -o "$dest" || die "Failed to download $src"
    CANDIDATES+=("$dest")
  else
    # local path (relative or absolute)
    if [[ -f "$src" ]]; then
      CANDIDATES+=("$(readlink -f "$src")")
    elif [[ -f "./$src" ]]; then
      CANDIDATES+=("$(readlink -f "./$src")")
    else
      echo "Warning: skipping missing local file: $src" >&2
    fi
  fi
done

[[ ${#CANDIDATES[@]} -gt 0 ]] || die "No valid .container files resolved."

# Present selection
echo
echo "${BOLD}Discovered Quadlet files:${RESET}"
i=1
for f in "${CANDIDATES[@]}"; do
  echo "  [$i] $(basename "$f")"
  ((i++))
done

SELECTED=()

choose_files() {
  local input=""
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    input="$SELECT_SPEC"
  else
    echo
    read -rp "Select items by number/comma, ranges (e.g. 1,3-4), globs, or 'all': " input
  fi
  [[ -z "$input" ]] && die "Nothing selected."

  if [[ "$input" == "all" ]]; then
    SELECTED=("${CANDIDATES[@]}")
    return
  fi

  # Build a list from patterns
  local picked=()
  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    part="$(echo "$part" | xargs)"
    [[ -z "$part" ]] && continue

    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      # range
      local start="${part%-*}"
      local end="${part#*-}"
      for ((n=start; n<=end; n++)); do
        idx=$((n-1))
        [[ $idx -ge 0 && $idx -lt ${#CANDIDATES[@]} ]] && picked+=("${CANDIDATES[$idx]}")
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      # single index
      idx=$((part-1))
      [[ $idx -ge 0 && $idx -lt ${#CANDIDATES[@]} ]] && picked+=("${CANDIDATES[$idx]}")
    else
      # treat as glob against basenames
      for f in "${CANDIDATES[@]}"; do
        bn="$(basename "$f")"
        if [[ "$bn" == $part ]]; then
          picked+=("$f")
        fi
      done
    fi
  done

  # unique-ify
  local uniq=()
  local seen=""
  for f in "${picked[@]}"; do
    [[ ":$seen:" == *":$f:"* ]] && continue
    uniq+=("$f")
    seen="${seen}:$f"
  done
  [[ ${#uniq[@]} -gt 0 ]] || die "Selection matched nothing."
  SELECTED=("${uniq[@]}")
}

choose_files

TARGET_DIR="/etc/containers/systemd"
[[ -d "$TARGET_DIR" ]] || mkdir -p "$TARGET_DIR"

# Backup any existing same-named files
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${TARGET_DIR}.bak-${STAMP}"
mkdir -p "$BACKUP_DIR"

echo
echo "Injecting install dir and installing to ${TARGET_DIR} ..."
for src in "${SELECTED[@]}"; do
  bn="$(basename "$src")"
  tmp="${WORKDIR}/${bn}.tmp"
  cp "$src" "$tmp"

  # Replace tokens if present
  sed -i \
    -e "s#{{INSTALL_DIR}}#${INSTALL_DIR//\//\\/}#g" \
    -e "s#%%INSTALL_DIR%%#${INSTALL_DIR//\//\\/}#g" \
    "$tmp"

  dest="${TARGET_DIR}/${bn}"

  if [[ -f "$dest" ]]; then
    echo "  Backing up existing ${bn} -> ${BACKUP_DIR}/${bn}"
    mv -f "$dest" "${BACKUP_DIR}/${bn}"
  fi

  install -m 0644 "$tmp" "$dest"
done

echo
echo "Reloading systemd daemon ..."
systemctl daemon-reload

# Enable & start services
echo
echo "Enabling & starting services ..."
ENABLED_STARTED=()
for src in "${SELECTED[@]}"; do
  svc="$(basename "${src%.container}").service"
  systemctl enable --now "$svc" || die "Failed to enable/start $svc"
  ENABLED_STARTED+=("$svc")
done

echo
echo "${BOLD}Done!${RESET}"
echo "Services enabled & started:"
for s in "${ENABLED_STARTED[@]}"; do
  echo "  - $s"
done

echo
echo "Manage with:"
for s in "${ENABLED_STARTED[@]}"; do
  echo "  systemctl status $s"
done
echo
echo "If you edit any .container units, run:  systemctl daemon-reload && systemctl restart <service>"
echo "Backups of replaced units (if any) are in: ${BACKUP_DIR}"