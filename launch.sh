#! /bin/bash

set -eu -o pipefail

Script_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/helpers.sh
source "$Script_Dir/lib/helpers.sh"


Timestamp=$(date -u +"%Y%m%dT%H%M")
Tmp_Dir=$(mktemp -d /tmp/dir.XXXXXX); chmod 700 "$Tmp_Dir"
Ssh_Socket=$(mktemp -u "$Tmp_Dir/sock.XXXXXX") # To ensure compatibility with the v3.2 Bash on MacOS
Remote_Dir=$(mktemp -du /tmp/dir.XXXXXX)

declare Host User Port
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
        --user [username] [password_hash] [if_create_home] [if_sudo_group] [shell] 
            Create new user. Password should be hashed with SHA-512 algorithm. Be sure to single quote the password
        --more-users
            Add more users in interactive mode
        --root-password [password_hash]
            Change root password. Password should be hashed with SHA-512 algorithm. Be sure to single quote it
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
	local log; log=$(mktemp)
	echo
	Log "[You can find the log at $log if anything went wrong]"
	echo
	Launch "$@" 2>&1 | tee "$log"
	echo
	Log "Setup completed. Enjoy! "
}


Launch(){
	ParseArgs "$@"

	CheckIfTyping
	echo

    PromptForCreds
    echo

	SetUp
}


ParseArgs(){
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h | --help)
				PrintHelp; exit;;
            --typing)
                TYPING=true; shift;;
			--host)
				Host="$2"; shift 2 ;;
			--port)
				Port="$2"; shift 2 ;;
			*)
				Setup_Args+=("$1"); shift;;
		esac
	done
}


PromptForCreds(){
	: "${Host:=$(PromptForAnswer "First, what would the server's ${G}IP or domain${I} be?: ")}"
	User=root
	: "${Port:=$(PromptForAnswer "Then, what would be the SSH ${G}port${I}? [Default to 22]: " 22)}"

	Log "Host: $Host"
	Log "User: $User"
	Log "Port: $Port"

	[[ $Host && $User && $Port ]] || { Typing -e "Provided info is incomplete. Aborting..."; exit 1; }
}


SetUp(){
    trap CleanUp EXIT INT TERM HUP PIPE

	Typing "Creating ${Y}master SSH connection${I}... It's essentially one persisting connection that can be reused. Don't worry, it will be purged once everything is set up"
	Typing "It will prompt for password. In terminal, password won't show up when typing for security reasons"
	Typing "It may also prompt about fingerprint. Fingerprint identifies the connection's authencity so that middle men can't impersonating. It doesn't happen often. But it won't hurt to be cautious. You may find the correct fingerprint on the mail from your provider or their website"
	CreateMasterSshConnection
	Typing "Master SSH connection ${G}created${I} at $Ssh_Socket"
	echo

	Typing "Creating temporary working directory $Remote_Dir on server before ${Y}uploading${I} neccessary setup files..."
	SshRunCommand mkdir -p "$Remote_Dir/"
	Typing "Uploading files..."
	CopySetupFiles
	Typing "All files transferred"
	echo

	local env; env=("TIMESTAMP=$Timestamp" "SSH_PORT=$Port" "TYPING=$TYPING")
	local new_users_record; new_users_record=$Remote_Dir/new_user
	Typing "Let's do a quick survey about what to set up first"
	SshRunCommandWithPty "${env[@]}" bash "$Remote_Dir/survey.sh" "$new_users_record" "${Setup_Args[@]}" # Pty merges stdin and stderr
	local users; users=$(SshCatFile "$new_users_record")
	echo

	Typing "Before setting everything up, let's ${Y}create and upload keys${I} for the users on server. After all, key authentication needs keys to work. One user can actually have multiple keys. But for now, we just need one for each user"
	local key_method=ed25519
	local -a array; IFS=' ' read -ra array <<< "$users"
	CreateSshKeys "$key_method" "${array[@]}" "$User"
	Typing "All users have their keys generated"
	echo
	
	UploadPublicKeys
	Typing "Public keys Uploaded"
	echo

	Typing "Setting up..."
	local new_port_record; new_port_record="$Remote_Dir/new_port"
	SshRunCommandWithPty "${env[@]}" bash "$Remote_Dir/setup.sh" "$new_port_record"
	Typing "Setup completed"
	local new_port; new_port=$(SshCatFile "$new_port_record")

	Typing "Trying to log in and disable nuclear recovery timer..."
	if TryLogInDisableTimer "$new_port" "${users[0]}"; then
		local ssh_config_dir="$HOME/.ssh/id_$key_method.d"
		Typing "Copying private keys to local location $ssh_config_dir. This folder is automatically when initiating a SSH connection, saving you from specifying keys path when connecting to server"
		CopyPrivateKeys "$ssh_config_dir"
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
	local u comment method=$1
	for u in "${@:2}"; do
		Typing "Generating keys for user '$u'..."
		comment=$(PromptForAnswer "Add ${G}comment${I}? It may help with identification. A common practice is using email. Return to skip: ")
		Typing "You can have ${G}passwords${I} on top of keys. It's also generally recommended. It stops the attacher to log in even if the key is leaked"
		ssh-keygen -t "$method" -o -a 256 -C "$comment" -f "$Tmp_Dir/$u.$Timestamp.key"
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
	if ssh -p "$port" -i "$key" -o PasswordAuthentication=no "$user@$Host" "rm -rf ${Remote_Dir:?}"; then
		Typing "Recovery timer successfully disabled"
		return 0
	else
		Typing "Failed to log in. Recovery will happen"
		return 1
	fi
}


CopyPrivateKeys(){
	mkdir -p "$1"
	cp "$Tmp_Dir"/*.key "$1/"
	chmod 600 "$1/"*
}


CleanUp(){
	local exit_code=$?
	Log "Performing restoration and cleanup..."

	ssh -S "$Ssh_Socket" -O exit -p "$Port" "$User@$Host" 2>/dev/null || true
	RemoveDirectory "$Tmp_Dir"
	Log "Removed $Tmp_Dir where SSH ControlMaster socket and keys temporarily live"

	Log "Everything cleaned up"
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