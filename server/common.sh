#! /bin/bash

declare -I TIMESTAMP SSH_PORT TYPING

Todo_Filename="todo"
ToUndo_Filename="toundo"

Sshd_Directive_Dir="/etc/ssh/sshd_config.d"
Sshd_Config="$Sshd_Directive_Dir/99-user.$TIMESTAMP.conf"
Ssh_Service="ssh"

Sudo_Group=$(grep -oE '(^|:)(wheel|sudo):' /etc/group | cut -d: -f1 | head -n1)

# Identify_Files=(/etc/passwd /etc/shadow /etc/group /etc/gshadow)


GetDistroInfo(){
    local os_file="/etc/os-release"
    if [[ -f "$os_file" ]]; then
		# shellcheck source=/etc/os-release
        source "$os_file"
        Os=$ID
        case "$Os" in
            almalinux|centos|rocky|fedora)
                Ssh_Service="sshd" ;;
            *)
                Ssh_Service="ssh" ;;
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
