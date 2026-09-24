#! /bin/bash

set -eu -o pipefail

Script_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/helpers.sh
source "$Script_Dir/helpers.sh"
# shellcheck source=./common.sh
source "$Script_Dir/common.sh"


Todo="$Script_Dir/todo"
New_Hostname_Record="$Script_Dir/new_hostname"
New_User_Comments_Record="$Script_Dir/new_user_comment"

New_Users=()
New_User_Comments=()
New_User_Automated=()
New_Hostname=""


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
  local planned_hostname=${New_Hostname:-$(GetCurrentHostname)}
  local i
  for ((i = 0; i < ${#New_Users[@]}; i += 1)); do
    if [[ ${New_User_Automated[i]} == true && -z ${New_User_Comments[i]} ]]; then
      New_User_Comments[i]="${New_Users[i]}:$planned_hostname"
    fi
  done
  printf '%s\n' "$planned_hostname" > "$New_Hostname_Record"
  printf '%s\n' "${New_User_Comments[@]}" > "$New_User_Comments_Record"
  echo "${New_Users[@]}" > "$New_User_Record"
}


CleanUp(){
  local exit_code=$?
  Log "Cleaning up folder on server..." # May not show up in TTY as SSH is already detached
  RemoveDirectory "$Script_Dir"
  exit "$exit_code"
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
ValidateUsername(){
  local username=$1
  if [[ ! $username =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    Typing -e "Invalid username '$username'. Use lowercase letters, numbers, underscore, and hyphen; start with a letter or underscore"
    return 1
  elif id "$username" >/dev/null 2>&1; then
    Typing -e "User '$username' already exists. Skipping..."
    return 1
  elif grep -qE "^$username:" /etc/group; then
    Typing -w "There is already an group with the same name '$username'. While this is technically allowed, to avoid future confusion and conflicts, let's try some other names"
    return 1
  fi
}


AddUsers(){
  Typing "It's often ${Y}discouraged to operate as root user${I}. Root user has the utmost power and can easily cause unintentional harm. Meanwhile, normal user is intentionally restricted, effectively protecting the system. Normal user can still gain admin priviledge with the help of 'sudo', which means 'superuser do'"
  Typing "That being said, let's ${Y}create some normal users!${I}"

  local index; if index=$(ValidateFlag --user 2 5); then
    local username=${Args[index+1]}
    ValidateUsername "$username" || return 1
    local value_count; value_count=$(GetFlagValueCount --user)
    local password=${Args[index+2]} comment="" sudo=true shell=bash
    if (( value_count >= 3 )) && [[ -n ${Args[index+3]} ]]; then
      comment=${Args[index+3]}
    fi
    if (( value_count >= 4 )) && [[ -n ${Args[index+4]} ]]; then
      sudo=${Args[index+4]}
    fi
    if (( value_count >= 5 )) && [[ -n ${Args[index+5]} ]]; then
      shell=${Args[index+5]}
    fi
    AddTodo AddUser "$username" "$password" "$sudo" "$shell"
    New_Users+=("$username")
    New_User_Comments+=("$comment")
    New_User_Automated+=(true)
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
    if ! ValidateUsername "$username"; then
      continue
    fi

    local password; password=$(GetPasswordAndHash)

    local sudo; sudo=$(PromptForYesNo "Add '$username' to ${G}sudo group${I}? (y/n):  " && echo true || echo false)

    if (( count == 1)); then
      Typing "What'd would be the user's shell?"
      Typing "Shells are essentially interfaces allowing you to interact with the kernel with command lines, like a shell wrapper, hence the name."
      Typing "There are many shells: dash, bash, zsh, ksh, fish... Different shells may serve different purposes, some ideal to terminal sessions, some optimized for desktop environment, while some for special use cases, like git-shell"
      Typing "Shells are not always compatible, and one shell's script may not work on another"
      Typing "${G}Bash${I} is the safest and commonest choice for most servers"
    fi
    local available; available=$(grep -Ev '^\s*(#|$)' /etc/shells)
    while true; do
      Typing "Here are the available ones: "; cat <<< "$available"
      local shell; shell=$(PromptForAnswer "What'd would the ${G}shell${I} for '$username'? [Default to bash]: " bash)
      if grep -qE "(^|/)$shell$" <<< "$available"; then
        break
      fi
      Typing -e "Unknown shell. Let's try again"
    done

    AddTodo AddUser "$username" "$password" "$sudo" "$shell"
    New_Users+=("$username")
    New_User_Comments+=("")
    New_User_Automated+=(false)

    PromptForYesNo "Add ${G}more${I} users? (y/n): " && more=true || more=false
    ((count++))
  done
}


EnsureSudoInstalledAndEnabled(){
  Typing "${Y}'sudo' package${I} allows normal user to temporarily borrow root privilege. Some system may not ship with it installed or enabled by default. Let's make sure that's not the case"
  AddTodo EnsureSudoInstalledAndEnabled
}


AddPublicKeys(){
  (( ${#New_Users[@]} == 0 )) && return 0

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

  local index; if index=$(ValidateFlag --hostname 1); then
    if ValidateHostname "${Args[index+1]}"; then
      AddTodo ChangeHostname "$(GetCurrentHostname)" "${Args[index+1]}"
      New_Hostname=${Args[index+1]}
    else
      return 1
    fi
  fi

  DoIfInteractive InteractiveChangeHostname
}


ValidateHostname(){
  if [[ ! $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    Typing -e "Invalid hostname: $1"
    return 1
  fi
}


InteractiveChangeHostname(){
  local new
  while true; do
    new=$(PromptForAnswer "Have a better name in mind (Blank space is not allowed and hyphen/underscore should be used. Return to skip changing)?: ")
    new=${new// /-}
    [[ -z $new ]] && return 0
    if ValidateHostname "$new"; then
      AddTodo ChangeHostname "$(GetCurrentHostname)" "$new"
      New_Hostname=$new
      return 0
    fi
    Typing "Invalid hostname. Let's try again"
  done
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
  if CheckIfTimeSynchronized; then
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
  Typing "(Technically any port between 0 and 65535 will do, but ports under 1024 are by convention reserved like 53 for DNS queries and 443 for HTTPS traffic, while numbers above 49152 commonly used for ephemeral outbound connections and better avoided)"
  Typing "Don't worry. Changing the port won't interrupt this connection until SSH servic is restarted"
  Typing "Current: $(cat /etc/ssh/sshd_config | grep -w Port)"

  local index; if index=$(ValidateFlag --new-port 1); then
    local new_port=${Args[index+1]}
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
    port=$(PromptForAnswer "Change it to (Return to skip)?: ")
    if [[ -z $port ]]; then
      break
    elif CheckIfValidPort "$port"; then
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

  SilentValidateFlag --disable-password && AddTodo DisablePasswordLogin

  DoIfInteractive InteractiveDisablePasswordLogin
}


InteractiveDisablePasswordLogin(){
  if PromptForYesNo "Disable it? (Y/n): " Y; then
    AddTodo DisablePasswordLogin
  fi
}


DisableRootLogin(){
  Typing "It's suggested to ${Y}disable root login${I}, especially if password auth haven't been disabled. You can still switch to root user from normal user with command \`su\`"
  Typing "Technically you can keep root login if password login is disabled, but since operating as normal users is advised, so..."

  SilentValidateFlag --disable-root && AddTodo DisableRootLogin

  DoIfInteractive InteractiveDisableRootLogin
}


InteractiveDisableRootLogin(){
  if PromptForYesNo "Disable it? (Y/n): " Y; then
    AddTodo DisableRootLogin
  fi
}


### Packages and firewall
UpdatePackages(){
  Typing "The system from your server provider may often be less up-to-date. It's recommended to ${Y}update all of them${I} especially if there are security patches"

  SilentValidateFlag --update && AddTodo UpdatePackages

  DoIfInteractive InteractiveUpdatePackages
}


InteractiveUpdatePackages(){
  if PromptForYesNo "Update? (y/n): "; then
    AddTodo UpdatePackages
  fi
}


InstallFirewall(){
  Typing "The Internet is a ${Y}hostile${I} place. Attacks happen constantly, like the most common brute-force attack or DDOs attack"
  Typing "Linux uses Netfilter to manage network operations. Like the name suggests, it can filter packets to help protecting your server. Tools like ${G}iptables and nftables${I} are built on it offering interfaces for management"
  Typing "You can use nftables or iptables directly for advanced routing rules. But in most cases, there are much more user-friendly tools built on them. The most common ones are UFW and Firewalld"
  Typing "${G}UFW${I} stands for Uncomplicated Firewall. It's a simple yet user-friendly firewall tool built on iptables. It's shipped with Ubuntu"
  Typing "${G}Firewalld${I} is powerful yet more complex comparing to UFW. It's built-in in RHEL-based distros like Fedora or CentOS"

  SilentValidateFlag --ufw && AddTodo SetUpUfw
  SilentValidateFlag --firewalld && AddTodo SetUpFirewalld
  SilentValidateFlag --nftables && AddTodo SetUpNftables

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
  echo "$*" >> "$Todo"
  Log "Todo item added: $*"
}


GetPasswordAndHash(){
  local password retyped
  while true; do
    Typing -n "What would be password (your input won't show up for security reason)?: "; read -rs password; echo >&2
    Typing -n "Retype the password: "; read -rs retyped; echo >&2
    if [[ -z "$password" ]]; then
      Typing -e "Empty password is not allowed"
    elif [[ $password == "$retyped"  ]]; then
      break
    else
      Typing -e "Passwords do not match. Let's try again" >&2
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
  echo "$index"
}


GetFlagValueCount(){
  local flag=$1 index=${Flag_Indexes[$1]:-}
  local order; order=$(IndexArrayValue Flags "$flag")
  local next_flag=${Flags[order+1]:-}
  local next_flag_index=$([[ -n "$next_flag" ]] && echo "${Flag_Indexes[$next_flag]}" || echo "${#Args[@]}")
  echo $((next_flag_index - index - 1))
}


DoIfInteractive(){
  ! $Interactive && return
  local a; for a in "$@"; do
    $a
  done
}


Main
