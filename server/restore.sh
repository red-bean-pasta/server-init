#! /bin/bash

set -o pipefail

Script_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/helpers.sh
source "$Script_Dir/helpers.sh"
# shellcheck source=./common.sh
source "$Script_Dir/common.sh"

ToUndo="$Script_Dir/toundo"
Log_File=$1


Main(){
  InitializeSystemInfo || exit 1

  if [[ ! -f "$ToUndo" ]]; then
    Log "Can't find file $ToUndo. Nothing to undo"
    return
  fi

  local undos; mapfile -t  undos < "$ToUndo"
  local len=${#undos[@]}
  for (( i=len-1; i>=0; i-- )); do
    ${undos[i]}
    echo
  done
  Log "All changes were restored"

  systemctl restart "$Ssh_Service"
  Log "SSH service restarted"

  RemoveSetupFiles "$Script_Dir"
  Log "Removed the temporary setup files"
}


InitializeSystemInfo(){
  if ! GetDistroInfo || ! CheckOsSupport; then
    Log -e "Cannot restore an unsupported Linux distribution: $Os"
    return 1
  fi

  case "$Os" in
    debian|ubuntu)
      Uninstall_Cmd="apt-get purge -y" ;;
    almalinux|centos|rocky)
      Uninstall_Cmd="dnf remove -y" ;;
    fedora)
      Uninstall_Cmd="dnf remove -y" ;;
  esac
}


RestoreSudo(){
  RestoreBackup /etc/sudoers
  Log "Restored the sudo configuration"
}


DeleteUser(){
  userdel -rf "$1"
  groupdel "$1" 2>/dev/null || true
  Log "Deleted user '$1'"
}


RestoreRootPassword(){
  usermod -p "$1" root
  Log "Restored the root user's password"
}


RestoreAuthorizedKey(){
  local home; home=$(getent passwd "$1" | cut -d: -f6)
  local file; file="$home/.ssh/authorized_keys"
  RestoreBackup "$file"
  Log "Restored '$file'"
}


RemoveAuthorizedKey(){
  local home; home=$(getent passwd "$1" | cut -d: -f6)
  local file; file="$home/.ssh/authorized_keys"
  rm "$file"
  Log "Removed '$file'"
}


RestoreHostname(){
  hostnamectl set-hostname "$1"
  RestoreBackup /etc/hostname
  RestoreBackup /etc/hosts
  Log "Restored the hostname"
}


RestoreTimezone(){
  timedatectl set-timezone "$1"
  Log "Restored the timezone"
}


RestoreSshd(){
  RestoreBackup /etc/ssh/sshd_config
  rm -f "$Sshd_Config"
  Log "Restored the SSH configuration"
}


NotifyPackagesUpdated(){
  Typing "Package updates cannot be reversed. If an update is interrupted during installation, address it immediately because a partial update can leave the package system in a dangerous state"
}


DisableFail2Ban(){
  systemctl disable --now fail2ban 2>/dev/null || true
  Log "Stopped and disabled Fail2Ban"
}


RestoreFail2Ban(){
  local config="/etc/fail2ban/jail.local"
  local backup="$config.$TIMESTAMP.bak"
  if [[ -f "$backup" ]]; then
    mv "$backup" "$config"
  else
    rm -f "$config"
  fi
  Log "Restored Fail2Ban configuration"
}


DisableUfw(){
  ufw --force disable 2>/dev/null || true
  Log "Disabled UFW"
}


RestoreUfw(){
  if [[ ! -d /etc/ufw.backup ]]; then
    Log -e "UFW backup was not found"
    return 1
  fi
  rm -rf /etc/ufw
  mv /etc/ufw.backup /etc/ufw
  Log "Restored UFW settings"
}


DisableFirewalld(){
  systemctl disable --now firewalld 2>/dev/null || true
  Log "Stopped and disabled firewalld"
}


RestoreFirewalld(){
  if [[ ! -d /etc/firewalld.backup ]]; then
    Log -e "firewalld backup was not found"
    return 1
  fi
  rm -rf /etc/firewalld
  mv /etc/firewalld.backup /etc/firewalld
  firewall-cmd --reload 2>/dev/null || true
  Log "Restored firewalld settings"
}


DisableNftables(){
  systemctl disable --now nftables 2>/dev/null || true
  Log "Stopped and disabled nftables"
}


RestoreNftables(){
  local backup="/etc/nftables/nft.$TIMESTAMP.bak"
  if [[ -f "$backup" ]]; then
    mv "$backup" "$Nftables_Config"
    systemctl reload nftables 2>/dev/null || true
    Log "Restored nftables settings"
  fi
}


Uninstall(){
  if $Uninstall_Cmd "$@"; then
    Log "Uninstalled $*"
  else
    Typing -e "Could not uninstall $*. You may need to uninstall it manually later"
  fi
}


StartService(){
  systemctl start "$1"
  Log "Started service $1 again"
}


EnableService(){
  systemctl enable "$1"
  Log "Enabled service $1 again"
}


RemoveSetupFiles(){
  find "$Script_Dir" -mindepth 1 ! -name "$(basename "$Log_File")" ! -name "restore.sh" -delete 2>/dev/null || true
}


### Helper
RestoreBackup(){
  local bak="$1.$TIMESTAMP.bak"
  if [[ ! -f $bak ]]; then
    Log -e "Backup '$bak' was not found"
    return 1
  fi
  cp "$bak" "$1"
  Log "Restored '$1'"
}


Main 2>&1 | tee "$Log_File"
