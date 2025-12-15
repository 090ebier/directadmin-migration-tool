#!/usr/bin/env bash
# DirectAdmin Backup -> Transfer -> Restore (multi-user) + Post-restore rsync
# Enhanced UI version with improved colors, icons, and visual feedback
set -euo pipefail
IFS=$' \t\n'

# =========================
# Configuration
# =========================
DA_ADMIN_USER="admin"
DA_BIN="/usr/local/directadmin/directadmin"
TASK_QUEUE="/usr/local/directadmin/data/task.queue"
SSH_CONFIG_FILE="/root/.ssh/config"
SSH_PORT_DEFAULT="3031"
DEST_PATH_DEFAULT="/home/backups"
BACKUP_DIR="/home/admin/admin_backups/backup_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/da_backup_restore_$(date +%Y%m%d_%H%M%S).log"

DA_BACKUP_OPTIONS=(
  "autoresponder" "database" "database_data" "email" "emailsettings"
  "forwarder" "ftp" "ftpsettings" "list" "subdomain" "vacation"
)

RSYNC_OPTS="-a -h --stats --no-owner --no-group --omit-dir-times --delete-delay --info=progress2 --partial --append-verify"
SSH_CONNECT_TIMEOUT="8"
SSH_CONNECTION_ATTEMPTS="2"

# =========================
# Logging
# =========================
touch "$LOG_FILE" || { echo "Error: Cannot create log file $LOG_FILE"; exit 1; }
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >/dev/null; }

# =========================
# Enhanced UI Setup
# =========================
safe_tput() {
  command -v tput >/dev/null 2>&1 || return 0
  tput "$@" 2>/dev/null || true
}

# Color definitions
RST=""; BLD=""; DIM=""
RED=""; GRN=""; YLW=""; BLU=""; MAG=""; CYA=""; WHT=""

if [ -t 1 ] && [ -n "${TERM:-}" ]; then
  RST="$(safe_tput sgr0)"
  BLD="$(safe_tput bold)"
  DIM="$(safe_tput dim)"
  RED="$(safe_tput setaf 1)"
  GRN="$(safe_tput setaf 2)"
  YLW="$(safe_tput setaf 3)"
  BLU="$(safe_tput setaf 4)"
  MAG="$(safe_tput setaf 5)"
  CYA="$(safe_tput setaf 6)"
  WHT="$(safe_tput setaf 7)"
fi

# Enhanced icons
ICON_OK="✔"
ICON_INFO="ℹ"
ICON_WARN="⚠"
ICON_ERR="✖"
ICON_STEP="➤"
ICON_ARROW="→"
ICON_CLOCK="⏱"
ICON_SERVER="🖥"
ICON_BACKUP="💾"
ICON_SYNC="🔄"
ICON_LOCK="🔒"

# Separator styles
HR="${DIM}═══════════════════════════════════════════════════════════════${RST}"
HR_THIN="${DIM}───────────────────────────────────────────────────────────────${RST}"
HR_THICK="${BLD}${MAG}═══════════════════════════════════════════════════════════════${RST}"

# =========================
# Enhanced UI Functions
# =========================
ok() { 
  log "[OK] $*"
  echo -e "${GRN}${BLD}  ${ICON_OK}  ${RST}${GRN}${BLD}OK${RST}    $*"
}

info() { 
  log "[..] $*"
  echo -e "${CYA}${BLD}  ${ICON_INFO}  ${RST}${CYA}INFO${RST}  $*"
}

warn() { 
  log "[WRN] $*"
  echo -e "${YLW}${BLD}  ${ICON_WARN}  ${RST}${YLW}${BLD}WARN${RST}  $*"
}

err() { 
  log "[ERR] $*"
  echo -e "${RED}${BLD}  ${ICON_ERR}  ${RST}${RED}${BLD}ERROR${RST} $*"
}

die() {
  err "$*"
  unset SSH_PASS 2>/dev/null || true
  exit 1
}

section() {
  echo
  echo -e "${HR_THICK}"
  echo -e "${MAG}${BLD}  ${ICON_STEP}  $*${RST}"
  echo -e "${HR_THICK}"
  echo
  log "----- $* -----"
}

subsection() {
  echo
  echo -e "${HR_THIN}"
  echo -e "${BLU}${BLD}  ${ICON_ARROW}  $*${RST}"
  echo -e "${HR_THIN}"
}

progress() {
  echo -e "${WHT}${DIM}  ${ICON_CLOCK}  $*${RST}"
}

# =========================
# TTY Handling
# =========================
require_tty() {
  if ! [ -r /dev/tty ]; then
    err "This script requires an interactive TTY (/dev/tty not readable)."
    err "Run it in a real SSH session or use: script -c \"bash $0\""
    exit 1
  fi
}

# =========================
# Helper Functions
# =========================
check_command() { 
  command -v "$1" &>/dev/null || die "$1 is not installed."
}

url_encode_path() { 
  echo "$1" | sed 's/\//%2F/g'
}

url_encode_dots() { 
  echo "$1" | sed 's/\./%2E/g'
}

is_valid_ip() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  read -r -a octets <<< "$ip"
  for o in "${octets[@]}"; do 
    [[ $o -ge 0 && $o -le 255 ]] || return 1
  done
  return 0
}

prompt() {
  local q="$1" d="${2:-}" reply=""
  local prompt_text=""
  
  if [ -n "$d" ]; then
    prompt_text="${BLU}${BLD}  ?  ${RST}${q} ${DIM}[default: ${BLD}${d}${RST}${DIM}]${RST}
${BLD}     → ${RST}"
  else
    prompt_text="${BLU}${BLD}  ?  ${RST}${q}
${BLD}     → ${RST}"
  fi
  
  read -r -e -p "$(printf "%b" "$prompt_text")" reply </dev/tty || die "Input aborted (EOF)"
  echo "${reply:-$d}"
}

prompt_secret() {
  local q="$1" reply=""
  local prompt_text="${BLU}${BLD}  ${ICON_LOCK}  ${RST}${q}
${BLD}     → ${RST}"
  
  read -r -s -p "$(printf "%b" "$prompt_text")" reply </dev/tty || die "Input aborted (EOF)"
  echo >/dev/tty
  echo "$reply"
}

get_user_domain() {
  local user="$1" domain=""
  if [ -f "/usr/local/directadmin/data/users/$user/user.conf" ]; then
    domain="$(grep -m1 '^domain=' "/usr/local/directadmin/data/users/$user/user.conf" 2>/dev/null | cut -d'=' -f2 || true)"
  fi
  if [ -z "$domain" ] && [ -f "/usr/local/directadmin/data/users/$user/domains.list" ]; then
    domain="$(head -n1 "/usr/local/directadmin/data/users/$user/domains.list" 2>/dev/null || true)"
  fi
  [ -z "$domain" ] && domain="(no domain)"
  echo "$domain"
}

get_reseller_users() {
  local reseller="$1"
  local users_list=""
  local f="/usr/local/directadmin/data/users/$reseller/users.list"
  
  if [ -f "$f" ] && [ -r "$f" ]; then
    users_list=$(tr '\n' ' ' < "$f" | tr -s ' ' | xargs)
    [ -n "$users_list" ] && { echo "$users_list"; return 0; }
  fi
  
  local api_output=""
  api_output=$("$DA_BIN" o --api-json CMD_API_SHOW_USERS username="$reseller" 2>/dev/null || true)
  
  if [ -n "$api_output" ] && echo "$api_output" | grep -q '"list"'; then
    if command -v jq &>/dev/null; then
      users_list=$(echo "$api_output" | jq -r '.list[]? // empty' 2>/dev/null | tr '\n' ' ' | xargs || true)
    elif command -v python3 &>/dev/null; then
      users_list=$(echo "$api_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(d.get('list',[])))" 2>/dev/null || true)
    fi
    [ -n "$users_list" ] && { echo "$users_list"; return 0; }
  fi
  
  echo ""
  return 0
}

find_backup_file_for_user() {
  local u="$1"
  find "$BACKUP_DIR" -maxdepth 1 -type f \( \
      -name "*.tar.zst" -o -name "*.tar.gz" -o -name "*.tar.bz2" -o -name "*.tar.xz" \
    \) -printf "%f\n" \
    | grep -E "\.${u}\.tar\.(zst|gz|bz2|xz)$" \
    | head -n1 || true
}

wait_for_backup_file() {
  local u="$1" timeout_sec="${2:-3600}"
  local start now f
  progress "Waiting for backup file for '${BLD}${u}${RST}' ..."
  start=$(date +%s)
  while true; do
    f="$(find_backup_file_for_user "$u")"
    if [ -n "$f" ] && [ -s "$BACKUP_DIR/$f" ]; then
      ok "Backup ready: ${BLD}$f${RST}"
      return 0
    fi
    now=$(date +%s)
    if [ $((now-start)) -ge "$timeout_sec" ]; then
      return 1
    fi
    sleep 2
  done
}

remote_ssh() {
  sshpass -p "$SSH_PASS" ssh -q \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    -o ConnectionAttempts="$SSH_CONNECTION_ATTEMPTS" \
    "${SSH_OPTS[@]}" \
    "$DEST_USER@$DEST_IP" "$@"
}

ssh_warmup() {
  progress "Warming up SSH connection (first contact) ..."
  remote_ssh "echo ok" >/dev/null 2>&1 || die "SSH warm-up failed (check IP/port/user/pass/firewall/sshd)."
  ok "SSH connection warmed up"
}

wait_for_remote_user_home() {
  local u="$1" timeout_sec="${2:-1800}"
  local start now
  progress "Waiting for destination /home/${BLD}$u${RST} to exist ..."
  start=$(date +%s)
  while true; do
    if remote_ssh "test -d '/home/$u'"; then
      ok "Destination /home/${BLD}$u${RST} exists"
      return 0
    fi
    now=$(date +%s)
    if [ $((now-start)) -ge "$timeout_sec" ]; then
      return 1
    fi
    sleep 3
  done
}

rsync_user_subdir() {
  local u="$1" subdir="$2"
  local src="/home/$u/$subdir/"
  local dst="/home/$u/$subdir/"
  
  if [ ! -d "$src" ]; then
    warn "Source missing: ${BLD}$src${RST} (skipped)"
    return 0
  fi
  
  info "Syncing ${BLD}$u/$subdir${RST} (resumable transfer)"
  
  local RSYNC_SSH
  RSYNC_SSH="ssh -q -T -o Compression=no -o IPQoS=throughput -o ServerAliveInterval=30 -o ServerAliveCountMax=3 ${SSH_OPTS_STR}"
  
  sshpass -p "$SSH_PASS" rsync $RSYNC_OPTS -e "$RSYNC_SSH" \
    "$src" "$DEST_USER@$DEST_IP:$dst" \
    || die "Rsync failed for $u/$subdir"
    
  ok "Synced ${BLD}$u/$subdir${RST}"
}

fix_remote_ownership() {
  local u="$1"
  progress "Fixing ownership on destination for ${BLD}$u${RST} ..."
  remote_ssh "
    set -e
    if [ -d '/home/$u/domains' ]; then
      chown -R '$u:$u' '/home/$u/domains'
    fi
    if [ -d '/home/$u/imap' ]; then
      if getent group mail >/dev/null 2>&1; then
        chown -R '$u:mail' '/home/$u/imap'
      else
        chown -R '$u:$u' '/home/$u/imap'
      fi
    fi
  " >/dev/null 2>&1 || die "Failed to fix ownership on destination for $u"
  ok "Ownership fixed for ${BLD}$u${RST}"
}

build_backup_task_line_multi() {
  local opts="" idx=0
  for o in "${DA_BACKUP_OPTIONS[@]}"; do
    opts="${opts}&option${idx}=${o}"
    idx=$((idx+1))
  done
  
  local selects="" sidx=0
  for u in "${SELECTED_USERS[@]}"; do
    selects="${selects}&select${sidx}=${u}"
    sidx=$((sidx+1))
  done
  
  echo "action=backup&append_to_path=nothing&database_data_aware=yes&email_data_aware=yes&local_path=${ENC_BACKUP_DIR}${opts}&owner=${DA_ADMIN_USER}${selects}&trash_aware=yes&type=admin&value=multiple&what=select&when=now&where=local"
}

build_restore_task_line_multi() {
  local selects="" idx=0
  for u in "${SELECTED_USERS[@]}"; do
    local f=""
    f="$(find_backup_file_for_user "$u")"
    [ -n "$f" ] || die "Cannot find backup file for user '$u' in $BACKUP_DIR"
    selects="${selects}&select%3${idx}=$(url_encode_dots "$f")"
    idx=$((idx+1))
  done
  
  echo "action=restore&ip%5Fchoice=select&ip=$DEST_SERVER_IP&local%5Fpath=$ENC_DEST_PATH&owner=$DA_ADMIN_USER${selects}&type=admin&value=multiple&when=now&where=local"
}

# =========================
# Main Script Start
# =========================
clear
echo
echo -e "${MAG}${BLD}╔═══════════════════════════════════════════════════════════════╗${RST}"
echo -e "${MAG}${BLD}║                                                               ║${RST}"
echo -e "${MAG}${BLD}║          ${WHT}DirectAdmin Backup & Restore Wizard${MAG}                  ║${RST}"
echo -e "${MAG}${BLD}║                                                               ║${RST}"
echo -e "${MAG}${BLD}╚═══════════════════════════════════════════════════════════════╝${RST}"
echo
echo -e "${DIM}Log file: ${BLD}$LOG_FILE${RST}"
echo

log "Starting backup/restore wizard"
require_tty

# =========================
# Pre-flight Checks
# =========================
section "Pre-flight System Checks"

progress "Checking required commands..."
check_command rsync
check_command ssh
check_command sshpass
ok "All required commands present"

progress "Verifying DirectAdmin installation..."
[ -x "$DA_BIN" ] || die "DirectAdmin binary not found at $DA_BIN"
ok "DirectAdmin binary verified"

progress "Checking backup directory permissions..."
[ -w "$(dirname "$BACKUP_DIR")" ] || die "Backup base directory is not writable"
ok "Backup directory permissions OK"

# =========================
# Destination Configuration
# =========================
section "Step 1: Destination Server Configuration"

info "Please provide destination server details"
echo

DEST_IP="$(prompt 'Destination server IP (or hostname)' '')"
SSH_PORT="$(prompt 'Destination SSH port' "$SSH_PORT_DEFAULT")"
DEST_USER="$(prompt 'Destination SSH username' 'root')"
DEST_PATH="$(prompt 'Destination backup path' "$DEST_PATH_DEFAULT")"

[ -n "$DEST_IP" ] || die "Destination IP/host is required"
[ -n "$DEST_PATH" ] || die "Destination path is required"

if is_valid_ip "$DEST_IP"; then
  DEST_SERVER_IP="$DEST_IP"
  info "Using ${BLD}${DEST_IP}${RST} as restore IP"
else
  DEST_SERVER_IP="$(prompt 'IP address available on destination for restore' '')"
fi

[ -n "${DEST_SERVER_IP:-}" ] || die "Restore IP is required"

echo
SSH_PASS="$(prompt_secret "SSH password for ${BLD}${DEST_USER}@${DEST_IP}${RST}")"
[ -n "${SSH_PASS:-}" ] || die "SSH password is required"

SSH_OPTS=(
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

[ -f "$SSH_CONFIG_FILE" ] && SSH_OPTS+=( -F "$SSH_CONFIG_FILE" )

SSH_OPTS_STR=""
for x in "${SSH_OPTS[@]}"; do SSH_OPTS_STR+="$x "; done
SSH_OPTS_STR="${SSH_OPTS_STR% }"

echo
subsection "Verifying Destination Server"
echo

progress "Testing SSH connection to ${DEST_USER}@${DEST_IP}:${SSH_PORT}..."
if remote_ssh "exit" >/dev/null 2>&1; then
  ok "SSH connection established"
else
  die "Failed to connect to destination server"
fi

ssh_warmup

progress "Verifying destination path: ${DEST_PATH}..."
remote_ssh "mkdir -p '$DEST_PATH' && [ -w '$DEST_PATH' ]" >/dev/null 2>&1 \
  || die "Destination path $DEST_PATH is not writable or cannot be created"
ok "Destination path verified and writable"

progress "Verifying restore IP: ${DEST_SERVER_IP}..."
remote_ssh "ip addr show | grep -q '$DEST_SERVER_IP'" >/dev/null 2>&1 \
  || die "Restore IP $DEST_SERVER_IP does not exist on destination"
ok "Restore IP verified on destination"

# =========================
# Account Selection
# =========================
section "Step 2: Account Selection"

info "Scanning DirectAdmin accounts and resellers..."

RESELLERS=()
ALL_USERS=()
DISPLAY_LIST=("Select All" "Search")
declare -ag SELECTED_USERS=()

progress "Scanning user directories..."

for u in /usr/local/directadmin/data/users/*; do
  [ ! -d "$u" ] && continue
  u="${u##*/}"
  case "$u" in
    packages|domains|skin_customizations|history|login_keys|php) continue ;;
  esac
  [ -f "/usr/local/directadmin/data/users/$u/reseller.conf" ] && RESELLERS+=("$u")
done

for u in /usr/local/directadmin/data/users/*; do
  [ ! -d "$u" ] && continue
  u="${u##*/}"
  case "$u" in
    packages|domains|skin_customizations|history|login_keys|php) continue ;;
  esac
  [ -f "/usr/local/directadmin/data/users/$u/user.conf" ] && ALL_USERS+=("$u")
done

[ ${#ALL_USERS[@]} -gt 0 ] || die "No DirectAdmin users found"

ok "Found ${BLD}${#ALL_USERS[@]}${RST} users and ${BLD}${#RESELLERS[@]}${RST} resellers"

for reseller in "${RESELLERS[@]}"; do
  DISPLAY_LIST+=("Reseller: $reseller")
  reseller_users="$(get_reseller_users "$reseller")"
  if [ -n "$reseller_users" ]; then
    for user in $reseller_users; do
      if [ -f "/usr/local/directadmin/data/users/$user/user.conf" ]; then
        domain="$(get_user_domain "$user")"
        DISPLAY_LIST+=("$user ($domain)")
      fi
    done
  fi
  if [ -f "/usr/local/directadmin/data/users/$reseller/user.conf" ]; then
    domain="$(get_user_domain "$reseller")"
    DISPLAY_LIST+=("$reseller ($domain)")
  fi
done

for user in "${ALL_USERS[@]}"; do
  if [[ ! " ${RESELLERS[*]} " =~ " ${user} " ]]; then
    already_added=0
    for item in "${DISPLAY_LIST[@]}"; do
      if [[ "$item" =~ ^${user}\ \( ]]; then
        already_added=1
        break
      fi
    done
    if [ $already_added -eq 0 ]; then
      domain="$(get_user_domain "$user")"
      DISPLAY_LIST+=("$user ($domain)")
    fi
  fi
done

echo
echo -e "${BLD}Available accounts (${BLU}${#DISPLAY_LIST[@]}${RST}${BLD} items):${RST}"
echo -e "${HR_THIN}"

for i in "${!DISPLAY_LIST[@]}"; do
  if [[ "${DISPLAY_LIST[$i]}" =~ ^Reseller: ]]; then
    printf "${MAG}%3d${RST}) ${BLD}%s${RST}\n" $((i+1)) "${DISPLAY_LIST[$i]}"
  elif [[ "${DISPLAY_LIST[$i]}" == "Select All" ]]; then
    printf "${GRN}%3d${RST}) ${BLD}%s${RST}\n" $((i+1)) "${DISPLAY_LIST[$i]}"
  elif [[ "${DISPLAY_LIST[$i]}" == "Search" ]]; then
    printf "${CYA}%3d${RST}) ${BLD}%s${RST}\n" $((i+1)) "${DISPLAY_LIST[$i]}"
  else
    printf "${DIM}%3d${RST}) %s\n" $((i+1)) "${DISPLAY_LIST[$i]}"
  fi
done

echo -e "${HR_THIN}"

SELECTED_USERS=()

add_user() {
  local u_to_add="$1"
  [ -f "/usr/local/directadmin/data/users/$u_to_add/user.conf" ] || { 
    warn "User '${BLD}$u_to_add${RST}' invalid, skipped"
    return 0
  }
  case " ${SELECTED_USERS[*]-} " in
    *" ${u_to_add} "*) : ;;
    *) SELECTED_USERS+=("$u_to_add") ;;
  esac
  return 0
}

handle_item() {
  local item_to_handle="$1" reseller_name="" reseller_user_list="" extracted_user=""
  
  if [ "$item_to_handle" == "Select All" ]; then
    SELECTED_USERS=("${ALL_USERS[@]}")
    return 0
  elif [[ "$item_to_handle" =~ ^Reseller:\ (.+)$ ]]; then
    reseller_name="${BASH_REMATCH[1]}"
    reseller_user_list="$(get_reseller_users "$reseller_name")"
    if [ -n "$reseller_user_list" ]; then
      for uu in $reseller_user_list; do add_user "$uu"; done
    fi
    [ -f "/usr/local/directadmin/data/users/$reseller_name/user.conf" ] && add_user "$reseller_name"
    return 1
  elif [ "$item_to_handle" == "Search" ]; then
    return 1
  else
    extracted_user="$(echo "$item_to_handle" | sed -E 's/^([^ ]+) .*/\1/')"
    [ -n "$extracted_user" ] && add_user "$extracted_user"
    return 1
  fi
}

while true; do
  echo
  PROMPT_TEXT="${BLU}${BLD}  ?  ${RST}Select accounts (${BLD}number${RST}, ${BLD}range 10:20${RST}, ${BLD}0${RST} finish, ${BLD}s${RST} search)
${BLD}     → ${RST}"
  
  if ! read -r -e -p "$(printf "%b" "$PROMPT_TEXT")" REPLY </dev/tty; then
    warn "Input interrupted (EOF)"
    continue
  fi
  
  [ -n "${REPLY:-}" ] || { warn "Please enter a selection"; continue; }
  
  if [ "$REPLY" == "0" ]; then
    break
  elif [ "$REPLY" == "s" ] || [ "$REPLY" == "S" ]; then
    SEARCH_PROMPT="${BLU}${BLD}  ?  ${RST}Enter search term (username or domain)
${BLD}     → ${RST}"
    if ! read -r -e -p "$(printf "%b" "$SEARCH_PROMPT")" SEARCH_TERM </dev/tty; then
      warn "Search cancelled (EOF)"
      continue
    fi
    if [ -n "${SEARCH_TERM:-}" ]; then
      echo
      echo -e "${BLD}Search results for '${CYA}${SEARCH_TERM}${RST}${BLD}':${RST}"
      echo -e "${HR_THIN}"
      found_results=0
      for i in "${!DISPLAY_LIST[@]}"; do
        if [[ "${DISPLAY_LIST[$i]}" =~ $SEARCH_TERM ]]; then
          printf "${GRN}%3d${RST}) %s\n" $((i+1)) "${DISPLAY_LIST[$i]}"
          found_results=1
        fi
      done
      [ $found_results -eq 0 ] && warn "No results found for '${BLD}$SEARCH_TERM${RST}'"
      echo -e "${HR_THIN}"
    fi
    continue
  fi
  
  if [[ "$REPLY" =~ ^[0-9]+:[0-9]+$ ]]; then
    START=${REPLY%:*}
    END=${REPLY#*:}
    if [ "$START" -ge 1 ] && [ "$END" -le "${#DISPLAY_LIST[@]}" ] && [ "$START" -le "$END" ]; then
      for ((i=START-1;i<END;i++)); do
        if handle_item "${DISPLAY_LIST[$i]}"; then break 2; fi
      done
      ok "Added items ${BLD}$START${RST} to ${BLD}$END${RST}"
    else
      warn "Invalid range. Must be between ${BLD}1${RST} and ${BLD}${#DISPLAY_LIST[@]}${RST}"
    fi
  elif [[ "$REPLY" =~ ^[0-9]+$ ]]; then
    if [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#DISPLAY_LIST[@]}" ]; then
      if handle_item "${DISPLAY_LIST[$((REPLY-1))]}"; then break; fi
      ok "Added: ${BLD}${DISPLAY_LIST[$((REPLY-1))]}${RST}"
    else
      warn "Invalid selection. Must be between ${BLD}1${RST} and ${BLD}${#DISPLAY_LIST[@]}${RST}"
    fi
  else
    warn "Invalid input. Use: ${BLD}number${RST}, ${BLD}range (10:20)${RST}, ${BLD}0${RST} (finish), or ${BLD}s${RST} (search)"
  fi
done

[ "${#SELECTED_USERS[@]}" -gt 0 ] || die "No users selected"

echo
ok "Selected ${BLD}${#SELECTED_USERS[@]}${RST} user(s): ${CYA}${SELECTED_USERS[*]-}${RST}"

# =========================
# Backup Process
# =========================
section "Step 3: ${ICON_BACKUP} Backup Process (Multi-User)"

info "Creating backup directory: ${BLD}$BACKUP_DIR${RST}"
mkdir -p "$BACKUP_DIR" || die "Failed to create backup directory $BACKUP_DIR"
ok "Backup directory created"

ENC_BACKUP_DIR="$(url_encode_path "$BACKUP_DIR")"

info "Queueing ONE backup task for ${BLD}${#SELECTED_USERS[@]}${RST} users"
echo "$(build_backup_task_line_multi)" >> "$TASK_QUEUE"
ok "Backup task queued"

progress "Executing DirectAdmin task queue (backup)..."
TASKQ_OUT="$("$DA_BIN" taskq 2>&1 || true)"

echo "$TASKQ_OUT" | tee -a "$LOG_FILE" >/dev/null

if echo "$TASKQ_OUT" | grep -qiE "error|failed|permission denied"; then
  die "DirectAdmin taskq failed on source (backup). Check log: $LOG_FILE"
fi

ok "Backup task execution triggered"

subsection "Waiting for Backup Files"

for u in "${SELECTED_USERS[@]}"; do
  wait_for_backup_file "$u" 3600 || die "Timeout waiting for backup file of user '${BLD}$u${RST}'"
done

ok "All backup files ready in ${BLD}$BACKUP_DIR${RST}"

# =========================
# Transfer Process
# =========================
section "Step 4: ${ICON_SYNC} Transfer Backups to Destination"

info "Transferring backups via rsync (resumable)"
echo -e "${DIM}  Source: ${BLD}$BACKUP_DIR${RST}"
echo -e "${DIM}  Destination: ${BLD}$DEST_USER@$DEST_IP:$DEST_PATH${RST}"
echo

sshpass -p "$SSH_PASS" rsync $RSYNC_OPTS \
  -e "ssh -q ${SSH_OPTS_STR}" \
  "$BACKUP_DIR/" "$DEST_USER@$DEST_IP:$DEST_PATH/" \
  || die "Failed to transfer backups to destination"

ok "Backup transfer completed"

progress "Fixing destination permissions for DirectAdmin..."
remote_ssh "
  set -e
  mkdir -p '$DEST_PATH'
  chown -R ${DA_ADMIN_USER}:${DA_ADMIN_USER} '$DEST_PATH'
  chmod 755 '$DEST_PATH'
" >/dev/null 2>&1 || die "Failed to fix destination permissions"
ok "Destination permissions configured"

# =========================
# Restore Process
# =========================
section "Step 5: ${ICON_SERVER} Restore Process on Destination"

ENC_DEST_PATH="$(url_encode_path "$DEST_PATH")"

subsection "Verifying Backup Files"

for u in "${SELECTED_USERS[@]}"; do
  f="$(find_backup_file_for_user "$u")"
  progress "Checking backup file for user: ${BLD}${u}${RST}"
  if ! remote_ssh "test -s '$DEST_PATH/$f'" >/dev/null 2>&1; then
    warn "Destination missing backup file: ${BLD}$DEST_PATH/$f${RST}"
  else
    ok "Verified: ${BLD}$f${RST}"
  fi
done

subsection "Queueing Restore Task"

restore_task="$(build_restore_task_line_multi)"

progress "Writing restore task to destination task.queue..."
remote_ssh "printf '%s\n' \"$restore_task\" >> '$TASK_QUEUE'" >/dev/null 2>&1 \
  || die "Failed to write restore task to destination task.queue"
ok "Restore task queued for ${BLD}${#SELECTED_USERS[@]}${RST} backups"

info "Executing task queue on destination..."
RESTORE_OUT="$(sshpass -p "$SSH_PASS" ssh -q \
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
  -o ConnectionAttempts="$SSH_CONNECTION_ATTEMPTS" \
  "${SSH_OPTS[@]}" \
  "$DEST_USER@$DEST_IP" "$DA_BIN taskq" 2>&1 || true)"

echo "$RESTORE_OUT" | tee -a "$LOG_FILE" >/dev/null

if echo "$RESTORE_OUT" | grep -qiE "error running backup task|task failed|permission denied|ensure_backup_readable|Error creating symlink: File exists"; then
  warn "Restore encountered errors on destination. Check $LOG_FILE and DirectAdmin logs"
else
  ok "Restore execution completed"
fi

# =========================
# Post-Restore Sync
# =========================
section "Step 6: ${ICON_SYNC} Post-Restore Data Synchronization"

info "Syncing heavy data directories (domains + imap)"
echo

for u in "${SELECTED_USERS[@]}"; do
  subsection "User: ${BLD}$u${RST}"
  
  wait_for_remote_user_home "$u" 1800 || die "Timeout: /home/$u not created on destination"
  
  rsync_user_subdir "$u" "domains"
  rsync_user_subdir "$u" "imap"
  fix_remote_ownership "$u"
  
  echo
done

ok "Post-restore synchronization completed for all users"

# =========================
# Cleanup
# =========================
section "Cleanup"

progress "Removing source backup directory: $BACKUP_DIR..."
rm -rf "$BACKUP_DIR" || die "Failed to remove $BACKUP_DIR"
ok "Source backup directory cleaned up"

unset SSH_PASS

# =========================
# Completion
# =========================
echo
echo -e "${HR_THICK}"
echo -e "${GRN}${BLD}  ${ICON_OK}  BACKUP AND RESTORE PROCESS COMPLETED SUCCESSFULLY${RST}"
echo -e "${HR_THICK}"
echo
echo -e "${BLD}Summary:${RST}"
echo -e "  ${DIM}•${RST} Users migrated: ${BLD}${#SELECTED_USERS[@]}${RST}"
echo -e "  ${DIM}•${RST} Destination: ${BLD}${DEST_USER}@${DEST_IP}${RST}"
echo -e "  ${DIM}•${RST} Log file: ${BLD}$LOG_FILE${RST}"
echo
echo -e "${DIM}Full operation log saved to: ${BLD}$LOG_FILE${RST}"
echo

log "Backup and restore process completed successfully"
