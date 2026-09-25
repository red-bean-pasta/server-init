#! /bin/bash

set -eu -o pipefail

Script_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib/helpers.sh
source "$Script_Dir/lib/helpers.sh"

declare Host User Port Accept_New_Host Timestamp Tmp_Dir Ssh_Socket Remote_Dir

Setup_Args=()


PrintHelp(){
cat <<EOF
Lightweight bash tool to help initializing remote Linux servers
Pass options for automated mode, or run without options for interactive mode

Options:
  -h, --help
    Show help message
  --typing
    Enable the typing effect for easier reading. It is disabled automatically when you pass setup options

Connection options:
  --host
    Server address or domain
  --port
    SSH port used to connect to the server
  --accept-new-host
    Automatically accept a new SSH host key for setup and final verification SSH connections

Remote automation options:
  --user [username] [password-hash] [if-sudo (default: true)] [optional: shell (default: bash)] [ssh-key-comment (default: username:hostname)] [optional: ssh-key-password]
    Create a new user with a home directory
    password-hash should be a SHA-512 or Yescrypt hash and single quoted because it may contain special characters
    The optional ssh-key-password should be plaintext and single quoted
  --root [optional: new-password-hash] [optional: ssh-key-comment (default: root:hostname)] [optional: ssh-key-password]
    Change the root password and prepare its SSH key
    Pass "" as new-password-hash to keep the current root password
    The optional ssh-key-password should be plaintext and single quoted
  --hostname [hostname]
    Change the server's hostname
  --timezone [new_timezone]
    Change timezone
  --new-port [new_port]
    Change the SSH port
  --disable-password
    Disable password-based SSH login
  --disable-root
    Disable SSH login for root
  --update
    Perform system packages update
  --ufw
    Install and set up UFW. Use only one of --ufw, --firewalld, and --nftables. May require --update
  --firewalld
    Install and set up Firewalld. Use only one of --ufw, --firewalld, and --nftables. May require --update
  --nftables
    Install and set up Nftables. Use only one of --ufw, --firewalld, and --nftables. May require --update
  --fail2ban
    Install and set up Fail2Ban. May require --update
EOF
}


Main() {
  HelpIfNeeded "$@"
  
  local log; log=$(mktemp)
  echo
  Log "You can find the log at $log"
  echo
  
  Launch "$@" 2>&1 | tee "$log"
  echo
  
  Log "Setup completed. You can find the log at '$log'. Enjoy!"
}


HelpIfNeeded(){
  local arg; for arg in "$@"; do
    case "$arg" in
      -h | --help)
        PrintHelp
        exit 0
        ;;
    esac
  done
}


Launch(){
  InitializeRuntime
  trap CleanUp EXIT INT TERM HUP PIPE

  ParseArgs "$@"

  CheckIfTyping
  echo

  PrepareSshInfo
  echo

  SetUp
}

InitializeRuntime(){
  Timestamp=$(date -u +"%Y%m%dT%H%M%S")
  
  Tmp_Dir=$(mktemp -d /tmp/dir.XXXXXX)
  chmod 700 "$Tmp_Dir"
  
  Ssh_Socket=$(mktemp -u "$Tmp_Dir/sock.XXXXXX") # To ensure compatibility with the v3.2 Bash on MacOS
  Remote_Dir=$(mktemp -du /tmp/dir.XXXXXX)
}


ParseArgs(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        PrintHelp
        exit
        ;;
      --typing)
        TYPING=true
        shift
        ;;
      --accept-new-host)
        Accept_New_Host=true
        shift
        ;;
      --host)
        [[ $# -ge 2 ]] || { Typing -e "Missing value for --host"; exit 1; }
        Host="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || { Typing -e "Missing value for --port"; exit 1; }
        Port="$2"
        shift 2
        ;;
      *)
        Setup_Args+=("$1")
        shift
        ;;
    esac
  done

  if [[ ! ${TYPING:-} ]] && (( ${#Setup_Args[@]} > 0 )); then
    TYPING=false
  fi

  if ! ValidateFirewallOptions; then
    return 1
  fi
}

ValidateFirewallOptions(){
  local count=0 option argument
  for option in --ufw --firewalld --nftables; do
    for argument in "${Setup_Args[@]}"; do
      if [[ "$argument" == "$option" ]]; then
        ((count += 1))
        break
      fi
    done
  done

  if (( count > 1 )); then
    Typing -e "Choose only one firewall option: --ufw, --firewalld, or --nftables"
    return 1
  fi
}


PrepareSshInfo(){
  : "${Host:=$(PromptForAnswer "First, how should we connect to the server? Most servers use an ${G}IP address${I}: ")}"
  User=root
  : "${Port:=$(PromptForAnswer "What's the SSH ${G}port${I}? [Default to 22]: " 22)}"

  Log "Host: $Host"
  Log "User: $User"
  Log "Port: $Port"

  if [[ -z $Host || -z $User || -z $Port ]]; then
    Typing -e "Connection details is incomplete. Aborting..."
    exit 1
  fi
  if ! CheckIfValidPort "$Port"; then
    Typing -e "SSH port must be a number between 1 and 65535. Aborting..."
    exit 1
  fi
}


SetUp(){
  Typing "Creating a ${Y}master SSH connection${I} so the setup can reuse one open SSH connection. It will be removed when setup exits"
  Typing "SSH may ask for password. Nothing will appear while you type it, which is normal for security"
  Typing "SSH may ask about a ${Y}fingerprint${I}. It helps confirm that you are connecting to the right server and not an impostor. Check your provider's email or website if you need to verify it"
  CreateMasterSshConnection
  Log "Master SSH connection ${G}created${I} at $Ssh_Socket"
  echo

  Typing "Creating a temporary working folder on the server at $Remote_Dir"
  SshRunCommand mkdir -p "$Remote_Dir/"
  Log "Temporary server folder created"

  Typing "Uploading setup files to the server"
  CopySetupFiles
  Log "Setup files uploaded"
  echo

  Typing "Let's first ${Y}answer a few questions${I} about what to set up"
  local env; env=("TIMESTAMP=$Timestamp" "SSH_PORT=$Port" "TYPING=$TYPING")
  SshRunCommandWithPty "${env[@]}" bash "$Remote_Dir/survey.sh" "${Setup_Args[@]}" # Pty merges stdin and stderr
  echo

  local user_record; user_record=$(SshCatFile "$Remote_Dir/new_users")
  local -a users=(); if [[ -n $user_record ]]; then
    IFS=' ' read -ra users <<< "$user_record"
  fi

  Typing "Before applying the changes, let's prepare the login keys"
  Typing "During key generation, SSH will ask whether to protect each private key with a password. This adds protection if the key is leaked"

  CreateSshKeys "${users[@]}" "$User"
  Log "Login keys generated for all users"
  echo

  Typing "Uploading the public login keys to the server"
  UploadPublicKeys
  Log "All public keys uploaded"
  echo

  Typing "Applying the selected server changes"
  SshRunCommandWithPty "${env[@]}" bash "$Remote_Dir/setup.sh"
  Typing "Server changes applied"
  local new_port; new_port=$(SshCatFile "$Remote_Dir/new_port")

  local hero; if (( ${#users[@]} > 0 )); then
    hero=${users[0]}
  else
    hero=$USER
  fi
  Typing "Trying to log in and disable nuclear recovery timer..."
  if TryLogInDisableTimer "$new_port" "$hero"; then
    Typing "Adding the generated private keys to $HOME/.ssh/id_ed25519"
    AppendPrivateKeys
  else
    Typing -e "Attempt failed. Recovery will happen"
    return 1
  fi
}


CreateMasterSshConnection(){
  local cmds; cmds=(
    "ssh"
    "-f" "-M" "-N"
    "-o" "ControlPath=$Ssh_Socket"
    "-o" "ControlPersist=yes"
  )
  if [[ ${Accept_New_Host:-false} == true ]]; then
    cmds+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  fi
  cmds+=(-p "$Port")
  [[ -n "${1:-}" ]] && cmds+=(-i "$1")
  cmds+=("$User@$Host")
  "${cmds[@]}"
}


CopySetupFiles(){
  local name="setup.tar.gz"
  local archive="$Tmp_Dir/$name"
  tar -czf "$archive" -C "$Script_Dir/lib" helpers.sh -C "$Script_Dir/server" .
  SftpToServer "$Remote_Dir" "$archive"
  SshRunCommand tar -xzf "$Remote_Dir/$name" -C "$Remote_Dir"
}


CreateSshKeys(){
  local method=ed25519
  local hostname; hostname=$(SshCatFile "$Remote_Dir/new_hostname") # nameref isn't supported on the legacy MacOS bash
  local commented; commented=$(SshCatFile "$Remote_Dir/automated_ssh_comments")
  local passworded; passworded=$(SshCatFile "$Remote_Dir/automated_ssh_passwords")
  local -a comments=() passwords=()
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    comments+=("$line")
  done <<< "$commented"
  while IFS= read -r line || [[ -n $line ]]; do
    passwords+=("$line")
  done <<< "$passworded"

  local i=0; local user cmt pwd; local -a commands
  for user in "$@"; do
    Typing "Generating a login key for '$user'"
    cmt=${comments[i]:-$user:$hostname}
    pwd=${passwords[i]-}
    commands=(ssh-keygen -t "$method" -o -a 256 -C "$cmt" -f "$Tmp_Dir/$user.$Timestamp.key")
    if [[ -n $pwd ]]; then
      commands+=(-N "$pwd")
    fi
    "${commands[@]}"
    ((i += 1))
  done
}


UploadPublicKeys(){
  local name="keys.tar.gz"
  local archive="$Tmp_Dir/$name"
  (cd "$Tmp_Dir" && tar -czf "$archive" ./*.pub)
  SftpToServer "$Remote_Dir" "$archive"
  SshRunCommand tar -xzf "$Remote_Dir/$name" -C "$Remote_Dir"
}


TryLogInDisableTimer(){
  local port=$1 user=$2
  local key; key="$Tmp_Dir/$user.$Timestamp.key"
  local cancel_file; cancel_file="$Remote_Dir.cancel"
  local -a ssh_args=(-p "$port" -i "$key" -o PasswordAuthentication=no)
  if [[ ${Accept_New_Host:-false} == true ]]; then
    ssh_args+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  fi
  Typing "Trying to log in as '$user' with key at $key..."
  if ssh "${ssh_args[@]}" "$user@$Host" "touch '$cancel_file' && [ -f '$cancel_file' ]"; then
    Typing "Recovery timer cancellation ordered"
    return 0
  else
    Typing "Failed to log in. Recovery will happen"
    return 1
  fi
}


AppendPrivateKeys(){
  local target="$HOME/.ssh/id_ed25519"
  mkdir -p "$HOME/.ssh"

  local k; for k in "$Tmp_Dir"/*.key; do
    [[ -f $k ]] || continue
    cat "$k" >> "$target"
  done

  chmod 600 "$target"
  rm -f "$Tmp_Dir"/*.key "$Tmp_Dir"/*.pub
}


CleanUp(){
  local exit_code=$?
  if (( exit_code != 0 )); then
    Log -e "Setup exited with code $exit_code"
  fi

  Log "Performing cleanup..."

  if [[ -S "$Ssh_Socket" ]]; then
    ssh -S "$Ssh_Socket" -O exit -p "$Port" "$User@$Host" 2>/dev/null || true
    Log "Closed master SSH connection"
  fi

  if [[ -n ${Tmp_Dir:-} && -d $Tmp_Dir ]]; then
    RemoveDirectory "$Tmp_Dir"
    Log "Removed temporary local folder $Tmp_Dir containing the SSH socket and keys"
  fi

  Log "Everything cleaned up"
  trap - EXIT INT TERM HUP PIPE
  exit "$exit_code"
}


### Helpers
SshRunCommand(){
  ssh -S "$Ssh_Socket" -p "$Port" "$User@$Host" "$(NormalizeRemoteCommand "$@")"
}


SshRunScript(){
  if [ -t 0 ]; then
    SshRunCommand bash -c "$@"
  else
    SshRunCommand bash -s
  fi
}


SshRunCommandWithPty(){ # Pty is needed for trap invoke and silent read
  ssh -t -S "$Ssh_Socket" -p "$Port" "$User@$Host" "$(NormalizeRemoteCommand "$@")"
}


SshCatFile(){
  SshRunCommand cat "$1"
}


NormalizeRemoteCommand(){
  printf '%q ' "${@}" # Notice the blank space in '%q '
}


SftpToServer(){
  local dest="$1" files=("${@:2}")
  local command

  command+="cd $dest"$'\n'
  for file in "${files[@]}"; do
    command+="put $file"$'\n'
  done
  command+="bye"

  sftp -o "ControlPath=$Ssh_Socket" -o "Port=$Port" "$User@$(NormalizeHost)" <<< "$command"
}


SftpFromServer(){
  local dest="$1" files=("${@:2}")
  local command

  command+="lcd $dest"$'\n'
  for file in "${files[@]}"; do
    command+="get $file"$'\n'
  done
  command+="bye"

  sftp -o "ControlPath=$Ssh_Socket" -o "Port=$Port" "$User@$(NormalizeHost)" <<< "$command"
}


NormalizeHost(){
  # SFTP mistakes colon as file name separator due to historical convention "user@host:file"
  [[ "$Host" == *:* ]] && echo "[$Host]" || echo "$Host"
}


Main "$@"
