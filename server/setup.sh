#! /bin/bash

set -eu -o pipefail

Script_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/helpers.sh
source "$Script_Dir/helpers.sh" 
# shellcheck source=./common.sh
source "$Script_Dir/common.sh"


Todo="$Script_Dir/todo"
ToUndo="$Script_Dir/toundo"


Main(){
    trap StartRecoveryTimer EXIT INT TERM HUP 

    InitializeSystemInfo
    echo

    if [[ ! -f "$Todo" ]]; then
        Log -e "To-do file '$Todo' not found"
        exit 1
    fi

    local todos; mapfile -t  todos < "$Todo"
    for todo in "${todos[@]}"; do
        $todo || true
        echo
    done

    echo "$SSH_PORT" > "$1"
}


StartRecoveryTimer(){
    Log -w "Nuclear recover timer started. If SSH login is broken, recovery script will automatically execute after 90s and revert everything"
    chmod 777 "$Script_Dir" #Allow any user to delete the folder and stop the timer
    nohup sh -c "sleep 90 && TIMESTAMP=$TIMESTAMP TYPING=$TYPING $Script_Dir/restore.sh $Script_Dir/restore.log" &
    Log "Recovery service is now waiting at PID $(pgrep -f "$Script_Dir/restore.sh")"
    Log "You can find the recovery log at $Script_Dir/restore.log"
}


InitializeSystemInfo(){
    if ! GetDistroInfo || ! CheckOsSupport; then
        Log -e "Trying to set up on unsupported distro: $Os"
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

    Log "Distro command to update packages: $Update_Cmd"
    Log "Distro command to install new package: $Install_Cmd"
}


### User
EnsureSudoInstalledAndEnabled(){
    ! EnsureInstalled sudo || return 1

    local file="/etc/sudoers"
    if ! grep -q "^ *%$Sudo_Group ALL=(ALL:ALL) ALL" "$file"; then
        local tmp; tmp=$(CreateTmp "$file")
        local bak; bak=$(CreateBackup "$file")
        sed -i "s/^# *\(%$Sudo_Group ALL=(ALL:ALL) ALL\)/\1/" "$tmp"
        if visudo -csf "$tmp" >/dev/null 2>&1; then
            AddUndo RestoreSudo
            mv "$tmp" "$file"
        else 
            rm "$tmp" "$bak"
            Log -e "Something went wrong. You need to manually enable sudo by modifying $file"
        fi
    fi
    Log "Ensured that sudo is enabled"
}


AddUser(){
    local name=$1 password=$2 home=$3 sudo=$4 shell=$5
    local args=("useradd" "-U")

    if $home; then
        args+=("-m")
    else
        args+=("-M")
    fi
    if $sudo; then
        args+=("-G" "$Sudo_Group")
    fi
    if [[ -n $shell ]]; then
        local path; path=$(cat /etc/shells | grep -m 1 "/$shell")
        args+=("-s" "$path")
    fi

    args+=("$name")

    AddUndo DeleteUser "$name"
    "${args[@]}"
    Log "Created user '$name'"

    usermod -p "$password" "$name"
    Log "Set password for user '$name'"
}


ChangeRootPassword(){
    AddUndo RestoreRootPassword "$(grep -E "^root:" /etc/shadow | cut -d: -f2)"
    usermod -p "$1" root
    Log "Changed root user's password"
}


AddPublicKeys(){
    local keys=("$Script_Dir"/*.pub)
    local user home record
    for key in "${keys[@]}"; do
        user=$(basename "$key" | cut -d. -f1)
        home=$(getent passwd "$user" | cut -d: -f6)
        record="$home/.ssh/authorized_keys"

        mkdir -p "$home/.ssh"
        if [[ -f $record ]]; then
            CreateBackup "$record"
            AddUndo RestoreAuthorizedKey "$user"
        else
            touch "$record"
        fi
        chmod 600 "$record"
        chown "$user:$user" "$record"

        cat "$key" >> "$record"
        Log "Added public key $key to user $user"
    done
}


### Hostname
ChangeHostname(){
    local old=$1 new=${2:-} 
    AddUndo RestoreHostname "$old"

    local hostname_file="/etc/hostname"
    CreateBackup "$hostname_file"

    hostnamectl set-hostname "$new"
    echo "$new" > "$hostname_file"

    local hosts_file="/etc/hosts"
    CreateBackup "$hosts_file"
    case "$Os" in
        debian|ubuntu)
            echo "127.0.1.1 $new" > /etc/hosts
            echo "::1 $new" > /etc/hosts
            ;;
        almalinux|centos|rocky|fedora)
            echo "127.0.0.1 $new $new.localdomain $new.localdomain4" > /etc/hosts
            echo "::1 $new $new.localdomain $new.localdomain6" > /etc/hosts
            ;;
    esac

    Log "Changed hostname to $new"
    if grep -q "/etc/cloud" /etc/hosts; then
        Typing -w "Your server provider uses Cloud-Init. The server will follows the cloud templates at boot. The hostname change might not persist after reboot. You may wanna manually disable Cloud-Init or change the template"
    fi
}


### Time
ChangeTimezone(){
    AddUndo RestoreTimezone "$1"
    timedatectl set-timezone "$2"
    Log "Timezone changed to $2"
}


### SSH
EnableAndCreateSshdDirectives(){
    AddUndo RestoreSshd

    local config="/etc/ssh/sshd_config" line="Include $Sshd_Directive_Dir/\*\.conf"
    if ! grep -Eq "^[[:space:]]*$line" "$config"; then
        CreateBackup "$config"
        Log "Backup Created"
        if grep -Eq "$line" "$config"; then
            sed -i "s|^[#[:space:]]*$line|$line|" "$config"
        else
            sed -i "1i $line" "$config"
        fi
    fi
    Log "Ensured that original ssh config respects directive folder"

    mkdir -p "$Sshd_Directive_Dir"
    touch "$Sshd_Config"
    Log "Create directive config at $Sshd_Config"
}
     

ChangeSshPort(){
    SSH_PORT=$1
    echo "Port $1" >> "$Sshd_Config"
    Log "Changed port to $1"
}


EnablePublicKeyAuthentication(){
    echo "PubkeyAuthentication yes" >> "$Sshd_Config"
    Log "Enabled public key authentication"
}
    

DisablePasswordLogin(){
    echo "PasswordAuthentication no" >> "$Sshd_Config"
    Log "Disbaled password login"
}
    

DisableRootLogin(){
    echo "PermitRootLogin no" >> "$Sshd_Config"
    Log "Disabled root login"
}
    

### Packages
UpdatePackages(){
    AddUodo NotifyPackagesUpdated
    if $Update_Cmd; then
        Log "${G}All packages successfully updated${I}"
    else
        Log -e "Something went wrong. You need to update manually later"
    fi
}
    

SetUpFail2Ban(){
    case "$Os" in
        debian|ubuntu)
            EnsureInstalled fail2ban 
            ;;
        almalinux|centos|rocky|fedora)
            Typing "For RHEL-based distributions, the default Red Hat Enterprise Linux (RHEL) repository only offers core packages. Fail2Ban is actualluy inside Extra Packages for Enterprise Linux (EPEL) repository. We also need to enable that repository"
            EnsureInstalled epel-release
            EnsureInstalled fail2ban 
            ;;
    esac || return 1

    AddUndo TakeDownFail2Ban
    local default_config="/etc/fail2ban/fail2ban.conf"
    local local_config="/etc/fail2ban/fail2ban.local"
    if [[ ! -f "$local_config" ]]; then
        cp "$default_config" "$local_config"
    fi

    local max_retry; max_retry=$(grep -m1 "^maxretry" $local_config | awk -F= '{print $2}' | tr -d ' ')
    local ban_time; ban_time=$(grep -m1 "^bantime" $local_config | awk -F= '{print $2}' | tr -d ' ')
    local find_time; find_time=$(grep -m1 "^findtime" $local_config | awk -F= '{print $2}' | tr -d ' ')
    Log "Your current configuration bans failed attempts for $ban_time after $max_retry times within $find_time"

    systemctl enable fail2ban
    systemctl start fail2ban
    Log "Fail2Ban is started and now protecting your server"
}


SetUpUfw(){
    Disable firewalld || return 1
    ! EnsureInstalled ufw && return 1

    AddUndo RestoreUfw
    Log "Backing up ufw rules..."
    local dir=/etc/ufw backup=/etc/ufw.backup
    cp -a "$dir" "$backup"
    Log "Backed up at $backup"

    ufw default deny incoming
    ufw default allow outgoing

    ufw allow "$SSH_PORT/tcp"
    Log "Denied all inbound connection unless to SSH port $SSH_PORT. Allowed any outbound connection"

    ufw enable
    Log "ufw enabled as system service and will start at boot"
}


SetUpFirewalld(){
    Disable ufw || return 1
    ! EnsureInstalled firewalld && return 1

    AddUndo RestoreFirewalld
    Log "Backing up firewalld rules..."
    local dir=/etc/firewalld backup=/etc/firewalld.backup
    cp -a "$dir" "$backup"
    Log "Backed up at $backup"

    Log "Setting up firewalld"
    firewall-cmd --permanent --set-default-zone=public
    Log "Set default zone to 'public'"
    firewall-cmd --permanent --zone=public --set-target=default
    Log "Set default target to 'default'"
    local services; services=$(firewall-cmd --zone=public --list-services)
    local -a array; IFS=' ' read -ra array <<< "$services"
    local s; for s in "${array[@]}"; do
            firewall-cmd --permanent --zone=public --remove-service="$s"
            Log "Removed allowed service $s"
    done

    firewall-cmd --permanent --zone=public --add-port="$SSH_PORT/tcp"
    Log "Added port $SSH_PORT"

    firewall-cmd --reload

    systemctl enable --now firewalld
    Log "firewalld enabled as system service and will start at boot"
}


SetUpNftables(){
    Disable firewalld ufw || return 1
    ! EnsureInstalled nft && return 1

    local config_dir="/etc/nftables"
    AddUndo RestoreNftables
    nft list ruleset > "$config_dir/nft.$TIMESTAMP.bak"
    Log "Original nftables rules backed up"
    
    nft -f <"$(TemplateNftables)"
    nft add rule inet filter input tcp dport "$SSH_PORT" accept
    Log "Set up nftables rules"

    nft list ruleset | tee /etc/nftables.conf >/dev/null
    systemctl enable --now nftables
    Log "Nftables enabled as system service and will start at boot"
}


ReloadSsh(){
	Log -w "About to reload server-side SSH service. All changes will take effect for new connections. Don't worry. Established connections aren't affected"
	systemctl reload ssh
	Log "SSH service reloaded"
}


Install(){
    AddUndo Uninstall "$@"
    Log "Installing: $*"
    if $Install_Cmd "$@"; then
        Log "Installed: $*"
    else
        Log -e "Failed to install $*. You may need to install them manually later"
        return 1
    fi
}


### Helpers
AddUndo(){
    echo "$@" >> "$ToUndo"
}


CreateBackup(){
    local bak="$1.$TIMESTAMP.bak"
    cp "$1" "$bak"
    Typing "$1 backed up at $bak"
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


CheckIfInstalled(){
    if $2 >/dev/null 2>&1; then
        Typing "$1 is already installed"
        return 0
    fi
    Typing "$1 is not installed"
    return 1
}


Disable(){
    local s; for s in "$@"; do
        Log "Disabling $s"
        if ! systemctl cat "$s" >/dev/null 2>&1; then
            Log "Service $s doesn't exist. Skipping..."
            continue
        fi
        if systemctl is-active --quiet "$s" && systemctl stop "$s"; then
            AddUndo StartService "$s"
            Log "Stopped $s"
        else
            Log "Failed to stop $s"
            return 1
        fi
        if systemctl is-enabled --quiet "$s" && systemctl disable "$s"; then
            AddUndo EnableService "$s"
            Log "Disabled $s"
        else
            Log "Failed to disable $s"
            return 1
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

            # Connection tracking
            ct state {established, related} accept
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