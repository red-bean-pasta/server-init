#! /bin/bash

export TIMESTAMP SSH_PORT TYPING

Sshd_Config="/etc/ssh/sshd_config.d/99-user.$TIMESTAMP.conf"
Ssh_Service="ssh"
Nftables_Config="/etc/nftables.conf"

Sudo_Group=$(grep -E '^(wheel|sudo):' /etc/group | cut -d: -f1 | head -n1)

# Identify_Files=(/etc/passwd /etc/shadow /etc/group /etc/gshadow)


GetDistroInfo(){
  local os_file="/etc/os-release"
  if [[ -f "$os_file" ]]; then
    # shellcheck source=/etc/os-release
    source "$os_file"
    Os=$ID
    case "$Os" in
      almalinux|centos|rocky|fedora)
        Ssh_Service="sshd"
        Nftables_Config="/etc/sysconfig/nftables.conf"
        ;;
      *)
        Ssh_Service="ssh"
        Nftables_Config="/etc/nftables.conf"
        ;;
    esac
  else
    Os="Unknown"
    return 1
  fi
}


CheckOsSupport(){
  case "$Os" in
    debian|ubuntu|almalinux|centos|rocky|fedora)
      return 0;;
    *)
      return 1;;
  esac
}
