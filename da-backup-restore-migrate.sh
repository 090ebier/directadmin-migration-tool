#!/usr/bin/env bash
# DirectAdmin Backup -> Transfer -> Restore (multi-user) + Post-restore rsync
# FIXED: tput under set -e, interactive input stability, reseller listing fallback
set -euo pipefail
IFS=$' \t\n'

# =========================
# Config
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

# Optional: disable spinner in weak terminals/panels
DA_NO_SPINNER="${DA_NO_SPINNER:-0}"

# =========================
# Logging
# =========================
touch "$LOG_FILE" || { echo "Error: Cannot create log file $LOG_FILE"; exit 1; }
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >/dev/null; }

# =========================
# UI (SAFE under set -e)
# =========================
safe_tput() {
  command -v tput >/dev/null 2>&1 || return 0
  tput "$@" 2>/dev/null || true
}

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

ICON_OK="✔"; ICON_INFO="ℹ"; ICON_WARN="⚠"; ICON_ERR="✖"; ICON_STEP="➤"
HR="${DIM}────────────────────────────────────────────────────────${RST}"

ok()   { log "[OK]  $*";  echo -e "${GRN}${BLD}${ICON_OK} OK${RST}  $*"; }
info() { log "[..]  $*";  echo -e "${CYA}${BLD}${ICON_INFO} INFO${RST} $*"; }
warn() { log "[WRN] $*";  echo -e "${YLW}${BLD}${ICON_WARN} WARN${RST} $*"; }
err()  { log "[ERR] $*";  echo -e "${RED}${BLD}${ICON_ERR} ERR${RST}  $*"; }

die() {
  err "$*"
  unset SSH_PASS 2>/dev/null || true
  exit 1
}

section() {
  echo -e "\n${HR}\n${MAG}${BLD}${ICON_STEP} $*${RST}\n${HR}"
  log "----- $* -----"
}

# =========================
# TTY handling (FIX)
# =========================
require_tty() {
  if ! [ -r /dev/tty ]; then
    err "This script requires an interactive TTY (/dev/tty not readable)."
    err "Run it in a real SSH session. If using pipes, run via: script -c \"bash da-backup-restore-migrate.sh\""
    exit 1
  fi
}

# =========================
# Spinner (safe)
# =========================
_spinner_pid=""

spinner_start() {
  local msg="$1"

  if [ "${DA_NO_SPINNER:-0}" = "1" ] || ! [ -t 1 ]; then
    info "$msg"
    return 0
  fi

  spinner_stop || true

  printf "%b" "${CYA}${BLD}${ICON_INFO} INFO${RST} ${msg} ${DIM}(working)${RST} "
  (
    local sp='|/-\' i=0
    while :; do
      printf "\b%s" "${sp:i++%4:1}"
      sleep 0.1
    done
  ) &
  _spinner_pid=$!
}

spinner_stop() {
  if [ -n "${_spinner_pid:-}" ]; then
    kill "${_spinner_pid}" 2>/dev/null || true
    wait "${_spinner_pid}" 2>/dev/null || true
    _spinner_pid=""
    [ -t 1 ] && printf "\b \n"
  fi
  return 0
}

# =========================
# Helpers
# =========================
check_command() { command -v "$1" &>/dev/null || die "$1 is not installed."; }
url_encode_path() { echo "$1" | sed 's/\//%2F/g'; }
url_encode_dots() { echo "$1" | sed 's/\./%2E/g'; }

is_valid_ip() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  read -r -a octets <<< "$ip"
  for o in "${octets[@]}"; do [[ $o -ge 0 && $o -le 255 ]] || return 1; done
  return 0
}

prompt() {
  local q="$1" d="${2:-}" reply=""
  if [ -n "$d" ]; then
    read -r -p "$(echo -e "${BLU}${BLD}?${RST} ${q} ${DIM}[default: ${d}]${RST}: ")" reply </dev/tty \
      || die "Input aborted (EOF)"
    echo "${reply:-$d}"
  else
    read -r -p "$(echo -e "${BLU}${BLD}?${RST} ${q}: ")" reply </dev/tty \
      || die "Input aborted (EOF)"
    echo "$reply"
  fi
}

prompt_secret() {
  local q="$1" reply=""
  read -r -s -p "$(echo -e "${BLU}${BLD}?${RST} ${q}: ")" reply </dev/tty \
    || die "Input aborted (EOF)"
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

  # IMPORTANT: No directory-scan fallback (it returns DA internal dirs)
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
  info "Waiting for backup file for '${u}' ..."
  start=$(date +%s)
  while true; do
    f="$(find_backup_file_for_user "$u")"
    if [ -n "$f" ] && [ -s "$BACKUP_DIR/$f" ]; then
      ok "Backup ready: $BACKUP_DIR/$f"
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
  info "Warming up SSH connection (first contact) ..."
  remote_ssh "echo ok" >/dev/null 2>&1 || die "SSH warm-up failed (check IP/port/user/pass/firewall/sshd)."
  ok "SSH warm-up OK."
}

wait_for_remote_user_home() {
  local u="$1" timeout_sec="${2:-1800}"
  local start now
  info "Waiting for destination /home/$u to exist ..."
  start=$(date +%s)
  while true; do
    if remote_ssh "test -d '/home/$u'"; then
      ok "Destination /home/$u exists."
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
    warn "Source missing: $src (skip)"
    return 0
  fi

  info "Rsync $u/$subdir (resumable; faster ssh) ..."

  local RSYNC_SSH
  RSYNC_SSH="ssh -q -T -o Compression=no -o IPQoS=throughput -o ServerAliveInterval=30 -o ServerAliveCountMax=3 ${SSH_OPTS_STR}"

  sshpass -p "$SSH_PASS" rsync $RSYNC_OPTS -e "$RSYNC_SSH" \
    "$src" "$DEST_USER@$DEST_IP:$dst" \
    || die "Rsync failed for $u/$subdir"

  ok "Synced $u/$subdir"
}

fix_remote_ownership() {
  local u="$1"
  info "Fixing ownership on destination for $u (domains + imap) ..."

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

  ok "Ownership fixed for $u"
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
# Start
# =========================
echo -e "${MAG}${BLD}DirectAdmin Backup/Restore Wizard${RST}\n${DIM}Log:${RST} $LOG_FILE"
log "Starting backup/restore"

require_tty

section "Pre-flight checks"
check_command rsync
check_command ssh
check_command sshpass
[ -x "$DA_BIN" ] || die "DirectAdmin binary not found at $DA_BIN"
[ -w "$(dirname "$BACKUP_DIR")" ] || die "Backup base dir is not writable"
ok "All required commands present."
ok "DirectAdmin binary ok."

section "Step 1: Destination details"
DEST_IP="$(prompt 'Enter destination server IP (or hostname)' '')"
SSH_PORT="$(prompt 'Enter destination SSH port' "$SSH_PORT_DEFAULT")"
DEST_USER="$(prompt 'Enter destination server SSH username' 'root')"
DEST_PATH="$(prompt 'Enter destination path for backups' "$DEST_PATH_DEFAULT")"

[ -n "$DEST_IP" ] || die "Destination IP/host is required"
[ -n "$DEST_PATH" ] || die "Destination path is required"

if is_valid_ip "$DEST_IP"; then
  DEST_SERVER_IP="$DEST_IP"
  info "Using ${DEST_IP} as restore IP (same as destination)."
else
  DEST_SERVER_IP="$(prompt 'Enter an IP address available on destination server for restore' '')"
fi

[ -n "${DEST_SERVER_IP:-}" ] || die "Restore IP is required"
SSH_PASS="$(prompt_secret "Enter SSH password for ${DEST_USER}@${DEST_IP}")"
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

spinner_start "Testing SSH connection to ${DEST_USER}@${DEST_IP}"
if remote_ssh "exit" >/dev/null 2>&1; then
  spinner_stop
  ok "SSH connection established."
else
  spinner_stop
  die "Failed to connect to destination server."
fi

ssh_warmup

spinner_start "Verifying destination path ${DEST_PATH}"
remote_ssh "mkdir -p '$DEST_PATH' && [ -w '$DEST_PATH' ]" >/dev/null 2>&1 \
  || { spinner_stop; die "Destination path $DEST_PATH is not writable or cannot be created."; }
spinner_stop
ok "Destination path is writable."

spinner_start "Verifying restore IP ${DEST_SERVER_IP} exists on destination"
remote_ssh "ip addr show | grep -q '$DEST_SERVER_IP'" >/dev/null 2>&1 \
  || { spinner_stop; die "Restore IP $DEST_SERVER_IP does not exist on destination."; }
spinner_stop
ok "Restore IP verified."

section "Step 2: Account selection"
info "Fetching list of DirectAdmin accounts and resellers..."

RESELLERS=()
ALL_USERS=()
DISPLAY_LIST=("Select All" "Search")

spinner_start "Scanning user directories"

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

spinner_stop

[ ${#ALL_USERS[@]} -gt 0 ] || die "No DirectAdmin users found! Check /usr/local/directadmin/data/users/"
ok "Found ${#ALL_USERS[@]} users and ${#RESELLERS[@]} resellers"

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
echo -e "${BLD}Available accounts (${#DISPLAY_LIST[@]} items):${RST}"
for i in "${!DISPLAY_LIST[@]}"; do
  printf "%s%3d%s) %s\n" "${DIM}" $((i+1)) "${RST}" "${DISPLAY_LIST[$i]}"
done

SELECTED_USERS=()

add_user() {
  local u_to_add="$1"
  [ -f "/usr/local/directadmin/data/users/$u_to_add/user.conf" ] || { warn "User '$u_to_add' invalid, skip"; return 0; }
  [[ " ${SELECTED_USERS[*]} " =~ " ${u_to_add} " ]] || SELECTED_USERS+=("$u_to_add")
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
  echo -ne "${BLU}${BLD}?${RST} Select accounts (number, range 10:20, 0 finish, 's' search): "
  if ! read -r REPLY </dev/tty; then
    warn "Input interrupted (EOF)."
    continue
  fi

  [ -n "${REPLY:-}" ] || { warn "Please enter a selection"; continue; }

  if [ "$REPLY" == "0" ]; then
    break
  elif [ "$REPLY" == "s" ] || [ "$REPLY" == "S" ]; then
    echo -ne "${BLU}${BLD}?${RST} Enter search term (username or domain): "
    if ! read -r SEARCH_TERM </dev/tty; then
      warn "Search cancelled (EOF)."
      continue
    fi
    if [ -n "${SEARCH_TERM:-}" ]; then
      echo -e "${BLD}Search results:${RST}"
      found_results=0
      for i in "${!DISPLAY_LIST[@]}"; do
        if [[ "${DISPLAY_LIST[$i]}" =~ $SEARCH_TERM ]]; then
          printf "%s%3d%s) %s\n" "${DIM}" $((i+1)) "${RST}" "${DISPLAY_LIST[$i]}"
          found_results=1
        fi
      done
      [ $found_results -eq 0 ] && warn "No results found for '$SEARCH_TERM'"
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
      ok "Added items $START to $END"
    else
      warn "Invalid range. Must be between 1 and ${#DISPLAY_LIST[@]}"
    fi
  elif [[ "$REPLY" =~ ^[0-9]+$ ]]; then
    if [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#DISPLAY_LIST[@]}" ]; then
      if handle_item "${DISPLAY_LIST[$((REPLY-1))]}"; then break; fi
      ok "Added: ${DISPLAY_LIST[$((REPLY-1))]}"
    else
      warn "Invalid selection. Must be between 1 and ${#DISPLAY_LIST[@]}"
    fi
  else
    warn "Invalid input. Use: number, range (10:20), 0 (finish), or 's' (search)"
  fi
done

[ "${#SELECTED_USERS[@]}" -gt 0 ] || die "No users selected."
ok "Selected ${#SELECTED_USERS[@]} user(s): ${SELECTED_USERS[*]}"

section "Step 3: Backup (one multi-user task)"
info "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" || die "Failed to create backup directory $BACKUP_DIR"
ENC_BACKUP_DIR="$(url_encode_path "$BACKUP_DIR")"

info "Queueing ONE backup task (multi-user) into $TASK_QUEUE ..."
echo "$(build_backup_task_line_multi)" >> "$TASK_QUEUE"
ok "Queued backup task for ${#SELECTED_USERS[@]} users."

spinner_start "Executing DirectAdmin task queue (backup)"
TASKQ_OUT="$("$DA_BIN" taskq 2>&1 || true)"
spinner_stop
echo "$TASKQ_OUT" | tee -a "$LOG_FILE" >/dev/null
echo "$TASKQ_OUT" | grep -qiE "error|failed|permission denied" && die "DirectAdmin taskq failed on source (backup). Check log: $LOG_FILE"
ok "Backup task execution triggered."

info "Waiting for backup files to be created..."
for u in "${SELECTED_USERS[@]}"; do
  wait_for_backup_file "$u" 3600 || die "Timeout waiting for backup file of user '$u'"
done
ok "All backup files are ready in $BACKUP_DIR"

section "Step 4: Transfer backups to destination (rsync resumable)"
info "Transferring backups -> $DEST_USER@$DEST_IP:$DEST_PATH ..."
sshpass -p "$SSH_PASS" rsync $RSYNC_OPTS \
  -e "ssh -q ${SSH_OPTS_STR}" \
  "$BACKUP_DIR/" "$DEST_USER@$DEST_IP:$DEST_PATH/" \
  || die "Failed to transfer backups to destination"
ok "Backup transfer completed."

info "Fixing destination permissions for DirectAdmin restore..."
remote_ssh "
  set -e
  mkdir -p '$DEST_PATH'
  chown -R ${DA_ADMIN_USER}:${DA_ADMIN_USER} '$DEST_PATH'
  chmod 755 '$DEST_PATH'
" >/dev/null 2>&1 || die "Failed to fix destination permissions"
ok "Destination permissions fixed."

section "Step 5: Restore (one multi-backup task) on destination"
ENC_DEST_PATH="$(url_encode_path "$DEST_PATH")"

info "Verifying backup files exist on destination..."
for u in "${SELECTED_USERS[@]}"; do
  f="$(find_backup_file_for_user "$u")"
  if ! remote_ssh "test -s '$DEST_PATH/$f'" >/dev/null 2>&1; then
    echo "WARNING: Destination missing backup file: $DEST_PATH/$f" | tee -a "$LOG_FILE"
  fi
done
ok "Backup file verification completed (errors logged if any)."

restore_task="$(build_restore_task_line_multi)"
info "Writing restore task into destination task.queue..."
remote_ssh "printf '%s\n' \"$restore_task\" >> '$TASK_QUEUE'" >/dev/null 2>&1 \
  || die "Failed to write restore task to destination task.queue"
ok "Queued restore task for ${#SELECTED_USERS[@]} backups."

info "Executing task queue (restore) on destination..."
RESTORE_OUT="$(sshpass -p "$SSH_PASS" ssh -q \
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
  -o ConnectionAttempts="$SSH_CONNECTION_ATTEMPTS" \
  "${SSH_OPTS[@]}" \
  "$DEST_USER@$DEST_IP" "$DA_BIN taskq" 2>&1 || true)"

echo "$RESTORE_OUT" | tee -a "$LOG_FILE" >/dev/null

if echo "$RESTORE_OUT" | grep -qiE "error running backup task|task failed|permission denied|ensure_backup_readable|Error creating symlink: File exists"; then
  warn "Restore encountered errors on destination. Check $LOG_FILE and DirectAdmin logs."
fi
ok "Restore execution triggered on destination (errors logged if any)."

section "Step 6: Post-restore rsync heavy data (domains + imap)"
for u in "${SELECTED_USERS[@]}"; do
  wait_for_remote_user_home "$u" 1800 || die "Timeout: /home/$u not created on destination"
  rsync_user_subdir "$u" "domains"
  rsync_user_subdir "$u" "imap"
  fix_remote_ownership "$u"
done
ok "Post-restore rsync completed for all selected users."

section "Cleanup"
info "Removing backup files from source server: $BACKUP_DIR ..."
rm -rf "$BACKUP_DIR" || die "Failed to remove $BACKUP_DIR"
ok "Source backup directory cleaned up."

unset SSH_PASS
ok "Backup and restore process completed successfully. Log: $LOG_FILE"
