#! /bin/bash

set -eu -o pipefail

Script_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/helpers.sh
source "$Script_Dir/helpers.sh"
# shellcheck source=./common.sh
source "$Script_Dir/common.sh"

Todo="$Script_Dir/todo"
ToUndo="$Script_Dir/toundo"
New_Port_Record="$Script_Dir/new_port"
Sudo_Group=""


Main(){
  trap OnExit EXIT INT TERM HUP

  InitializeSystemInfo
  echo

  if [[ ! -f "$Todo" ]]; then
    Log -e "The setup plan '$Todo' was not found"
    exit 1
  fi

  local todos; mapfile -t todos < "$Todo"
  for todo in "${todos[@]}"; do
    if eval "$todo"; then
      echo
    else
      local exit_code=$?
      Log -e "Step failed with exit code $exit_code"
      exit "$exit_code"
    fi
  done

  echo "$SSH_PORT" > "$New_Port_Record"
}


OnExit(){
  local exit_code=$?
  trap - EXIT INT TERM HUP
  StartRecoveryTimer
  exit "$exit_code"
}


StartRecoveryTimer(){
  Log -w "Recovery timer started. The server will automatically run the restore script after 90 seconds"
  # The directory intentionally kept private.
  # Disable is achieved by creating a cancel file besides the directory.
  chmod -R u=rwX,go= "$Script_Dir"
  local cancel_file="${Script_Dir}.cancel"
  nohup sh -c "sleep 90 && if [ -f '$cancel_file' ]; then rm -rf '$Script_Dir' '$cancel_file'; else TIMESTAMP='$TIMESTAMP' TYPING='$TYPING' bash '$Script_Dir/restore.sh' '$Script_Dir/restore.log'; fi" >/dev/null 2>&1 &
  Log "Recovery service is waiting in the background with PID $!"
  Log "Recovery log will be written to $Script_Dir/restore.log"
}


InitializeSystemInfo(){
  if ! GetDistroInfo || ! CheckOsSupport; then
    Log -e "Cannot set up an unsupported Linux distribution: $Os"
    exit 1
  fi

  case "$Os" in
    debian|ubuntu)
      Update_Cmd="UpdateDebianPackages"
      Install_Cmd="apt-get install -y"
      ;;
    almalinux|centos|rocky)
      Update_Cmd="dnf update -y"
      Install_Cmd="dnf install -y"
      ;;
    fedora)
      Update_Cmd="dnf upgrade --refresh -y"
      Install_Cmd="dnf install -y"
      ;;
  esac

  Log "Package update command: $Update_Cmd"
  Log "Package install command: $Install_Cmd"
}


### User
EnsureSudoInstalledAndEnabled(){
  EnsureInstalled sudo

  Sudo_Group=$(grep -E '^(wheel|sudo):' /etc/group | cut -d: -f1 | head -n1)
  if [[ -z $Sudo_Group ]]; then
    Log -e "Could not find a sudo group after installing sudo"
    return 1
  fi

  local file="/etc/sudoers"
  if ! grep -Eq "^[[:space:]]*%$Sudo_Group ALL=\\(ALL(:ALL)?\\) ALL" "$file"; then
    local tmp; tmp=$(CreateTmp "$file")
    local bak; bak=$(CreateBackup "$file")
    sed -i -E "s|^[[:space:]]*#[[:space:]]*(%$Sudo_Group ALL=\\(ALL(:ALL)?\\) ALL)|\\1|" "$tmp"
    if visudo -csf "$tmp" >/dev/null 2>&1; then
      AddUndo RestoreSudo
      mv "$tmp" "$file"
    else
      rm -f "$tmp" "$bak"
      Log -e "Could not enable sudo. You may need to enable it manually by editing $file"
    fi
  fi
  Log "Sudo is enabled"
}


AddUser(){
  local name=$1 password=$2 sudo=$3 shell=$4
  local args=("useradd" "-U" "-m")

  if [[ "$sudo" == "true" ]]; then
    args+=("-G" "$Sudo_Group")
  elif [[ "$sudo" != "false" ]]; then
    Log -e "Invalid sudo setting '$sudo'. Use 'true' or 'false'"
    return 1
  fi
  if [[ -n $shell ]]; then
    local path
    if ! path=$(grep -m 1 -E "(^|/)$shell$" /etc/shells); then
      Log -e "Shell '$shell' is not available on this server"
      return 1
    fi
    args+=("-s" "$path")
  fi

  args+=("$name")

  AddUndo DeleteUser "$name"
  "${args[@]}"
  Log "Created user '$name'"

  usermod -p "$password" "$name"
  Log "Set the password for user '$name'"
}


ChangeRootPassword(){
  AddUndo RestoreRootPassword "$(grep -E "^root:" /etc/shadow | cut -d: -f2)"
  usermod -p "$1" root
  Log "Changed the root user's password"
}


AddPublicKeys(){
  local keys=("$Script_Dir"/*.pub)
  local user home record key_name
  for key in "${keys[@]}"; do
    key_name=$(basename "$key")
    user=${key_name%.$TIMESTAMP.key.pub}
    home=$(getent passwd "$user" | cut -d: -f6)
    record="$home/.ssh/authorized_keys"

    mkdir -p "$home/.ssh"
    chmod 700 "$home/.ssh"
    chown "$user:$user" "$home/.ssh"
    if [[ -f $record ]]; then
      CreateBackup "$record" >/dev/null
      AddUndo RestoreAuthorizedKey "$user"
    else
      touch "$record"
      AddUndo RemoveAuthorizedKey "$user"
    fi
    chmod 600 "$record"
    chown "$user:$user" "$record"

    cat "$key" >> "$record"
    Log "Added public key '$key' for user '$user'"
  done
}


### Hostname
ChangeHostname(){
  local old=$1 new=${2:-}
  AddUndo RestoreHostname "$old"

  local hostname_file="/etc/hostname"
  CreateBackup "$hostname_file" >/dev/null

  hostnamectl set-hostname "$new"
  echo "$new" > "$hostname_file"

  local hosts_file="/etc/hosts"
  CreateBackup "$hosts_file" >/dev/null
  case "$Os" in
    debian|ubuntu)
      if grep -Eq '^[[:space:]]*127\.0\.1\.1([[:space:]]|$)' "$hosts_file"; then
        sed -i -E "s|^[[:space:]]*127\\.0\\.1\\.1([[:space:]].*)?$|127.0.1.1 $new|" "$hosts_file"
      else
        printf '\n127.0.1.1 %s\n' "$new" >> "$hosts_file"
      fi
      ;;
    almalinux|centos|rocky|fedora)
      if grep -Eq '^[[:space:]]*127\.0\.0\.1([[:space:]]|$)' "$hosts_file"; then
        sed -i -E "s|^[[:space:]]*127\\.0\\.0\\.1([[:space:]].*)?$|127.0.0.1 localhost $new $new.localdomain $new.localdomain4|" "$hosts_file"
      else
        printf '\n127.0.0.1 localhost %s %s %s\n' "$new" "$new.localdomain" "$new.localdomain4" >> "$hosts_file"
      fi
      if grep -Eq '^[[:space:]]*::1([[:space:]]|$)' "$hosts_file"; then
        sed -i -E "s|^[[:space:]]*::1([[:space:]].*)?$|::1 localhost $new $new.localdomain $new.localdomain6|" "$hosts_file"
      else
        printf '::1 localhost %s %s %s\n' "$new" "$new.localdomain" "$new.localdomain6" >> "$hosts_file"
      fi
      ;;
  esac

  Log "Changed the hostname to $new"
  if [[ -d /etc/cloud ]]; then
    Typing -w "Your provider uses Cloud-Init. The server may apply its own hostname settings at boot, so this hostname change may not persist. You may need to disable Cloud-Init or change its template manually"
  fi
}


### Time
ChangeTimezone(){
  AddUndo RestoreTimezone "$1"
  timedatectl set-timezone "$2"
  Log "Changed the timezone to $2"
}


### SSH
EnableAndCreateSshdDirectives(){
  local directive_dir="/etc/ssh/sshd_config.d"
  local config="/etc/ssh/sshd_config" line="Include $directive_dir/*.conf"
  local active_pattern='^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$'
  local commented_pattern='^[[:space:]]*#[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$'
  CreateBackup "$config" >/dev/null
  AddUndo RestoreSshd
  if ! grep -Eq "$active_pattern" "$config"; then
    Log "Created a backup"
    if grep -Eq "$commented_pattern" "$config"; then
      sed -i -E 's|^[[:space:]]*#[[:space:]]*(Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf)[[:space:]]*$|\1|' "$config"
    else
      sed -i "1i $line" "$config"
    fi
  fi
  Log "The original SSH configuration now includes the directive folder"

  mkdir -p "$directive_dir"
  touch "$Sshd_Config"
  Log "Created SSH directive configuration at $Sshd_Config"
}


ChangeSshPort(){
  CheckIfValidPort "$1" || { Log -e "Invalid SSH port: $1"; return 1; }
  SSH_PORT=$1
  echo "Port $1" >> "$Sshd_Config"
  Log "Changed the SSH port to $1"
}


EnablePublicKeyAuthentication(){
  echo "PubkeyAuthentication yes" >> "$Sshd_Config"
  Log "Enabled public key authentication"
}


DisablePasswordLogin(){
  echo "PasswordAuthentication no" >> "$Sshd_Config"
  Log "Disabled password login"
}


DisableRootLogin(){
  echo "PermitRootLogin no" >> "$Sshd_Config"
  Log "Disabled root login"
}


### Packages
UpdatePackages(){
  AddUndo NotifyPackagesUpdated
  if $Update_Cmd; then
    Log "${G}All packages were successfully updated${I}"
  else
    Log -e "Could not update all packages. You may need to update them manually later"
    return 1
  fi
}


SetUpFail2Ban(){
  AddDisableUndo fail2ban DisableFail2Ban

  case "$Os" in
    debian|ubuntu)
      EnsureInstalled fail2ban
      ;;
    almalinux|centos|rocky|fedora)
      Typing "On RHEL-based distributions, the default repository contains only core packages. Fail2Ban is provided by the Extra Packages for Enterprise Linux (EPEL) repository, so that repository must also be enabled"
      EnsureInstalled epel-release
      EnsureInstalled fail2ban
      ;;
  esac || return 1

  local default_config="/etc/fail2ban/jail.conf"
  local local_config="/etc/fail2ban/jail.local"
  if [[ ! -f "$default_config" ]]; then
    Log -e "Fail2Ban configuration '$default_config' was not found"
    return 1
  fi
  if [[ -f "$local_config" ]]; then
    CreateBackup "$local_config" >/dev/null
  fi
  AddUndo RestoreFail2Ban
  if [[ ! -f "$local_config" ]]; then
    cp "$default_config" "$local_config"
  fi

  local max_retry; max_retry=$(grep -m1 "^maxretry" "$local_config" | awk -F= '{print $2}' | tr -d ' ')
  local ban_time; ban_time=$(grep -m1 "^bantime" "$local_config" | awk -F= '{print $2}' | tr -d ' ')
  local find_time; find_time=$(grep -m1 "^findtime" "$local_config" | awk -F= '{print $2}' | tr -d ' ')
  Log "Current Fail2Ban settings allow $max_retry failed attempts within $find_time, followed by a ban lasting $ban_time"

  systemctl enable fail2ban
  systemctl start fail2ban
  Log "Fail2Ban is running and protecting the server"
}


SetUpUfw(){
  if ! command -v ufw >/dev/null 2>&1 || ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    AddUndo DisableUfw
  fi

  Disable firewalld || return 1
  ! EnsureInstalled ufw && return 1

  AddUndo RestoreUfw
  Log "Backing up UFW rules"
  local dir=/etc/ufw backup=/etc/ufw.backup
  cp -a "$dir" "$backup"
  Log "UFW rules backed up at $backup"

  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "$SSH_PORT/tcp"
  Log "Denied inbound connections except on SSH port $SSH_PORT and allowed all outbound connections"

  if ufw --force enable; then
    Log "UFW is enabled and will start automatically at boot"
  else
    Log -e "Could not enable UFW"
    return 1
  fi
}


SetUpFirewalld(){
  AddDisableUndo firewalld DisableFirewalld

  Disable ufw || return 1
  ! EnsureInstalled firewalld && return 1

  AddUndo RestoreFirewalld
  Log "Backing up firewalld rules"
  local dir=/etc/firewalld backup=/etc/firewalld.backup
  cp -a "$dir" "$backup"
  Log "firewalld rules backed up at $backup"

  Log "Configuring firewalld"
  systemctl enable --now firewalld
  firewall-cmd --permanent --set-default-zone=public
  Log "Set firewalld default zone to 'public'"
  firewall-cmd --permanent --zone=public --set-target=default
  Log "Set firewalld default target to 'default'"
  local services; services=$(firewall-cmd --zone=public --list-services)
  local -a array; IFS=' ' read -ra array <<< "$services"
  local s; for s in "${array[@]}"; do
      firewall-cmd --permanent --zone=public --remove-service="$s"
      Log "Removed allowed firewalld service $s"
  done

  firewall-cmd --permanent --zone=public --add-port="$SSH_PORT/tcp"
  Log "Allowed SSH port $SSH_PORT"

  firewall-cmd --reload

  Log "firewalld is enabled and will start automatically at boot"
}


SetUpNftables(){
  AddDisableUndo nftables DisableNftables

  Disable firewalld ufw || return 1
  ! EnsureInstalled nftables "command -v nft" && return 1

  local config_dir="/etc/nftables"
  AddUndo RestoreNftables
  mkdir -p "$config_dir"
  nft list ruleset > "$config_dir/nft.$TIMESTAMP.bak"
  Log "Backed up the original nftables rules"

  TemplateNftables | nft -f -
  nft add rule inet filter input tcp dport "$SSH_PORT" accept
  Log "Configured nftables rules"

  nft list ruleset | tee "$Nftables_Config" >/dev/null
  systemctl enable --now nftables
  Log "nftables is enabled and will start automatically at boot"
}


ReloadSsh(){
  Log "Checking the SSH configuration"
  if ! sshd -t; then
    Log -e "SSH configuration validation failed"
    return 1
  fi
  Log -w "Reloading the server SSH service next. The changes affect new connections only, and existing connections will stay open"
  systemctl reload "$Ssh_Service"
  Log "SSH service reloaded"
}


Install(){
  AddUndo Uninstall "$@"
  Log "Installing $*"
  if DEBIAN_FRONTEND=noninteractive $Install_Cmd "$@"; then
  Log "Installed $*"
  else
  Log -e "Could not install $*. You may need to install it manually later"
    return 1
  fi
}


### Helpers
AddUndo(){
  echo "$*" >> "$ToUndo"
}


AddDisableUndo(){
  local service=$1 undo=$2
  if systemctl is-active --quiet "$service" && systemctl is-enabled --quiet "$service"; then
    return 0
  fi
  AddUndo "$undo"
}


CreateBackup(){
  local bak="$1.$TIMESTAMP.bak"
  cp "$1" "$bak"
  Typing "Backed up $1 to $bak"
  echo "$bak"
}


CreateTmp(){
  local tmp="$1.$TIMESTAMP.tmp"
  cp "$1" "$tmp"
  echo "$tmp"
}


EnsureInstalled(){
  local package=$1 cmd=${2:-"command -v $1"}
  if ! CheckIfInstalled "$package" "$cmd" && ! Install "$package"; then
    return 1
  fi
}


Disable(){
  local s; for s in "$@"; do
    Log "Disabling $s"
    if ! systemctl cat "$s" >/dev/null 2>&1; then
      Log "Service $s does not exist, so it will be skipped"
      continue
    fi
    if systemctl is-active --quiet "$s"; then
      if systemctl stop "$s"; then
        AddUndo StartService "$s"
        Log "Stopped service $s"
      else
        Log -e "Could not stop service $s"
        return 1
      fi
    fi
    if systemctl is-enabled --quiet "$s"; then
      if systemctl disable "$s"; then
        AddUndo EnableService "$s"
        Log "Disabled service $s"
      else
        Log -e "Could not disable service $s"
        return 1
      fi
    fi
  done
}


UpdateDebianPackages(){
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    dist-upgrade
  apt-get autoremove -y
}


TemplateNftables(){ cat <<EOF
  #!/usr/sbin/nft -f

  flush ruleset

  table inet raw {
    chain prerouting {
      type filter hook prerouting priority raw;

      # Drops new TCP connections that do not have the SYN flag set
      tcp flags & (fin|syn|rst|ack) != syn ct state new drop

      # Drops NULL packets, meaning TCP packets with no flags set
      tcp flags & (fin|syn|rst|psh|ack|urg) == 0 drop

      # Drops TCP packets with all flags set, known as XMAS packets.
      tcp flags & (fin|syn|rst|psh|ack|urg) == (fin|syn|rst|psh|ack|urg) drop
    }
  }


  table inet filter {
    set ipv4_blackroom {
      type ipv4_addr
      flags dynamic, timeout
      timeout 1m
    }

    set ipv6_blackroom {
      type ipv6_addr
      flags dynamic, timeout
      timeout 1m
    }

    chain input {
      type filter hook input priority filter; policy drop;

      # Connection tracking
      ct state {established, related} accept
      ct state invalid drop

      # Local interface
      iifname lo accept
      # Drop external request to local addr to anti-proof
      iifname != lo ip saddr 127.0.0.0/8 drop
      iifname != lo ip6 saddr ::1 drop

      # ICMP/ICMPv6 - essential only
      meta l4proto {icmp, ipv6-icmp} limit rate 20/second accept

      # Blackroom for TCP connections
      meta nfproto ipv4 tcp flags & (fin|syn|rst|ack) == syn limit rate over 50/second add @ipv4_blackroom { ip saddr } drop
      meta nfproto ipv6 tcp flags & (fin|syn|rst|ack) == syn limit rate over 50/second add @ipv6_blackroom { ip6 saddr } drop

      # Blackroom for UDP connections
      meta nfproto ipv4 ip protocol udp limit rate over 1200/second add @ipv4_blackroom { ip saddr } drop
      meta nfproto ipv6 ip6 nexthdr udp limit rate over 1200/second add @ipv6_blackroom { ip6 saddr } drop
    }

    chain forward {
      type filter hook forward priority filter; policy drop;
    }

    chain output {
      type filter hook output priority filter; policy accept;

      # Connection tracking for output
      ct state invalid drop
    }
  }
EOF
}


Main "$@"
