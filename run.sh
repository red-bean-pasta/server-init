#! /bin/bash

This_Path="$(realpath "${BASH_SOURCE[0]}")"
This_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

Common_Script="$This_Dir/common.sh"
Setup_Script="$This_Dir/server_setup.sh"
Restore_Script="$This_Dir/server_restore.sh"

Nftables_Base_Rules="$This_Dir/base.nft"

SSH_Socket=""
Server_Work_Dir="/tmp/Server_Initialization"

Dir_For_This_Server=""
Key_Dir=""
Restore_Dir=""
Log_File=""

Server_IP=""
Root_Username=""
Port=""

# Some common variables and functions, e.g. message color code, function to check yes or no
source "$Common_Script"

Main() {
    # Exit once error is encountered rather than continuing
    set -e

    CheckIfTyping
    echo

    InitializeServerInformation 
    InitializeVariables
    echo

    if [[ -f "$Log_File" ]]; then
        LogInAndRestore
    else
        LoginAndSetUp
    fi
}

InitializeServerInformation(){
    Typing -n "First, what's the server's ${G}IP or domain${I}?: "
    read -r Server_IP
    
    Typing -n "And what's the root user's ${G}username${I}? Normally it is just \"${G}root${I}\": "
    read -r Root_Username

    Typing -n "Last, what's the ${G}port${I} open for SSH connection? It should be 22 by default: "
    read -r Port

    # Trim leading and trailing blank space 
    Server_IP=$(Trim "$Server_IP")
    Root_Username=$(Trim "${Root_Username:-root}")
    Port=$(Trim "${Port:-22}")
}

InitializeVariables(){
    Dir_For_This_Server="$This_Dir/$Server_IP"
    Key_Dir="$Dir_For_This_Server/Key"
    Restore_Dir="$Dir_For_This_Server/Restoration"
    Log_File="$Restore_Dir/log"

    SSH_Socket="/tmp/$Root_Username@$Server_IP:$Port.sock"

    mkdir -p "$Key_Dir"
    mkdir -p "$Restore_Dir"
}

LogInAndRestore(){
    Typing "You've run this script for this server before. ${Y}Did something go wrong${I}? Don't worry, ${Y}let's restore everything!${I}"

    TryConnectToServerInRestorationMode
    echo

    if SshRunCommand "[[ -d $Server_Work_Dir ]]"; then
        Typing "Detected neccessary files still left on server."
    else
        local files_to_upload=("$Common_Script" "$Restore_Script" "$Restore_Dir/*")
        SftpToServer "$This_Dir" "${files_to_upload[@]}"
        Typing "Copied neccessary files."
    fi
    echo

    SshRunCommand "IS_TYPING=$IS_TYPING bash $Server_Work_Dir/server_restore.sh"
    Typing "Everything restored."
    echo

    SshRunCommand "rm -rf ${Server_Work_Dir:?}"
    Typing "All related files at the server side are now removed."
    echo

    Typing "About to restart SSH service..."
    SshRunCommand "systemctl restart ssh"
    Typing "SSH service restarted."
    echo
    
    rm "$SSH_Socket"
    Typing "Master SSH connection socket removed. No one can exploit the master SSH connection now."
    echo

    rm -rf "${Dir_For_This_Server:?}"
    Typing "All related local files removed."
    echo

    Typing "${G}You're all set${I}."
}

LoginAndSetUp(){
    ### Create master socket
    # In case last setup was disrupted, after creating master socket, but before actually copied any setup files 
    rm -rf "${SSH_Socket:?}"

    Typing "Let's first create a ${Y}master SSH connection${I}. It's essentially a connection that can persists and be reused, so you don't have to retype your password over and over."
    Typing "There may be prompt asking for password. You may find it a little bizzare that your typing won't show up. That's for the sake of security."
    CreateMasterSshConnection
    echo -e "Master SSH connection ${G}created${I}. Connection socket is $SSH_Socket"
    echo
    
    ### Copy files
    Typing "Now we are ${Y}logging into the server${I} as root user. "
    SshRunCommand "mkdir -p $Server_Work_Dir"

    local filenames_to_upload=("$Setup_Script" "$Restore_Script" "$Common_Script" "$Nftables_Base_Rules")
    SftpToServer "$Server_Work_Dir" "${filenames_to_upload[@]}"
    echo -e "Neccessary files copies."
    echo "$FILES_UPLOADED_LOG" >> "$Log_File"
    echo

    ### Set up
    SshRunCommand "IS_TYPING=$IS_TYPING bash $Server_Work_Dir/server_setup.sh --part1"
    echo

    ### Retrieve keys back
    SftpFromServer "$Key_Dir" "$Server_Work_Dir/*.key"
    compgen -G "$Key_Dir/*.key" >/dev/null || { echo "Error: No private key copied"; exit 1; }
    Typing "${G}Private key copied and saved under $Key_Dir${I}. Keep them safe! "
    echo

    mkdir -p "$HOME/.ssh/"
    cp "$Key_Dir"/*.key "$HOME/.ssh/"
    chmod 600 "$HOME/.ssh/config/"*.key
    Typing "Private key copied to $HOME/.ssh/config/ directory as well. It's a  When you try to connect with a server, it should know to use keys there automatically."
    echo

    SshRunCommand "IS_TYPING=$IS_TYPING bash $Server_Work_Dir/server_setup.sh --part2"
    Typing "Everything set up."
    echo

    ### Retrieve files for restoration back
    local filenames_to_download=()
    for file in user.log backup.nft root_authorized_keys; do
        filenames_to_download+=("$Server_Work_Dir/$file")
    done
    # File backup.nft and root_authorized_keys may not exists, thus use "|| true" to catch errors.
    SftpFromServer "$Restore_Dir" "${filenames_to_download[@]}"
    SshRunCommand "cat $Server_Work_Dir/log" >> "$Log_File"
    Typing "Files needed for restoration copied under $Restore_Dir. "
    echo "$FILES_DOWNLOADED_LOG" >> "$Log_File"
    echo

    ### Clear up
    SshRunCommand "rm -rf $Server_Work_Dir"
    Typing "Files for setting up at the server end are now longer needed. Deleted."
    echo

    RestartSsh
    echo

    rm "$SSH_Socket"
    Typing "Master SSH connection socket removed. No one can exploit the master SSH connection now."
    echo
    
    Typing "${G}You're all set!${I}"
    Typing "${G}Enjoy!${I}"
}

CreateMasterSshConnection(){
    local key_path="$1"
    local key_option

    if [[ -n "$key_path" ]]; then
        key_option="-i $key_path"
    fi

    eval "ssh -f -M -o ControlPath=$SSH_Socket -o ControlPersist=yes $key_option -p $Port $Root_Username@$Server_IP sleep 1"
}

RestartSsh(){
    Typing "${Y}About to restart SSH service. All changes will take effect.${I}"
    Typing "${R}WARNING${I}: You may get ${Y}logged out${I} if you have changed the SSH port. You'll need to re-connect to the server using the new port."
    Typing "${R}WARNING${I}: If you've disabled password authentication, ${R}ensure you have the private key on your local machine${I}."
    
    local response
    Typing -n "Restart service(Y/n): "
    read -r response
    if CheckYesOrNo "$response" "y"; then
        Typing "${G}Restarting${I} SSH service..."
        SshRunCommand "systemctl restart ssh"
        Typing "SSH service restarted"
    else
        Typing "${G}Skipped${I} restarting SSH service."
        Typing "Please restart SSH service ${G}manually${I} when you're ready, for changes to take effect."
    fi
}

SshRunCommand(){
    local command="$1"
    ssh -S "$SSH_Socket" -p "$Port" "$Root_Username@$Server_IP" "$command"
}

SftpToServer(){
    local remote_destination="$1"
    local files=("${@:2}")
    local command
    local host

    command+="cd $remote_destination"$'\n'

    for file in "${files[@]}"; do
        command+="put $file"$'\n'
    done

    command+="bye"

    sftp -o "ControlPath=$SSH_Socket" -o "Port=$Port" "$Root_Username@$(GetNormalizedHost)" <<< "$command"
}

SftpFromServer(){
    local local_destination="$1"
    local files=("${@:2}")
    local command

    command+="lcd $local_destination"$'\n'

    for file in "${files[@]}"; do
        command+="get $file"$'\n'
    done

    command+="bye"
    
    sftp -o "ControlPath=$SSH_Socket" -o "Port=$Port" "$Root_Username@$(GetNormalizedHost)" <<< "$command"
}

TryConnectToServerInRestorationMode(){
    if [[ -S "$SSH_Socket" ]]; then
        Typing "Great, found the connection socket from last time. We can now reuse it and make everything right! "
        return 0
    fi

    if CreateMasterSshConnection; then
        Typing "Ah! Password authentication wasn't disabled. We can now log in and make everything right!"
        return 0
    fi

    local root_key_path="$Key_Dir/$Root_Username.key"
    if CreateMasterSshConnection "$root_key_path"; then
        Typing "Password authentication was disabled. Luckily we got the root user's private key. Now let's log in and make everything right!"
        return 0 
    fi 
    
    Typing "You seem to have completely diabled logging in as root user. Let's log in as someone in the sudo group."
    LogInAsSudoAndEnableRootLogIn

    CreateMasterSshConnection
}

LogInAsSudoAndEnableRootLogIn(){
    local username
    Typing -n "Now could you provide the name of some user inside sudo gorup?: "
    read -r username

    username=$(Trim "$username")

    local key_path="$Key_Dir/$username.key"
    local user_ssh_socket_path="/tmp/$username@$Server_IP:$Port.sock"

    if ssh -f -M -S "$user_ssh_socket_path" -o ControlPersist=yes -p "$Port" "$username"@"$Server_IP" sleep 1; then
        Typing "You didn't seem to disable password authentication. We can now connect to the server and make everything right!"
    elif ssh -f -M -S "$user_ssh_socket_path" -o ControlPersist=yes -i "$key_path" -p "$Port" "$username"@"$Server_IP" sleep 1; then
        Typing "Logged in with this user's private key. We can now connect to the server and make everything right!"
    else 
        Typing "${R}ERROR${I}: Failed to log in as user $username whether by password or key. Please retry. Or re-deploy the server at the provider, as the last restort."
        exit "$SSH_FAILED"
    fi

    ssh -S "$user_ssh_socket_path" -p "$Port" "$username"@"$Server_IP" "sudo sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
    Typing "Logging in as root is enabled. Password authentication is enabled."

    rm -rf "${user_ssh_socket_path:?}"
}

GetNormalizedHost(){
    local host
    if [[ "$Server_IP" == *:* ]]; then 
        host="[$Server_IP]" # SFTP will mistake : as separator, as the historical convention is user@host:file_name
    else
        host="$Server_IP"
    fi
    
    echo "host"
}

Main