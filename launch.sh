#! /bin/bash

set -eu -o pipefail

Script_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib/helpers.sh
source "$Script_Dir/lib/helpers.sh"

declare Host User Port Timestamp Tmp_Dir Ssh_Socket Remote_Dir

Setup_Args=()


PrintHelp(){
cat <<EOF
Set up remote server running on Linux
Pass options to run in automated mode, else interactive mode

Options:
  -h, --help
    Show help message
  --typing
    Enable typing effect for terminal output. Default to false if any automation argument is provided

Connection options:
  --host
    Server address
  --port
    SSH Port to connect to

Remote automation options:
  --user [username] [password_hash] [key_comment (default: username:hostname)] [if_sudo_group (default: true)] [optional: shell (default: bash)]
    Create new user with a home directory. Password should be hashed by SHA-512 or Yescrypt algorithm. Be sure to single quote the password as it may contain special characters
  --more-users
    Add more users in interactive mode
  --root-password [password_hash]
    Change root password. Password should be hashed by SHA-512 or Yescrypt algorithm. Be sure to single quote it
  --hostname [new_hostname]
    Change hostname
  --timezone [new_timezone]
    Change timezone
  --new-port [new_port]
    Change the SSH port
  --disable-password
    Disable SSH password login
  --disable-root
    Disable SSH root login
  --update
    Perform system packages update
  --ufw
    Install and set up UFW. Conflicts with --firewalld and --nftables. May require --update
  --firewalld
    Install and set up Firewalld. Conflicts with --ufw and --nftables. May require --update
  --nftables
    Install and set up Nftables. Conflicts with --ufw and --firewalld. May require --update
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
  
  Log "Setup completed. Enjoy!"
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
    Typing -e "Only one firewall option may be used: --ufw, --firewalld or --nftables"
    return 1
  fi
}


PrepareSshInfo(){
  : "${Host:=$(PromptForAnswer "First, how should we connect to the server? Most servers should have an ${G}IP${I}: ")}"
  User=root
  : "${Port:=$(PromptForAnswer "What's the SSH ${G}port${I}? [Default to 22]: " 22)}"

  Log "Host: $Host"
  Log "User: $User"
  Log "Port: $Port"

  if [[ -z $Host || -z $User || -z $Port ]]; then
    Typing -e "Provided info is incomplete. Aborting..."
    exit 1
  fi
  if ! CheckIfValidPort "$Port"; then
    Typing -e "SSH port must be a number between 1 and 65535. Aborting..."
    exit 1
  fi
}


SetUp(){
  Typing "Creating ${Y}master SSH connection${I}... It's essentially one persisting reusable connection. It will be purged after so don't worry."
  Typing "It will prompt for password. Password won't show up during typing for security reasons."
  Typing "It may prompt about 'fingerprint'. Fingerprint identifies a connection's authenticity. While middle man attack doesn't happen often, it doesn't hurt to be cautious. You may find the correct fingerprint in your provider's mail or website."
  CreateMasterSshConnection
  Log "Master SSH connection ${G}created${I} at $Ssh_Socket"
  echo

  Typing "Creating temporary server-side working directory $Remote_Dir.."
  SshRunCommand mkdir -p "$Remote_Dir/"
  Log "Working directory created"

  Typing "Uploading files..."
  CopySetupFiles
  Log "All files transferred"
  echo

  Typing "Let's first do a quick survey about what to set up"
  local env; env=("TIMESTAMP=$Timestamp" "SSH_PORT=$Port" "TYPING=$TYPING")
  SshRunCommandWithPty "${env[@]}" bash "$Remote_Dir/survey.sh" "${Setup_Args[@]}" # Pty merges stdin and stderr
  echo

  local user_record; user_record=$(SshCatFile "$Remote_Dir/new_users")
  local new_hostname; new_hostname=$(SshCatFile "$Remote_Dir/new_hostname")
  local -a users=(); if [[ -n $user_record ]]; then
    IFS=' ' read -ra users <<< "$user_record"
  fi

  Typing "Before setting everything up, let's parepare needed authentication keys..."
  if (( ${#users[@]} > 0 )); then
    local key_method=ed25519
    CreateSshKeys "$key_method" "$new_hostname" "${users[@]}" "$User"
    Log "All users have their keys generated"
    echo

    Typing "Uploading public keys to server..."
    UploadPublicKeys
    Log "All public keys uploaded"
    echo
  else
    Log "No user created. Skipping..."
    echo
  fi

  Typing "Setting up..."
  SshRunCommandWithPty "${env[@]}" bash "$Remote_Dir/setup.sh"
  Typing "Setup completed"
  local new_port; new_port=$(SshCatFile "$Remote_Dir/new_port")

  local hero; if (( ${#users[@]} > 0 )); then
    hero=${users[0]}
  else
    hero=$USER
  fi
  Typing "Trying to log in and disable nuclear recovery timer..."
  if TryLogInDisableTimer "$new_port" "$hero"; then
    Typing "Appending private keys to local location $HOME/.ssh/id_ed25519"
    AppendPrivateKeys
  fi
}


CreateMasterSshConnection(){
  local cmds; cmds=(
    "ssh"
    "-f" "-M" "-N"
    "-o" "ControlPath=$Ssh_Socket"
    "-o" "ControlPersist=yes"
    "-p" "$Port"
    "$User@$Host"
  )
  [[ -n "${1:-}" ]] && cmds+=(-i "$1")
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
  local method=$1 hostname=$2 comments_name=$3
  local -n comments=$comments_name
  local i=0 u comment
  for u in "${@:4}"; do
    Typing "Generating keys for user '$u'..."
    comment=${comments[i]:-}
    if [[ -z $comment ]]; then
      comment=$(PromptForAnswer "Add ${G}comment${I} for '$u'? [Default: $u:$hostname]: " "$u:$hostname")
    fi
    Typing "You can have ${G}passwords${I} on top of keys. It's also generally recommended. It stops the attacher to log in even if the key is leaked"
    ssh-keygen -t "$method" -o -a 256 -C "$comment" -f "$Tmp_Dir/$u.$Timestamp.key"
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
  Typing "Trying to log in as '$user' with key at $key..."
  if ssh -p "$port" -i "$key" -o PasswordAuthentication=no "$user@$Host" "rm -rf '${Remote_Dir:?}'/* 2>/dev/null; rmdir '${Remote_Dir:?}' 2>/dev/null || true; [ ! -f '${Remote_Dir:?}/toundo' ]"; then
    Typing "Recovery timer successfully disabled"
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
  Log "Performing cleanup..."

  if [[ -S "$Ssh_Socket" ]]; then
    ssh -S "$Ssh_Socket" -O exit -p "$Port" "$User@$Host" 2>/dev/null || true
    Log "Closed master SSH connection"
  fi

  if [[ -n ${Tmp_Dir:-} && -d $Tmp_Dir ]]; then
    RemoveDirectory "$Tmp_Dir"
    Log "Removed $Tmp_Dir where SSH socket and keys temporarily live"
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
