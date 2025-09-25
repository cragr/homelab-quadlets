#!/usr/bin/env bash
set -euo pipefail

DEFAULT_INSTALL_DIR="/opt/containers"
DEFAULT_MANIFEST_URL="https://raw.githubusercontent.com/cragr/homelab-quadlets/refs/heads/main/container-manifest.txt"

BOLD="$(tput bold 2>/dev/null || true)"
RESET="$(tput sgr0 2>/dev/null || true)"

die() { echo "Error: $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root (e.g., sudo $0)"; }
check_systemd() { command -v systemctl >/dev/null 2>&1 || die "systemctl not found."; }

usage() {
  cat <<EOF
${BOLD}Quadlet Installer${RESET}

Usage:
  $0 [--manifest <URL_or_path>] [--install-dir <path>] [--non-interactive] [--select "<pat1,pat2,...>"] [--var KEY=VALUE ...]

Options:
  --manifest        URL (raw) or local path to a manifest listing .container/.pod sources.
                    Entries may be separated by newlines OR spaces.
                    Optional label per entry using a pipe: URL|install-name.container
  --install-dir     Path injected into templates (default: ${DEFAULT_INSTALL_DIR}).
  --non-interactive Run without prompts. Requires --select and any needed --var KEY=VALUE.
  --select          Comma-separated numbers/ranges/filenames (or "all") to install.
  --var KEY=VALUE   Provide template variable(s) (repeatable). Examples:
                      --var PWP__OVERRIDE_BASE_URL=https://pwpush.example.com
                      --var GATEWAY_HOST_PORT=8080
                      --var APP_HOST_PORT=5100
EOF
}

MANIFEST=""
INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
NON_INTERACTIVE=0
SELECT_SPEC=""
VARS=()  # KEY=VALUE pairs for token injection

# --------- CLI parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --select) SELECT_SPEC="${2:-}"; shift 2 ;;
    --var)
      [[ -n "${2:-}" ]] || die "--var requires KEY=VALUE"
      VARS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_root
check_systemd

# Default manifest if not provided
if [[ -z "$MANIFEST" ]]; then
  MANIFEST="$DEFAULT_MANIFEST_URL"
  echo "No --manifest provided; using default: $MANIFEST"
fi

# Pick/install dir
if [[ $NON_INTERACTIVE -eq 0 ]]; then
  read -rp "Install/data path [${INSTALL_DIR}]: " ans
  [[ -n "${ans}" ]] && INSTALL_DIR="${ans}"
fi
mkdir -p "$INSTALL_DIR"; chmod 755 "$INSTALL_DIR"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ----- Gather sources -----
# Parallel arrays:
#   SRC_DESC[i]    - human-friendly description (basename/label + origin)
#   SRC_PATH[i]    - local temp path (download or local)
#   SRC_INSTALL[i] - basename to install under /etc/containers/systemd
SRC_DESC=()
SRC_PATH=()
SRC_INSTALL=()

trim_crlf() { printf '%s' "$1" | tr -d '\r' | xargs; }

if [[ -n "$MANIFEST" ]]; then
  echo "Using manifest: $MANIFEST"
  MF="${WORKDIR}/manifest.txt"
  if [[ "$MANIFEST" =~ ^https?:// ]]; then
    command -v curl >/dev/null 2>&1 || die "curl required for remote manifest."
    curl -fsSL "$MANIFEST" -o "$MF" || die "Failed to download manifest."
  else
    [[ -f "$MANIFEST" ]] || die "Manifest not found: $MANIFEST"
    awk '{ sub(/\r$/,""); print }' "$MANIFEST" > "$MF"
  fi

  # Accept space OR newline separated entries; allow optional "|label"
  idx=0
  while IFS= read -r raw; do
    line="$(trim_crlf "${raw%%#*}")"
    [[ -z "$line" ]] && continue
    for token in $line; do
      entry="$token"
      url="${entry}"; label=""
      if [[ "$entry" == *"|"* ]]; then
        url="${entry%%|*}"
        label="$(trim_crlf "${entry#*|}")"
      fi
      [[ -z "$url" ]] && continue

      if [[ "$url" =~ ^https?:// ]]; then
        base="$(basename "$(trim_crlf "$url")")"
        [[ -z "$label" ]] && label="$base"
        [[ "$label" != *.container && "$label" != *.pod ]] && label="${label}.container"
        idx=$((idx+1))
        dest="${WORKDIR}/$(printf '%02d' "$idx")_${base}"
        echo "Fetching ${base} ..."
        curl -fsSL "$url" -o "$dest" || die "Failed to download $url"
        SRC_PATH+=("$dest"); SRC_INSTALL+=("$label"); SRC_DESC+=("${label}  (from URL: ${base})")
      else
        [[ -f "$url" || -f "./$url" ]] || { echo "Warning: missing local file in manifest: $url"; continue; }
        full="$(readlink -f "${url#./}")"
        base="$(basename "$full")"
        [[ -z "$label" ]] && label="$base"
        [[ "$label" != *.container && "$label" != *.pod ]] && label="${label}.container"
        SRC_PATH+=("$full"); SRC_INSTALL+=("$label"); SRC_DESC+=("${label}  (from local: ${base})")
      fi
    done
  done < "$MF"

else
  # Discover local .container/.pod files
  mapfile -t localfiles < <(find . -maxdepth 1 -type f \( -name "*.container" -o -name "*.pod" \) -printf "%f\n" | sort)
  [[ ${#localfiles[@]} -gt 0 ]] || die "No .container/.pod files found in current directory. Use --manifest to pull from GitHub."
  for f in "${localfiles[@]}"; do
    full="$(readlink -f "$f")"
    base="$(basename "$full")"
    SRC_PATH+=("$full"); SRC_INSTALL+=("$base"); SRC_DESC+=("${base}  (local)")
  done
fi

[[ ${#SRC_PATH[@]} -gt 0 ]] || die "No valid entries found (check manifest formatting)."

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
      for ((i=0;i<${#SRC_INSTALL[@]};i++)); do
        if [[ "${SRC_INSTALL[$i]}" == "$part" ]]; then picked+=("$i"); fi
      done
    fi
  done
  [[ ${#picked[@]} -gt 0 ]] || die "Selection matched nothing."
  # unique
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

# ----- Host dir creation (heuristic) -----
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

# ----- Token discovery & prompting -----
extract_tokens() { grep -Eoh '{{[A-Z0-9_]+}}' "$@" 2>/dev/null | sed -E 's/[{}]//g' | sort -u; }

declare -A TOKVAL
seed_vars_from_cli() {
  for kv in "${VARS[@]}"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    [[ -z "$key" || "$key" == "$val" ]] && die "Bad --var format (KEY=VALUE): $kv"
    TOKVAL["$key"]="$val"
  done
}

prompt_for_missing_tokens() {
  local tokens=("$@")
  [[ ${#tokens[@]} -eq 0 ]] && return

  for t in "${tokens[@]}"; do
    [[ -n "${TOKVAL[$t]:-}" ]] && continue
    if [[ $NON_INTERACTIVE -eq 1 ]]; then
      die "Missing value for {{$t}} while --non-interactive. Provide --var $t=VALUE"
    fi
    # sensible defaults for common tokens
    default=""
    case "$t" in
      PWP__OVERRIDE_BASE_URL) default="https://pwpush.example.com" ;;
      GATEWAY_HOST_PORT)      default="8080" ;;
      APP_HOST_PORT)          default="5100" ;;
      HOST_PORT)              default="8080" ;;
    esac
    if [[ -n "$default" ]]; then
      read -rp "Value for {{$t}} [${default}]: " ans
      TOKVAL["$t"]="${ans:-$default}"
    else
      read -rp "Value for {{$t}}: " ans
      [[ -z "$ans" ]] && die "No value entered for {{$t}}"
      TOKVAL["$t"]="$ans"
    fi
  done
}

echo
echo "Injecting variables, ensuring host paths exist, and installing to ${TARGET_DIR} ..."

# 1) Copy selected files to tmp so we can scan tokens first
TMP_FILES_FOR_TOKEN_SCAN=()
DEST_BASENAMES=()
for idx in "${SELECTED_IDX[@]}"; do
  src="${SRC_PATH[$idx]}"
  install_bn="${SRC_INSTALL[$idx]}"
  tmp="${WORKDIR}/${install_bn}.tmp"
  cp "$src" "$tmp"
  TMP_FILES_FOR_TOKEN_SCAN+=("$tmp")
  DEST_BASENAMES+=("$install_bn")
done

# 2) Gather tokens and prompt/seed values
seed_vars_from_cli
mapfile -t FOUND_TOKENS < <(extract_tokens "${TMP_FILES_FOR_TOKEN_SCAN[@]}")
prompt_for_missing_tokens "${FOUND_TOKENS[@]}"

# 3) Replace tokens, mkdirs, install
TMP_UNITS=()
for i in "${!TMP_FILES_FOR_TOKEN_SCAN[@]}"; do
  tmp="${TMP_FILES_FOR_TOKEN_SCAN[$i]}"
  install_bn="${DEST_BASENAMES[$i]}"

  # Replace INSTALL_DIR first
  sed -i -e "s#{{INSTALL_DIR}}#${INSTALL_DIR//\//\\/}#g" -e "s#%%INSTALL_DIR%%#${INSTALL_DIR//\//\\/}#g" "$tmp"

  # Replace any arbitrary {{TOKEN}}
  for key in "${!TOKVAL[@]}"; do
    val="${TOKVAL[$key]}"
    esc_val="${val//\//\\/}"
    sed -i -e "s#{{$key}}#${esc_val}#g" "$tmp"
  done

  # Create host dirs from processed file
  create_host_dirs_from_unit "$tmp"

  dest="${TARGET_DIR}/${install_bn}"
  if [[ -f "$dest" ]]; then
    echo "  Backing up existing ${install_bn} -> ${BACKUP_DIR}/${install_bn}"
    mv -f "$dest" "${BACKUP_DIR}/${install_bn}"
  fi
  install -m 0644 "$tmp" "$dest"
  TMP_UNITS+=("$dest")
done

echo
echo "Reloading systemd daemon ..."
systemctl daemon-reload

echo
echo "Starting, then enabling services ..."
STARTED=()
for bn in "${DEST_BASENAMES[@]}"; do
  # Correct systemd unit names:
  #  - *.container -> <name>.service
  #  - *.pod       -> <name>-pod.service
  if [[ "$bn" == *.pod ]]; then
    svc="${bn%.pod}-pod.service"
  else
    svc="${bn%.container}.service"
  fi

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
echo "If you edit any units, run:  systemctl daemon-reload && systemctl restart <service>"
echo "Backups of replaced units (if any): ${BACKUP_DIR}"
