#! /bin/bash

set -eu -o pipefail

Script_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/helpers.sh
source "$Script_Dir/helpers.sh"
# shellcheck source=./common.sh
source "$Script_Dir/common.sh"

Todo="$Script_Dir/todo"
New_User_Record="$Script_Dir/new_users"
New_Hostname_Record="$Script_Dir/new_hostname"
Automated_Ssh_Comments_Record="$Script_Dir/automated_ssh_comments"
Automated_Ssh_Passwords_Record="$Script_Dir/automated_ssh_passwords"

New_Users=()
Automated_Ssh_Comments=()
Automated_Ssh_Passwords=()
Root_Ssh_Comment=""
Root_Ssh_Password=""
New_Hostname=""

AssertRemoteDependencies(){
  AssertBashVersion 4 3
  AssertCommandsAvailable systemctl tar gzip
}

AssertRemoteDependencies

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
Interactive=$([[ $# -gt 0 ]] && echo false || echo true)
declare -a Flags; declare -A Flag_Indexes; ParseArgs Flags Flag_Indexes "${Args[@]}"
Flag_Index=""


Main(){
  trap CleanUp EXIT INT TERM HUP

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

  ChangeTimezone || true
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

  local new_hostname=${New_Hostname:-$(GetCurrentHostname)}
  printf '%s\n' "$new_hostname" > "$New_Hostname_Record"
  if (( ${#Automated_Ssh_Comments[@]} > 0 )) || [[ -n ${Flag_Indexes[--root]:-} ]]; then
    printf '%s\n' "${Automated_Ssh_Comments[@]}" "$Root_Ssh_Comment" > "$Automated_Ssh_Comments_Record"
    printf '%s\n' "${Automated_Ssh_Passwords[@]}" "$Root_Ssh_Password" > "$Automated_Ssh_Passwords_Record"
  fi
  printf '%s ' "${New_Users[@]}" > "$New_User_Record"
}


CleanUp(){
  local exit_code=$?
  trap - EXIT INT TERM HUP
  Log "Cleaning up the temporary survey files" # May not show up in TTY as SSH is already detached
  RemoveDirectory "$Script_Dir"
  exit "$exit_code"
}


InitializeSystemInfo(){
  Typing "Some features of this script ${Y}work differently across Linux distributions${I} because each distribution has different package managers and default packages"
  Typing "Supported distributions: debian, ubuntu, almalinux, centos, rocky, and fedora"

  if ! GetDistroInfo; then
    Log -e "We could not identify your system as a supported Linux distribution"
    exit 1
  elif ! CheckOsSupport; then
    Log -e "Your Linux distribution ${Y}$Os is not supported${I}"
    exit 1
  else
    Log "Your system '$Os' is ${G}supported${I}"
  fi
}


### User managements
ValidateUsername(){
  local username=$1
  if [[ ! $username =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    Log -e "Username '$username' is invalid. Use lowercase letters, numbers, underscores, and hyphens, and start with a letter or underscore"
    return 1
  elif id "$username" >/dev/null 2>&1; then
    Log -e "User '$username' already exists, so it will be skipped"
    return 1
  elif grep -qE "^$username:" /etc/group; then
    Log -w "A group named '$username' already exists. Linux allows this, but using another name avoids confusion and future conflicts"
    return 1
  fi
}


ValidatePasswordHash(){
  local password_hash=$1
  if [[ $password_hash =~ ^\$(6|y)\$[^$]+(\$[^$]+)+$ ]]; then
    return 0
  fi

  Log -e "Password hash is invalid. Use a SHA-512 hash beginning with \$6\$ or a yescrypt hash beginning with \$y\$"
  return 1
}


AddUsers(){
  Typing "Operating as the root user is ${Y}discouraged${I} because root has full control and a mistake can harm the system. A normal user has fewer privileges and can still perform administrator tasks through 'sudo', which means 'superuser do'"
  Typing "Let's create a ${Y}normal user${I}"

  if [[ -n ${Flag_Indexes[--user]:-} ]]; then
    ValidateFlag --user 2 6
    local value_count; value_count=$(GetFlagValueCount --user)

    local username=${Args[Flag_Index+1]}
    ValidateUsername "$username" || return 1

    local password=${Args[Flag_Index+2]}
    ValidatePasswordHash "$password" || return 1

    local sudo=true
    if (( value_count >= 3 )) && [[ -n ${Args[Flag_Index+3]} ]]; then
      sudo=${Args[Flag_Index+3]}
    fi

    local shell=bash
    if (( value_count >= 4 )) && [[ -n ${Args[Flag_Index+4]} ]]; then
      shell=${Args[Flag_Index+4]}
    fi

    local ssh_key_password=""
    if (( value_count >= 5 )); then
      ssh_key_password=${Args[Flag_Index+5]}
    fi

    local ssh_key_comment=""
    if (( value_count >= 6 )) && [[ -n ${Args[Flag_Index+6]} ]]; then
      ssh_key_comment=${Args[Flag_Index+6]}
    fi

    AddTodo AddUser "$username" "$password" "$sudo" "$shell"
    New_Users+=("$username")
    Automated_Ssh_Comments+=("$ssh_key_comment")
    Automated_Ssh_Passwords+=("$ssh_key_password")
  fi

  DoIfInteractive InteractiveAddUser
}


InteractiveAddUser(){
  local count=1 more="true"
  while $more; do
    local username; username=$(PromptForAnswer "What name should the new user have? Spaces are not allowed, so use underscores instead: ")
    username=${username// /_}
    if ! ValidateUsername "$username"; then
      continue
    fi

    local password; password=$(GetPasswordAndHash)

    local sudo; sudo=$(PromptForYesNo "Add '$username' to ${G}sudo group${I}? (y/n): " && echo true || echo false)

    if (( count == 1)); then
      Typing "What shell should the user use?"
      Typing "A shell is the program that lets you interact with the Linux kernel by typing commands"
      Typing "${G}Bash${I} is the safest and most common choice for most servers"
    fi
    local available; available=$(grep -Ev '^\s*(#|$)' /etc/shells)
    while true; do
      Log "These shells are available on this server: "; cat <<< "$available"
      local shell; shell=$(PromptForAnswer "Which ${G}shell${I} should '$username' use? Press Enter to use bash: " bash)
      if grep -qE "(^|/)$shell$" <<< "$available"; then
        break
      fi
      Log -e "That shell is not available on this server. Let's try again"
    done

    AddTodo AddUser "$username" "$password" "$sudo" "$shell"
    New_Users+=("$username")

    PromptForYesNo "Add ${G}more${I} users? (y/n): " && more=true || more=false
    ((count++))
  done
}


EnsureSudoInstalledAndEnabled(){
  Typing "The ${Y}'sudo' package${I} lets a normal user temporarily use administrator privileges. Some systems do not include it or enable it by default, so let's check it"
  AddTodo EnsureSudoInstalledAndEnabled
}


AddPublicKeys(){
  (( ${#New_Users[@]} == 0 )) && return 0

  Typing "Let's make sure the ${Y}SSH public key${I} for each new user is added to that user. After this, the user can sign in with the matching private key"
  AddTodo AddPublicKeys
}


ChangeRootPassword(){
  [[ $(whoami) != "root" ]] && return 0
  Typing "You may sometimes need to switch to the root user, so you may want to ${Y}change the root password${I} to something easier to remember"
  Typing -w "This is recommended only when password or root login is disabled. Otherwise, a randomly generated password is safer"

  if [[ -n ${Flag_Indexes[--root]:-} ]]; then
    ValidateFlag --root 0 3
    local value_count; value_count=$(GetFlagValueCount --root)
    local password_hash=""
    if (( value_count >= 1 )); then
      password_hash=${Args[Flag_Index+1]}
      if [[ -n $password_hash ]]; then
        ValidatePasswordHash "$password_hash" || exit 1
        AddTodo ChangeRootPassword "$password_hash"
      fi
    fi
    if (( value_count >= 2 )); then
      Root_Ssh_Password=${Args[Flag_Index+2]}
    fi
    if (( value_count >= 3 )); then
      Root_Ssh_Comment=${Args[Flag_Index+3]}
    fi
  fi

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
  Typing "You can ${Y}give the system a name${I}. It helps identify the server and makes it easier to recognize"
  Typing "Current hostname: $(GetCurrentHostname)"

  if [[ -n ${Flag_Indexes[--hostname]:-} ]]; then
    ValidateFlag --hostname 1
    local new=${Args[Flag_Index+1]}
    if ValidateHostname "$new"; then
      AssertCommandsAvailable hostnamectl || return 1
      AddTodo ChangeHostname "$(GetCurrentHostname)" "$new"
      New_Hostname=$new
    else
      return 1
    fi
  fi

  DoIfInteractive InteractiveChangeHostname
}


ValidateHostname(){
  if [[ ! $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    Log -e "Invalid hostname: $1"
    return 1
  fi
}


InteractiveChangeHostname(){
  local new
  while true; do
    new=$(PromptForAnswer "Do you have a hostname in mind? Spaces are not allowed, so use hyphens or underscores. Press Enter to keep the current hostname: ")
    new=${new// /-}
    [[ -z $new ]] && return 0
    if ValidateHostname "$new"; then
      AssertCommandsAvailable hostnamectl || return 1
      AddTodo ChangeHostname "$(GetCurrentHostname)" "$new"
      New_Hostname=$new
      return 0
    fi
    Log "Invalid hostname. Let's try again"
  done
}


### Time
GetCurrentTimezone(){
  timedatectl show | grep Timezone | cut -d= -f2
}


ChangeTimezone(){
  Typing "A correct ${Y}timezone${I} is important for logging and certificate checks, so let's make sure it is set"
  if ! CheckIfInstalled timedatectl "command -v timedatectl" >/dev/null; then
    Typing -e "timedatectl is not installed, so timezone setup will be skipped. You can configure the timezone manually later"
    return 1
  fi
  Log "Current timezone: "; timedatectl status

  if [[ -n ${Flag_Indexes[--timezone]:-} ]]; then
    ValidateFlag --timezone 1
    AddTodo ChangeTimezone "$(GetCurrentTimezone)" "${Args[Flag_Index+1]}"
  fi

  DoIfInteractive InteractiveChangeTimezone
}


InteractiveChangeTimezone(){
  Typing "Available timezones, type Q to exit:"
  timedatectl list-timezones

  local timezone; while true; do
    timezone=$(PromptForAnswer "Which timezone should the server use? Try a partial name such as 'Hong' to find Hong Kong. Press Enter to skip: ")
    if [[ -z $timezone ]]; then
      return 0
    elif timedatectl list-timezones | grep -x "$timezone" >/dev/null; then
      break
    else
      Log -w "$timezone does not appear to be valid. Matching results: "
      if ! timedatectl list-timezones | grep "$timezone"; then
        Log "[No matching timezone found]"
      fi
      Log "Let's try again"
    fi
  done
  AddTodo ChangeTimezone "$(GetCurrentTimezone)" "$timezone"
}


CheckTimeSync(){
  Typing "Correct ${Y}timekeeping${I} is important because the clock can drift. ${Y}Let's check it now${I}"
  if CheckIfTimeSynchronized; then
    Log "${G}The system has synchronized time${I}"
  else
    Log -e "No NTP process was found. You may need to check time synchronization manually later"
  fi
}


### SSH management
EnableAndCreateSshdDirectives(){
  Typing "This is an SSH session, which lets us control the Linux server remotely. It is powerful, so attackers often target it"
  Typing "We can secure SSH by changing which users may connect and how they authenticate. Instead of editing the original configuration directly, we will ${Y}create a directive file${I}. Rules in this file have higher priority"
  AddTodo EnableAndCreateSshdDirectives
}


ChangeSshPort(){
  Typing "Port 22 is the conventional SSH default and receives many automated attacks. It is recommended to ${Y}change the port${I} to a number from ${Y}49152 to 65535${I}"
  Typing "Technically, ports from 0 to 65535 are valid. Ports below 1024 are commonly reserved, such as 53 for DNS and 443 for HTTPS. Ports above 49152 are often used for temporary outbound connections, so the recommended range avoids both groups"
  Typing "Changing the port will not interrupt this connection until the SSH service restarts"
  Typing "Current SSH port: $(cat /etc/ssh/sshd_config | grep -w Port)"

  if [[ -n ${Flag_Indexes[--new-port]:-} ]]; then
    ValidateFlag --new-port 1
    local new_port=${Args[Flag_Index+1]}
    if CheckIfValidPort "$new_port"; then
      AddTodo ChangeSshPort "$new_port"
    else
      Log -e "Invalid SSH port: $new_port"
      exit 1
    fi
  fi

  DoIfInteractive InteractiveChangeSshPort
}


InteractiveChangeSshPort(){
  local port; while true; do
    port=$(PromptForAnswer "What should the new port be? Press Enter to keep the current port: ")
    if [[ -z $port ]]; then
      break
    elif CheckIfValidPort "$port"; then
      AddTodo ChangeSshPort "$port"
      break
    else
      Log -e "That is not a valid port, so let's try again"
    fi
  done
}


EnablePublicKeyAuthentication(){
  Typing "Some systems do not enable ${Y}public key authentication${I} by default, so let's make sure it is enabled"
  AddTodo "EnablePublicKeyAuthentication"
}


DisablePasswordLogin(){
  Typing "It is safer to ${Y}disable password login${I} completely because this reduces brute-force and dictionary attacks"

  SilentValidateFlag --disable-password && AddTodo DisablePasswordLogin

  DoIfInteractive InteractiveDisablePasswordLogin
}


InteractiveDisablePasswordLogin(){
  if PromptForYesNo "Disable it? (Y/n): " Y; then
    AddTodo DisablePasswordLogin
  fi
}


DisableRootLogin(){
  Typing "It is safer to ${Y}disable root login${I}, especially while password login is enabled. You can still become root from a normal user with the command \`su\`"
  Typing "Root login can remain enabled when password login is disabled, but using a normal user is still recommended"

  if SilentValidateFlag --disable-root; then
    AssertNewUserForDisableRoot
    AddTodo DisableRootLogin
  fi

  DoIfInteractive InteractiveDisableRootLogin
}


AssertNewUserForDisableRoot(){
  if (( ${#New_Users[@]} == 0 )); then
    Log -e "--disable-root requires a new user. Add --user with a new login user"
    exit 1
  fi
}


InteractiveDisableRootLogin(){
  if (( ${#New_Users[@]} == 0 )); then
    Typing -w "Disabling root login is not allowed when no new user is created. Skipping..."
    return 0
  fi

  if PromptForYesNo "Disable it? (Y/n): " Y; then
    AddTodo DisableRootLogin
  fi
}


### Packages and firewall
UpdatePackages(){
  Typing "Your server provider may have outdated packages. Updating them is recommended, especially when security fixes are available"

  SilentValidateFlag --update && AddTodo UpdatePackages

  DoIfInteractive InteractiveUpdatePackages
}


InteractiveUpdatePackages(){
  if PromptForYesNo "Update? (y/n): "; then
    AddTodo UpdatePackages
  fi
}


InstallFirewall(){
  Typing "The Internet is a ${Y}hostile${I} place, and attacks happen constantly, including common brute-force and denial-of-service attacks"
  Typing "Linux uses Netfilter to manage network traffic. It filters packets and provides the foundation for tools such as ${G}iptables and nftables${I}"
  Typing "You can use nftables or iptables directly for advanced routing rules, but most people use easier tools built on them. The most common choices are UFW and Firewalld"
  Typing "${G}UFW${I} means Uncomplicated Firewall. It is a simple firewall tool built on iptables and is included with Ubuntu"
  Typing "${G}Firewalld${I} is more powerful but more complex than UFW. It is included with RHEL-based distributions such as Fedora and CentOS"

  SilentValidateFlag --ufw && AddTodo SetUpUfw
  SilentValidateFlag --firewalld && AddTodo SetUpFirewalld
  SilentValidateFlag --nftables && AddTodo SetUpNftables

  DoIfInteractive InteractiveInstallFirewall
}


InteractiveInstallFirewall(){
  if CheckIfInstalled ufw; then
    Log "This system already has UFW installed"
    AddTodo SetUpUfw
  elif CheckIfInstalled firewalld; then
    Log "This system already has Firewalld installed"
    AddTodo SetUpFirewalld
  elif PromptForYesNo "No firewall is installed. UFW is a simple starting point. Install UFW? Choose No to use the default Nftables rules instead: " Y; then
    AddTodo SetUpUfw
  else
    AddTodo SetUpNftables
  fi
}


InstallFail2Ban(){
  Typing "${G}Fail2Ban${I} is another security tool. Unlike a firewall, which inspects network traffic, Fail2Ban scans system logs and blocks visitors with too many failed attempts"
  Typing "It has advanced features such as randomized delays, email notifications, and reports about malicious IP addresses. Some features need manual setup, but the default protection works for many services, including SSH"
  Typing "It is not required, especially when password login is already disabled"

  SilentValidateFlag --fail2ban && AddTodo SetUpFail2Ban

  DoIfInteractive InteractiveInstallFail2Ban
}


InteractiveInstallFail2Ban(){
  if PromptForYesNo "Install Fail2Ban? (Y/n): " Y; then
    AddTodo SetUpFail2Ban
  fi
}


ScheduleReloadSsh(){
  AddTodo ReloadSsh
}


### Helpers
AddTodo(){
  printf '%q ' "$@" >> "$Todo"
  printf '\n' >> "$Todo"
  Log "Todo item added: $*"
}


GetPasswordAndHash(){
  local password retyped
  while true; do
    Typing -n "What password should be used? Your input will be hidden for security: "; read -rs password; echo >&2
    Log -n "Retype the password: "; read -rs retyped; echo >&2
    if [[ -z "$password" ]]; then
      Log -e "Empty password is not allowed"
    elif [[ $password == "$retyped"  ]]; then
      break
    else
      Log -e "Passwords do not match. Let's try again" >&2
    fi
  done
  openssl passwd -6 "$password"
}


SilentValidateFlag(){
  ValidateFlag "$@" >/dev/null
}

ValidateFlag(){
  local flag=$1; local min=${2:-0}; local max=${3:-$min}
  local index; index=${Flag_Indexes[$flag]:-}
  [[ -z $index ]] && return 1

  local value_count; value_count=$(GetFlagValueCount "$flag")
  if [[ $value_count -lt $min ]] || [[ $value_count -gt $max ]]; then
    Log "Invalid $flag argument: Expecting $([[ $min -eq $max ]] && echo "$min" || echo "$min-$max") values, received $value_count"
    exit 1
  fi
  Flag_Index=$index
}


GetFlagValueCount(){
  local flag=$1 index=${Flag_Indexes[$1]:-}
  local order; order=$(IndexArrayValue Flags "$flag")
  local next_flag=${Flags[order+1]:-}
  local next_flag_index; next_flag_index=$([[ -n "$next_flag" ]] && echo "${Flag_Indexes[$next_flag]}" || echo "${#Args[@]}")
  echo $((next_flag_index - index - 1))
}


DoIfInteractive(){
  ! $Interactive && return
  local a; for a in "$@"; do
    $a
  done
}


Main
