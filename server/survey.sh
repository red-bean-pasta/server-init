#! /bin/bash

set -eu -o pipefail

Script_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/helpers.sh
source "$Script_Dir/helpers.sh" 
# shellcheck source=./common.sh
source "$Script_Dir/common.sh"


Todo="$Script_Dir/todo"

New_Users=()


ParseArgs(){
    local -n _flags=$1 _indexes=$2; shift 2
    local i=0; local arg; for arg in "$@"; do
        if [[ $arg == --* ]]; then
            _flags+=("$arg")
            _indexes["$arg"]=$i
        fi
        ((++i))
    done
}
Args=("$@")
New_User_Record=$1
Interactive=$([[ $# -gt 1 ]] && echo false || echo true)
declare -a Flags; declare -A Flag_Indexes; ParseArgs Flags Flag_Indexes "${Args[@]}"


Main(){
    trap CleanUp INT TERM HUP 

    InitializeSystemInfo
    echo

    EnsureSudoInstalledAndEnabled
    echo
    AddUsers
    echo
    AddPublicKeys
    echo
    
    ChangeRootPassword
    echo

    ChangeHostname
    echo

    ChangeTimezone
    echo
    CheckTimeSync
    echo

    EnableAndCreateSshdDirectives
    echo
    EnablePublicKeyAuthentication
    echo
    ChangeSshPort
    echo
    DisablePasswordLogin
    echo
    DisableRootLogin
    echo

    UpdatePackages
    echo
    InstallFirewall
    echo
    InstallFail2Ban
    echo

    ScheduleReloadSsh
    
    echo "${New_Users[@]}" > "$New_User_Record"
}


CleanUp(){
    Log "Cleaning up folder on server..." # May not show up in TTY as SSH is already detached
    RemoveDirectory "$Script_Dir"
}


InitializeSystemInfo(){
    Typing "Some features of this script ${Y}aren't applicable to all Linux distributions${I} as they have different package manager and default packages"
    Typing "Supported distros: debian, ubuntu, almalinux, centos, rocky and fedora"

    if ! GetDistroInfo; then
        Typing -e "Unfortunately, your system appears to be a ${Y}legacy${I} distro that we can't identify"
        exit 1
    elif ! CheckOsSupport; then
        Typing -e "Unfortunately, your distro is ${Y}not supported${I}: $Os"
        exit 1
    else
        Typing "Your system '$Os' is ${G}supported${I}"
    fi
}


### User managements
AddUsers(){
    Typing "It's often ${Y}discouraged to operate as root user${I}. Root user has the utmost power and can easily cause unintentional harm. Meanwhile, normal user is intentionally restricted, effectively protecting the system. Normal user can still gain admin priviledge with the help of 'sudo', which means 'superuser do'"
    Typing "That being said, let's ${Y}create some normal users!${I}"

    local index; if index=$(ValidateFlag --user 5); then
        AddTodo AddUser "${Args[@]:(($index+1)):5}" # [username] [password_hash] [if_create_home] [if_sudo_group] [shell] 
        New_Users+=("${Args[index+1]}")
    fi

    if $Interactive || [[ -n ${Flag_Indexes[--more-users]:-} ]]; then
        InteractiveAddUser
    fi
}


InteractiveAddUser(){
    local count=1 more="true" 
    while $more; do
        local username; username=$(PromptForAnswer "Give the uew user a name (blank space not allowed, use underscore instead): ")
        username=${username// /_}
        if id "$username" >/dev/null 2>&1; then
            Typing -e "User '$username' already exists. Skipping..."
            continue
        elif grep -qE "^$username:" /etc/group; then
            Typing -w "There is already an group with the same name '$username'. While this is technically allowed, to avoid future confusion and conflicts, let's try some other names"
            continue
        fi
        
        local password; password=$(GetPasswordAndHash)

        Typing "A home is where the user stores its own files and install their own applications without affecting others. Users normally have their own homes"
        local home; home=$(PromptForYesNo "Give '$username' a ${G}home${I}? (Y/n): " Y && echo true || echo false)

        local sudo; sudo=$(PromptForYesNo "Add '$username' to ${G}sudo group${I}? (y/n):  " && echo true || echo false)

        if (( count == 1)); then
            Typing "What'd would be the user's shell?"
            Typing "Shells are essentially interfaces allowing you to interact with the kernel with command lines, like a shell wrapper, hence the name."
            Typing "There are many shells: dash, bash, zsh, ksh, fish... Different shells may serve different purposes, some ideal to terminal sessions, some optimized for desktop environment, while some for special use cases, like git-shell"
            Typing "Shells are not always compatible, and one shell's script may not work on another"
            Typing "${G}Bash${I} is the safest and commonest choice for most servers"
        fi
        local available; available=$(grep -Ev '^\s*(#|$)' <(cat /etc/shells))
        while true; do 
            Typing "Here are the available ones: "; cat <<< "$available"
            local shell; shell=$(PromptForAnswer "What'd would the ${G}shell${I} for '$username'? [Default to bash]: " bash)
            if cat <<< "$available" | grep -q "/$shell" >/dev/null 2>&1; then
                break
            fi
            Typing -e "Unknown shell. Let's try again"
        done

        AddTodo AddUser "$username" "$password" "$home" "$sudo" "$shell" 
        New_Users+=("$username")

        PromptForYesNo "Add ${G}more${I} users? (y/n): " && more=true || more=false
        ((count++))
    done
}


EnsureSudoInstalledAndEnabled(){
    Typing "${Y}'sudo' package${I} allows normal user to temporarily borrow root privilege. Some system may not ship with it installed or enabled by default. Let's make sure that's not the case"
    AddTodo EnsureSudoInstalledAndEnabled
}


AddPublicKeys(){
    Typing "Let's also make sure that ${Y}SSH public keys${I} found at $Script_Dir will be ${Y}added${I} to corresponding user. Once added, one can then sign in as that user providing matching private key"
    AddTodo AddPublicKeys
}


ChangeRootPassword(){
    [[ $(whoami) != "root" ]] && return 0
    Typing "One may sometimes find the need to switch to root user and may wanna ${Y}change the root password${I} to something easier to memorize"
    Typing -w "This is only recommended if password or root login is disabled, else it's much safer to use the password randomly generated"

    local index; index=$(ValidateFlag --root-password 1) && AddTodo ChangeRootPassword "${Args[index+1]}"

    DoIfInteractive InteractiveChangeRootPassword
}


InteractiveChangeRootPassword(){
    if PromptForYesNo "Change root password? (y/N): " N; then
        AddTodo ChangeRootPassword "$(GetPasswordAndHash)"
    fi
}


### Hostname
GetCurrentHostname(){
    cat /etc/hostname
}


ChangeHostname(){
    Typing "You can ${Y}give the system a name${I}. It may help with identification. It also looks nicer"
    Typing "Your current hostname is $(GetCurrentHostname)"
    
    local index; index=$(ValidateFlag --hostname 1) && AddTodo ChangeHostname "$(GetCurrentHostname)" "${Args[index+1]}"

    DoIfInteractive InteractiveChangeHostname
}


InteractiveChangeHostname(){
    local new; new=$(PromptForAnswer "Have a better name in mind (Blank space is not allowed and underscore should be used. Return to skip changing)?: ")
    new=${new// /_}
    AddTodo ChangeHostname "$(GetCurrentHostname)" "$new"
}


### Time
GetCurrentTimezone(){
    timedatectl show | grep Timezone | cut -d= -f2
}


ChangeTimezone(){
    Typing "It's important to ${Y}have the right timezone${I} as many services depends on it, such as logging and certificate verification"
    if ! CheckIfInstalled timedatectl "command -v timedatectl" >/dev/null; then
        Typing -e "timedatectl doesn't seem to be installed. Skipping setting timezone for now. You can configure it manually later"
        return 1
    fi
    Typing "Your current timezone status: "; timedatectl status

    local index; index=$(ValidateFlag --timezone 1) && AddTodo ChangeTimezone "$(GetCurrentTimezone)" "${Args[index+1]}"

    DoIfInteractive InteractiveChangeTimezone
}


InteractiveChangeTimezone(){
    Typing "Available timezones (Type Q to exit):"
    timedatectl list-timezones
    
    local timezone; while true; do
        timezone=$(PromptForAnswer "Change the timezone? You can try fuzzy search first, like type 'Hong' to find the timezone for HongKong. Return to skip: ")
        if [[ -z $timezone ]]; then
            return 0
        elif timedatectl list-timezones | grep -x "$timezone" >/dev/null; then
            break
        else
            Typing -w "$timezone doesn't appear to be a valid timezone. Filter result: "
            if ! timedatectl list-timezones | grep "$timezone"; then
                Log "[No candidate found]"
            fi
            Typing "Let's try again"
        fi
    done
    AddTodo ChangeTimezone "$(GetCurrentTimezone)" "$timezone"
}


CheckTimeSync(){
    Typing "It's also important to have correct ${Y}timekeeping${I} so it doesn't drift away. ${Y}Let's have a fast check${I}..."
    if timedatectl show | grep -E 'NTPSynchronized|TimeUSec' || pgrep 'chronyd|ntpd|openntpd'; then
        Typing "${G}The system has timekeeping set up${I}"
    else
        Typing -e "No NTP process found. You may wanna troubleshoot manually later"
    fi
}
    

### SSH management 
EnableAndCreateSshdDirectives(){
    Typing "We are now at a Secure Shell session, often more known with abbreviated name SSH. It allows remote control over a Linux system, like what we are doing now! Needless to say, it's super powerful and easily the target of malicious attackers"
    Typing "We can secure it by modifying its configuration like the who to accept and how to authenticate. Instead of modifying directly the original config file, We can take a less invasive approach and ${Y}create a directive file${I}. Rules in directive file takes higher priority"
    AddTodo EnableAndCreateSshdDirectives
}


ChangeSshPort(){
    Typing "22 is by convention the default SSH port. It therefore expects the most attacks. It's advised to ${Y}change to port${I} to a number between ${Y}49152 and 65535${I}"
    Typing "(Technically any port between 0 and 65535 will do, but ports under 1024 are by convention reserved like 53 for DNS queries and 443 for HTTPS traffic, while numbers between 1024 and 49152 are also registered just less well-known. To avoid conflict in the future, it's best to just leave them alone)"
    Typing "Don't worry. Changing the port won't interrupt this connection until SSH servic is restarted"
    Typing "Current: $(cat /etc/ssh/sshd_config | grep -w Port)"

    local index; index=$(ValidateFlag --new-port 1) && AddTodo ChangeSshPort "${Args[index+1]}"

    DoIfInteractive InteractiveChangeSshPort
}


InteractiveChangeSshPort(){
    local port; while true; do
        port=$(PromptForAnswer "Change it to (Return to skip)?: ")
        if [[ -z $port ]]; then
            break
        elif [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ]; then
            AddTodo ChangeSshPort "$port"
            break
        else 
            Typing -e "Invalid input. Let's try again"
        fi
    done
}


EnablePublicKeyAuthentication(){
    Typing "Some system might not ${Y}enable public key authentication${I} by default. Let's make sure it's enabled"
    AddTodo "EnablePublicKeyAuthentication"
}
    

DisablePasswordLogin(){
    Typing "It's suggested to ${Y}disable password login${I} completely to minimize the risk of brute-force or dictionary attack"
    
    ValidateFlag --disable-password && AddTodo DisablePasswordLogin

    DoIfInteractive InteractiveDisablePasswordLogin
}
    

InteractiveDisablePasswordLogin(){
    PromptForYesNo "Disable it? (Y/n): " Y && AddTodo DisablePasswordLogin
}


DisableRootLogin(){
    Typing "It's suggested to ${Y}disable root login${I}, especially if password auth haven't been disabled. You can still switch to root user from normal user with command \`su\`"
    Typing "Technically you can keep root login if password login is disabled, but since operating as normal users is advised, so..."

    ValidateFlag --disable-root && AddTodo DisableRootLogin

    DoIfInteractive InteractiveDisableRootLogin
}


InteractiveDisableRootLogin(){
    PromptForYesNo "Disable it? (Y/n): " Y && AddTodo DisablePasswordLogin
}
    

### Packages and firewall
UpdatePackages(){
    Typing "The system from your server provider may often be less up-to-date. It's recommended to ${Y}update all of them${I} especially if there are security patches"
    
    ValidateFlag --update && AddTodo UpdatePackages

    DoIfInteractive InteractiveUpdatePackages
}


InteractiveUpdatePackages(){
    PromptForYesNo "Update? (y/n): " && AddTodo UpdatePackages
}
    

InstallFirewall(){
    Typing "The Internet is a ${Y}hostile${I} place. Attacks happen constantly, like the most common brute-force attack or DDOs attack" 
    Typing "Linux uses Netfilter to manage network operations. Like the name suggests, it can filter packets to help protecting your server. Tools like ${G}iptables and nftables${I} are built on it offering interfaces for management"
    Typing "You can use nftables or iptables directly for advanced routing rules. But in most cases, there are much more user-friendly tools built on them. The most common ones are UFW and Firewalld"
    Typing "${G}UFW${I} stands for Uncomplicated Firewall. It's a simple yet user-friendly firewall tool built on iptables. It's shipped with Ubuntu"
    Typing "${G}Firewalld${I} is powerful yet more complex comparing to UFW. It's built-in in RHEL-based distros like Fedora or CentOS"

    ValidateFlag --ufw && AddTodo SetUpUfw
    ValidateFlag --firewalld && AddTodo SetUpFirewalld
    ValidateFlag --nftables && AddTodo SetUpNftables

    DoIfInteractive InteractiveInstallFirewall
}


InteractiveInstallFirewall(){
    if CheckIfInstalled ufw; then
        Typing "Your system is shipped with UFW"
        AddTodo SetUpUfw
    elif CheckIfInstalled firewalld; then
        Typing "Your system is shipped with Firewalld"
        AddTodo SetUpFirewalld
    elif PromptForYesNo "Your system doesn't have any firewall. You can start with UFW for now. Do you wish to install UFW. Don't worry if you don't as a default Nftables rule will be applied. Your answer? (Y\n): " Y; then
        AddTodo SetUpUfw
    else
        AddTodo SetUpNftables
    fi
}
    

InstallFail2Ban(){
    Typing "${Y}Fail2Ban${I} is another tool that protects servers. Unlike firewall tools who inspects raw networks packets, Fail2Ban scans the system log and bans visitors with too many failures"
    Typing "It has rich and powerful features like increment fail time randomly, send mails and report malicious IP. Many of them require manual setup, but it still works out of box with default protection over many protocols, including SSH"
    Typing "However, it's not strictly neccessary, especially if password auth is already disabled"

    ValidateFlag --fail2ban && AddTodo SetUpFail2Ban

    DoIfInteractive InteractiveInstallFail2Ban
}


InteractiveInstallFail2Ban(){
    PromptForYesNo "Install Fail2Ban? (Y/n): " Y && AddTodo SetUpFail2Ban
}


ScheduleReloadSsh(){
    AddTodo ReloadSsh
}


### Helpers
AddTodo(){
    echo "$@" >> "$Todo"
    Log "Todo item added: $*"
}


GetPasswordAndHash(){
    local password retyped
    while true; do
        Typing -n "What would be password (your input won't show up for security reason)?: "; read -rs password
        Typing -n "Retype the password: "; read -rs retyped
        if [[ -z "$password" ]]; then
            Typing -e "Empty password is not allowed"
        elif [[ $password == "$retyped"  ]]; then
            break
        else
            Typing -e "Passowrd not match. Let's try again" >&2
        fi
    done
    openssl passwd -6 "$password"
}


ValidateFlag(){
    local flag=$1; local min=${2:-0}; local max=${3:-$min}
    local index; index=${Flag_Indexes[$flag]:-}
    [[ -z $index ]] && return 1

    local order; order=$(IndexArrayValue Flags "$flag")
    local next_flag=${Flags[order+1]:-}
    local next_flag_index; next_flag_index=$([[ -n "$next_flag" ]] && echo "${Flag_Indexes[$next_flag]}" || echo "${#Args[@]}" )
    local value_count=$((next_flag_index - index - 1))
    if [[ $value_count -lt $min ]] || [[ $value_count -gt $max ]]; then
        Log "Invalid $flag argument: Expecting $([[ $min -eq $max ]] && echo "$min" || echo "$min-$max") values, received $value_count" 
        exit 1
    fi
    echo "$index"
}


DoIfInteractive(){
    ! $Interactive && return
    local a; for a in "$@"; do
        $a
    done
}


Main