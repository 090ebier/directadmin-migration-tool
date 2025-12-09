#!/usr/bin/env bash
# DirectAdmin Backup -> Transfer -> Restore (multi-user) + Post-restore rsync
# UI/UX rewrite + FIXES:
# - SSH_OPTS as ARRAY (no "Bad port" parsing bugs)
# - Silence SSH warnings ("Permanently added ...") via LogLevel + known_hosts to /dev/null
# - SSH warm-up (even if you never ssh'ed before)
# - Spinner-safe SSH calls (redirect noisy output)
# - rsync progress in human-readable (KB/MB/GB) + summary stats
# - safer rsync -e ssh string via SSH_OPTS_STR
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

# -h => human readable (KB/MB/GB)
# --stats => summary at end
# --info=progress2 => single-line overall progress
RSYNC_OPTS="-a -h --stats --no-owner --no-group --omit-dir-times --delete-delay --info=progress2 --partial --append-verify"

# SSH quiet + stable defaults
SSH_CONNECT_TIMEOUT="8"
SSH_CONNECTION_ATTEMPTS="2"

# =========================
# UI (colors + layout)
# =========================
if [ -t 1 ]; then
  RST="$(tput sgr0)"; BLD="$(tput bold)"; DIM="$(tput dim)"
  RED="$(tput setaf 1)"; GRN="$(tput setaf 2)"; YLW="$(tput setaf 3)"
  BLU="$(tput setaf 4)"; MAG="$(tput setaf 5)"; CYA="$(tput setaf 6)"; WHT="$(tput setaf 7)"
else
  RST=""; BLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; MAG=""; CYA=""; WHT=""
fi

ICON_OK="✔"; ICON_INFO="ℹ"; ICON_WARN="⚠"; ICON_ERR="✖"; ICON_STEP="➤"
HR="${DIM}────────────────────────────────────────────────────────${RST}"

touch "$LOG_FILE" || { echo "Error: Cannot create log file $LOG_FILE"; exit 1; }

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >/dev/null; }

ok()   { log "[OK]  $*";   echo -e "${GRN}${BLD}${ICON_OK} OK${RST}  $*"; }
info() { log "[..]  $*";   echo -e "${CYA}${BLD}${ICON_INFO} INFO${RST} $*"; }
warn() { log "[WRN] $*";   echo -e "${YLW}${BLD}${ICON_WARN} WARN${RST} $*"; }
err()  { log "[ERR] $*";   echo -e "${RED}${BLD}${ICON_ERR} ERR${RST}  $*"; }

die() {
  err "$*"
  unset SSH_PASS 2>/dev/null || true
  exit 1
}

section() {
  echo -e "\n${HR}\n${MAG}${BLD}${ICON_STEP} $*${RST}\n${HR}"
  log "----- $* -----"
}

prompt() {
  local q="$1" d="${2:-}"
  if [ -n "$d" ]; then
    read -r -p "$(echo -e "${BLU}${BLD}?${RST} ${q} ${DIM}[default: ${d}]${RST}: ")" REPLY
    echo "${REPLY:-$d}"
  else
    read -r -p "$(echo -e "${BLU}${BLD}?${RST} ${q}: ")" REPLY
    echo "$REPLY"
  fi
}

prompt_secret() {
  local q="$1" REPLY=""
  # Always read from the real terminal to avoid stdin pollution (curl/progress/pipe)
  read -r -s -p "$(echo -e "${BLU}${BLD}?${RST} ${q}: ")" REPLY </dev/tty
  echo >/dev/tty
  echo "$REPLY"
}


_spinner_pid=""
spinner_start() {
  local msg="$1"
  [ -t 1 ] || { info "$msg"; return 0; }
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
  [ -n "${_spinner_pid:-}" ] || return 0
  kill "$_spinner_pid" 2>/dev/null || true
  wait "$_spinner_pid" 2>/dev/null || true
  _spinner_pid=""
  [ -t 1 ] && printf "\b \n"
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
  IFS='.' read -r -a octets <<< "$ip"
  for o in "${octets[@]}"; do [[ $o -ge 0 && $o -le 255 ]] || return 1; done
  return 0
}

get_reseller_users() {
  local reseller="$1"
  local f="/usr/local/directadmin/data/users/$reseller/users.list"
  [ -f "$f" ] || { echo ""; return; }
  tr '\n' ' ' < "$f"
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

# All remote ssh commands should use this wrapper (silent + consistent)
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
    local f
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

# IMPORTANT FIX: SSH_OPTS as ARRAY + silent hostkey warnings
SSH_OPTS=(
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)
[ -f "$SSH_CONFIG_FILE" ] && SSH_OPTS+=( -F "$SSH_CONFIG_FILE" )

# Safer string for rsync -e
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

# Warm-up explicitly (covers: no prior ssh)
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
for u in /usr/local/directadmin/data/users/*; do
  u="${u##*/}"
  [ -f "/usr/local/directadmin/data/users/$u/reseller.conf" ] && RESELLERS+=("$u")
done

mapfile -t ALL_USERS < <(ls -1 /usr/local/directadmin/data/users/)

DISPLAY_LIST=("Select All" "Search")
for reseller in "${RESELLERS[@]}"; do
  DISPLAY_LIST+=("Reseller: $reseller")
  reseller_users="$(get_reseller_users "$reseller")"
  for user in $reseller_users; do
    if [ -f "/usr/local/directadmin/data/users/$user/user.conf" ]; then
      domain="$(grep -m1 "^domain=" "/usr/local/directadmin/data/users/$user/user.conf" | cut -d'=' -f2)"
      DISPLAY_LIST+=("$user ($domain)")
    else
      DISPLAY_LIST+=("$user (no domain found)")
    fi
  done

  if [ -f "/usr/local/directadmin/data/users/$reseller/user.conf" ]; then
    domain="$(grep -m1 "^domain=" "/usr/local/directadmin/data/users/$reseller/user.conf" | cut -d'=' -f2)"
    DISPLAY_LIST+=("$reseller ($domain)")
  fi
done

echo
echo -e "${BLD}Available accounts:${RST}"
for i in "${!DISPLAY_LIST[@]}"; do
  printf "%s%3d%s) %s\n" "${DIM}" $((i+1)) "${RST}" "${DISPLAY_LIST[$i]}"
done

SELECTED_USERS=()
add_user() { local u="$1"; [[ " ${SELECTED_USERS[*]} " =~ " ${u} " ]] || SELECTED_USERS+=("$u"); }

handle_item() {
  local item="$1"
  if [ "$item" == "Select All" ]; then
    SELECTED_USERS=("${ALL_USERS[@]}")
    return 0
  elif [[ "$item" =~ ^Reseller: ]]; then
    local reseller users
    reseller="$(echo "$item" | awk '{print $2}')"
    users="$(get_reseller_users "$reseller")"
    for uu in $users; do add_user "$uu"; done
    [ -f "/usr/local/directadmin/data/users/$reseller/user.conf" ] && add_user "$reseller"
    return 1
  else
    local u
    u="$(echo "$item" | awk '{print $1}')"
    add_user "$u"
    return 1
  fi
}

while true; do
  echo
  REPLY="$(prompt "Select accounts (number, range 10:20, 0 finish, 's' search)" "")"

  if [ "$REPLY" == "0" ]; then
    break
  elif [ "$REPLY" == "s" ]; then
    SEARCH_TERM="$(prompt "Enter search term (username or domain)" "")"
    echo -e "${BLD}Search results:${RST}"
    for i in "${!DISPLAY_LIST[@]}"; do
      [[ "${DISPLAY_LIST[$i]}" =~ $SEARCH_TERM ]] && printf "%d) %s\n" $((i+1)) "${DISPLAY_LIST[$i]}"
    done
    continue
  fi

  if [[ "$REPLY" =~ ^[0-9]+:[0-9]+$ ]]; then
    START=${REPLY%:*}; END=${REPLY#*:}
    if [ "$START" -ge 1 ] && [ "$END" -le "${#DISPLAY_LIST[@]}" ] && [ "$START" -le "$END" ]; then
      for ((i=START-1;i<END;i++)); do
        if handle_item "${DISPLAY_LIST[$i]}"; then break 2; fi
      done
    else
      warn "Invalid range."
    fi
  elif [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#DISPLAY_LIST[@]}" ]; then
    if handle_item "${DISPLAY_LIST[$((REPLY-1))]}"; then break; fi
  else
    warn "Invalid selection."
  fi
done

[ "${#SELECTED_USERS[@]}" -gt 0 ] || die "No users selected."
ok "Selected users: ${SELECTED_USERS[*]}"

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
  remote_ssh "test -s '$DEST_PATH/$f'" >/dev/null 2>&1 \
    || die "Destination missing backup file: $DEST_PATH/$f"
done
ok "All backup files exist on destination."

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
  die "Restore failed on destination. Please check DirectAdmin logs on destination + $LOG_FILE"
fi
ok "Restore execution triggered on destination."

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
