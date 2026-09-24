#! /bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/common.sh"

LOG_PATH="$SCRIPT_DIR/log"
USER_LOG_PATH="$SCRIPT_DIR/user.log"

SSHD_CONFIG_PATH="/etc/ssh/sshd_config"
SSHD_BAK_PATH="$SSHD_CONFIG_PATH.bak"

ROOT_KEYS_BACKUP="$SCRIPT_DIR/root_authorized_keys"

UNINSTALL_CMD=""

Main(){
    # Exit once error is encountered rather than continuing
    set -e

    CheckIfSetupAnything

    CheckIfSudo

    InitializeInformation && echo && ( FinishUpdation && echo ; UninstallFail2Ban && echo ; UninstallUfw && echo ; UninstallOrRestoreNftables && echo )
    
    RestoreHostName
    echo

    RestoreSudoers
    echo

    RemoveUsers && echo && RemoveOrRestoreRootKey
    echo

    RecoverSshConfig
    echo

    InformAboutRootPassword
}

CheckIfSetupAnything(){
    if [[ ! -f "$LOG_PATH" ]]; then
        Typing "Set-up process seemed to be terminated early. Nothing to restore at server side. ${G}Skipping${I}..."
        exit 0
    fi
}

InitializeInformation(){
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS=$ID
    else 
        OS="unsupported"
        Typing "Your system is: unkown."
        return 1
    fi

    case "$OS" in
        almalinux|centos|rocky|fedora)
            UNINSTALL_CMD="dnf remove -y"
            ;;
        debian|ubuntu)
            UNINSTALL_CMD="apt-get purge -y"
            ;;
        *)
            Typing "Your system is: $OS"
            return 1
            ;;
    esac

    Typing "The command to uninstall packages on your system $OS is: $UNINSTALL_CMD"
}

FinishUpdation(){
    if CheckLog "$UPDATE_LOG" && ! CheckLog "$UPDATE_FINISHED_LOG" ; then
        Typing "Things seemed to go wrong during packages updation. While updation is irreversible, partial updation is extremely dangerous, so we have to finish what we started."
        Typing "Finishing packages updating..."
        eval "$UPDATE_CMD"
        Log "$UPDATE_FINISHED_LOG"
        Typing "${G}All packages successfully updated.${I}"
        return 0
    elif ! CheckLog "$UPDATE_LOG"; then
        Typing "Packages weren't updated. ${G}Skipping${I}..."
        return 0
    elif CheckLog "$UPDATE_FINISHED_LOG"; then
        Typing "${Y}Packages updated${I}. It ${Y}can't be reversed${I}, but it won't do you any harm."
        return 0
    fi
}  

UninstallFail2Ban(){
    if ! CheckLog "$FAIL2BAN_LOG"; then
        Typing "Fail2Ban wasn't installed. ${G}Skipping${I}..."
        return 0
    fi

    eval "$UNINSTALL_CMD fail2ban"

    rm -rf /etc/fail2ban
    rm -rf /var/log/fail2ban.log /var/lib/fail2ban

    echo "${G}Fail2Ban uninstalled${I} along with its log and config files. "
}

UninstallUfw(){
    if ! CheckLog "$UFW_LOG"; then
        Typing "ufw wasn't installed. ${G}Skipping${I}..."
        return 0
    fi

    eval "$UNINSTALL_CMD ufw"

    Typing "${G}ufw uninstalled.${I}"
}

UninstallOrRestoreNftables(){
    if CheckLog "$NFTABLES_LOG"; then
        eval "$UNINSTALL_CMD nftables"
        Typing "${G}Nftables uninstalled${I}."
    elif CheckLog "$NFTABLES_RULE_LOG"; then
        nft flush ruleset
        nft -f "$SCRIPT_DIR/backup.nft"
        Typing "${G}Nftables ruleset recovered${I}."
    else
        Typing "Nftables wansn't configured. ${G}Skipping${I}"
    fi
}

RestoreHostName(){
    if ! CheckLog "$HOSTNAME_LOG"; then
        Typing "Host name wansn't changed. ${G}Sikpping...${I}"
        return 0
    fi

    local original_hostname
    original_hostname=$(grep -F "$HOSTNAME_LOG" "$LOG_PATH" | awk '{print $NF}')

    hostnamectl set-hostname "$original_hostname"
    Typing "Original hostname ${G}restored${I}."

    if ! CheckLog "$HOSTS_FILE_MODIFIED_LOG"; then
        Typing "File /etc/hosts wasn't changed. ${G}Sikpping...${I}"
    else
        mv /etc/hosts.bak /etc/hosts
        Typing "${G}File /etc/hosts restored.${I}"
    fi
}

RestoreSudoers(){
    if ! CheckLog "$SUDOERS_LOG"; then
        Typing "Sudoers file wasn't modified. ${G}Skipping${I}."
        return 0
    fi

    mv /etc/sudoers.bak /etc/sudoers
    Typing "${G}Restored original settings about sudo group.${I}"
}

RemoveUsers(){
    if [[ ! -f "$USER_LOG_PATH" ]]; then
        Typing "No new user was created. ${G}Skipping${I}"
        return 0
    fi

    local user
    local users_array
    mapfile -t users_array < <(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "$USER_LOG_PATH" | tr -s ' ' '\n' | grep -v '^$')
    
    for user in "${users_array[@]}"; do
        pkill -u "$user"
        userdel -r "$user"
        echo "Removed user $user."
    done

    Typing "${G}All created users removed.${I}"
    Typing "Remaining user:"
    ls /home
    Typing "You may see some users that weren't created by this script, or some that can't be removed because their home directory holds files or folders of others. You may need to remove them manually."
}

RemoveOrRestoreRootKey(){
    Typing "When the user is removed, their public keys should also be ${G}removed${I} ."

    if ! CheckLog "$PUBLIC_KEY_LOG"; then
        Typing "All key generated from script should be removed."
        return 0
    fi

    rm "$HOME/.ssh/authorized_keys"

    [[ -f "$ROOT_KEYS_BACKUP" ]] && mv "$ROOT_KEYS_BACKUP" "$HOME/.ssh/authorized_keys"

    Typing "${G}Root user's key generated from script removed. Other public keys aren't harmed, if there're any.${I}"
}

RecoverSshConfig(){
    if ! CheckLog "$SSH_BACKUP_LOG"; then
        Typing "SSH config wasn't changed. ${G}Skipping${I}"
        return 0
    fi

    local current_ssh_port
    current_ssh_port=$(grep -E "^[[:space:]]*#?[[:space:]]*Port" $SSHD_CONFIG_PATH | awk '{print $2}')
    local original_ssh_port
    original_ssh_port=$(grep -E "^[[:space:]]*#?[[:space:]]*Port" $SSHD_BAK_PATH | awk '{print $2}')

    if systemctl status firewalld > /dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="$current_ssh_port/tcp"
        firewall-cmd --permanent --zone=public --add-port="$original_ssh_port/tcp"
        firewall-cmd --reload
    fi

    if sestatus > /dev/null 2>&1; then
        semanage port -m -t ssh_port_t -p tcp "$original_ssh_port"
    fi

    if ufw --version > /dev/null 2>&1; then 
        ufw deny "$current_ssh_port"
        ufw allow "$original_ssh_port/tcp"
    fi

    Typing "Firewall rules restored."

    mv "$SSHD_BAK_PATH" "$SSHD_CONFIG_PATH"
    Typing "SSH config restored. "
}

InformAboutRootPassword(){
    if CheckLog "$ROOT_PASSWORD_LOG"; then
        Typing "You seem to have ${Y}changed the root user's password${I}. We ${Y}can't recover that${I}, but you can now in your server as root user using the changed password."
    fi
}

Main