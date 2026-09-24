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
  Log "All restored"

  systemctl restart "$Ssh_Service"
  Log "SSH restarted"

  RemoveSetupFiles "$Script_Dir"
  Log "Removed setup files"
}


InitializeSystemInfo(){
  if ! GetDistroInfo || ! CheckOsSupport; then
    Log -e "Trying to restore unsupported distro: $Os"
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
  Log "Restored sudo file"
}


DeleteUser(){
  userdel -rf "$1"
  groupdel "$1" 2>/dev/null || true
  Log "Deleted user $1"
}


RestoreRootPassword(){
  usermod -p "$1" root
  Log "Restored root password"
}


RestoreAuthorizedKey(){
  local home; home=$(getent passwd "$1" | cut -d: -f6)
  local file; file="$home/.ssh/authorized_keys"
  RestoreBackup "$file"
  Log "Restored $file"
}


RemoveAuthorizedKey(){
  local home; home=$(getent passwd "$1" | cut -d: -f6)
  local file; file="$home/.ssh/authorized_keys"
  rm "$file"
  Log "Removed $file"
}


RestoreHostname(){
  hostnamectl set-hostname "$1"
  RestoreBackup /etc/hostname
  RestoreBackup /etc/hosts
  Log "Restored hostname"
}


RestoreTimezone(){
  timedatectl set-timezone "$1"
  Log "Restored timezone"
}


RestoreSshd(){
  RestoreBackup /etc/ssh/sshd_config
  rm -f "$Sshd_Config"
  Log "Restored sshd config"
}


NotifyPackagesUpdated(){
  Typing "Package update can't be reversed. If the update is cut off during installation stage, please address it immediately. Partial update is dangerous"
}


TakeDownFail2Ban(){
  systemctl disable --now fail2ban
  Log "Fail2Ban stopped and disabled"
}


RestoreUfw(){
  ufw --force disable 2>/dev/null || true
  rm -rf /etc/ufw
  [[ -d /etc/ufw.backup ]] && mv /etc/ufw.backup /etc/ufw
  Log "Restored ufw settings"
}


RestoreFirewalld(){
  rm -rf /etc/firewalld
  mv /etc/firewalld.backup /etc/firewalld
  firewall-cmd --reload
  Log "Restored firewalld settings"
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
    Typing -e "Failed to uninstall $*. You may wanna uninstall manually later"
  fi
}


StartService(){
  systemctl start "$1"
  Log "Re-started $1"
}


EnableService(){
  systemctl enable "$1"
  Log "Re-enabled $1"
}


RemoveSetupFiles(){
  find "$Script_Dir" -mindepth 1 ! -name "$(basename "$Log_File")" ! -name "restore.sh" -delete 2>/dev/null || true
}


### Helper
RestoreBackup(){
  local bak="$1.$TIMESTAMP.bak"
  if [[ ! -f $bak ]]; then
    Log -e "Backup not found: $bak"
    return 1
  fi
  cp "$bak" "$1"
  Log "Restored $1"
}


Main 2>&1 | tee "$Log_File"
