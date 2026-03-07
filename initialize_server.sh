#! /bin/bash

# Untested
# Total automation


InitializeLocal(){
    Timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")
    declare -g Host User Port
    Ssh_Socket=$(mktemp -u --suffix=.sock) 
    Remote_Work_Dir=$(mktemp -ud)

    declare -g Good_To_Go

    GetServerInfo(){
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -h|--host)
                    Host="$2"; shift 2 ;;
                -p|--port)
                    Port="$2"; shift 2 ;;
                *)
                    echo "Unknown argument: $1"; exit 1 ;;
            esac
        done

        [[ $Host ]] || { Typing -n "Now, what's the server's ${G}IP or domain${I}?: "; read -r Host; }
        User=root
        [[ $Port ]] || { Typing -n "What's the SSH ${G}port${I}? [Default to 22]: "; read -r Port; }
        
        Host=$(Trim "$Host")
        Port=$(Trim "${Port:-22}")
        echo "Host: $Host"
        echo "User: $User"
        echo "Port: $Port"

        [[ $Host && $User && $Port ]] || { echo "Provided info is incomplete. Aborting..."; exit 1; }
    }

    InitializeLocalSetUp(){
        CreateMasterSshConnection(){
            local key_option; [[ $1 ]] && key_option="-i $1"
            eval "ssh -f -M -o ControlPath=$Ssh_Socket -o ControlPersist=yes $key_option -p $Port $User@$Host sleep 1"
        }
    
        RestartSsh(){
            Typing "${Y}About to reload server-side SSH service. All changes will take effect.${I}"
            Typing "${R}Make sure having private keys locally if password authentication is disabled.${I}"
            
            local response
            Typing -n "Restart service(Y/n): "; read -r response
            if CheckYesOrNo "$response" Y; then
                Typing "${G}Restarting${I} SSH service..."
                SshRunCommand "systemctl reload ssh"
                Typing "SSH service restarted"
            else
                Typing "${G}Skipped${I} reloading SSH service."
                Typing "Please reload ${G}manually${I} when ready."
            fi
        }
    
        SshRunCommand(){
            ssh -S "$Ssh_Socket" -p "$Port" "$User@$Host" "$@"
        }

        SshRunScript(){
            if [ -t 0 ]; then
                SshRunCommand "bash -c" "$*"
            else
                SshRunCommand "bash -s"
            fi
        }

        # Obsolete
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
    }

    SetUp(){
        ### Create master socket
            rm -rf "${SSH_Socket:?}" # In case last setup was disrupted after creating master socket but before copying any setup files 
            Typing "Let's first create a ${Y}master SSH connection${I}. It's essentially one persisting and reusable connection, saving you from retyping passwords repeatedly."
            Typing "It will prompt for password. On Linux, password won't show up while typing for the sake of security, so don't be surprised."
            CreateMasterSshConnection
            echo -e "Master SSH connection ${G}created${I} at $Ssh_Socket"
            echo

        ### Set up
            local setup_env; setup_env=$(
                printf '%s\n' \
                    "set -eu" \
                    "TIMESTAMP=$Timestamp" \
                    "WORKING_DIR=$Remote_Work_Dir" \
                    "SSH_PORT=$Port" \
                    "IS_TYPING=$IS_TYPING" \
                    "$(declare -f InitializeAllShared)" \
                    "$(declare -f InitializeRemoteShared)" \
                    "$(declare -f InitializeRemoteSetUp)" \
                    "InitailizeAllShared" \
                    "InitializeRemoteShared" \
                    "InitializeRemoteSetUp" 
            )
            SshRunCommand "mkdir -p $Remote_Work_Dir"
            printf '%s\n' "$setup_env" "$(declare -f RemoteSetUp1)" "RemoteSetUp1" | SshRunScript
            echo
    
        ### Fetch private keys back first
            local ssh_config_dir="$HOME/.ssh/config"
            mkdir -p "$ssh_config_dir"
            SshRunCommand "Log $Added_Private_Key"
            SftpFromRemote "$ssh_config_dir" "$Remote_Work_Dir/*.key"
            compgen -G "$ssh_config_dir/*$Timestamp*" >/dev/null || { 
                Typing -e "No private key retrieved from remote."; 
                exit 1; 
            }
            chmod 600 "$ssh_config_dir/"*"$Timestamp"*
            Typing "Private keys copied to ${G}local $ssh_config_dir${I}. SSH checks it automatically when connecting to a remote server, saving you from specifying manually."
            Typing "${G}Keep them safe!${I}"
            echo
    
        ### Continue setup
            printf '%s\n' "$setup_env" "$(declare -f RemoteSetUp2)" "RemoteSetUp2" | SshRunScript
            Typing "Everything is set up."
            echo

        ### Mark success for clean up
            Good_To_Go=1
    }

    Restore(){
        local restore_env; restore_env=$(
            printf '%s\n' \
                "set -eu" \
                "TIMESTAMP=$Timestamp" \
                "WORKING_DIR=$Remote_Work_Dir" \
                "SSH_PORT=$Port" \
                "IS_TYPING=$IS_TYPING" \
                "$(declare -f InitializeAllShared)" \
                "$(declare -f InitializeRemoteShared)" \
                "$(declare -f InitializeRemoteRestore)" \
                "InitailizeAllShared" \
                "InitializeRemoteShared" \
                "InitializeRemoteRestore" 
        )
        printf '%s\n' "$restore_env" "$(declare -f RemoteRestoreMain)" "RemoteRestoreMain" | SshRunScript
        echo "Everything restored."
        echo
    }

    CleanUp(){
        ### Check if restore
        if [[ ! $Good_To_Go ]]; then
            Typing -e "Script exiting... Performing restoration and clean-up..."
            Typing -w "Please wait till finish..."
            Restore
        fi

        ### Apply and Clean up
            rm -rf "${Local_Work_Dir:?}"
            Typing "Cleaned up local temporary files."
            echo
        
            SshRunCommand "rm -rf ${Remote_Work_Dir:?}"
            Typing "Cleaned up remote temporary files."
            echo
    
            [[ $Good_To_Go ]] && {
                RestartSsh
                echo
            }
    
            rm "$Ssh_Socket"
            Typing "Master SSH connection socket removed. No one can exploit it now."
            echo
        
        ### :)
        [[ $Good_To_Go ]] && {
            Typing "${G}You're all set!${I}"
            Typing "${G}Enjoy!${I}"
        }
    }
}

LocalMain() {
    trap CleanUp EXIT INT TERM HUP

    CheckIfTyping
    echo

    GetServerInfo "$@"
    echo

    if [[ -f "$Log_File" ]]; then
        InitializeLocalRestore
        LogInAndRestore
    else
        InitializeLocalSetUp
        SetUp
    fi
}

InitializeRemoteShared(){
    Log_File="$WORKING_DIR/log"
    User_Record="$WORKING_DIR/new_users"

    # Log code
    Modify_Hostname="Changing hostname from: "
    Modify_Hosts_File="Modifying /etc/hosts..."
    Modified_Sudoers="Modified sudoers file"
    Added_Public_Key="Adding public keys..."
    Added_Private_Key="Registering privates keys locally"
    Modified_Main_Ssh_Config="Modified /.ssh/sshd_config"
    Modified_Root_Password="Modified root password"
    Updating_Packages="Updating packages"
    Updated_Packages="Updated All packages"
    Installed_Fail2Ban="Installed Fail2Ban"
    Installed_Ufw="Installed ufw"
    Installed_Nftables="Installed nftables"
    Modified_Nftables_Rule="Set up nftables rules"

    Nftables_Dir="/etc/nftables"
    Hostname_File="/etc/hostname"
    Hosts_File="/etc/hosts"
    Sudoers_File="/etc/sudoers"
    Main_Sshd_Config="/etc/ssh/sshd_config"
    Sshd_Directive_Dir="/etc/ssh/sshd_config.d"
    Sshd_Config="$Sshd_Directive_Dir/99-user.$TIMESTAMP.conf"
    Root_Keys="$HOME/.ssh/authorized_keys"
    
    # Obsolete
    CheckIfSudo(){
        if [[ "$EUID" -ne 0 ]]; then
            echo -e "${R}ERROR${I}: Rot privileges required. Please log in as root user."
            exit 1
        fi
    }

    InitializeDistroInfo(){
        local os_file="/etc/os-release"
        if [[ -f "$os_file" ]]; then
            source "$os_file"
            Os=$ID
        else 
            Os="Unknown"
            return 1
        fi
    
        case "$Os" in
            almalinux|centos|rocky)
                Update_Cmd="dnf update -y"
                Install_Cmd="dnf install -y"
                Uninstall_Cmd="dnf remove -y"
                ;;
            debian|ubuntu)
                Update_Cmd="export DEBIAN_FRONTEND=noninteractive && apt-get update -y && apt-get dist-upgrade -o Dpkg::Options::=\"--force-confold\" -o Dpkg::Options::=\"--force-confdef\" && apt-get autoremove -y"
                Install_Cmd="apt-get install -y"
                Uninstall_Cmd="apt-get purge -y"
                ;;
            fedora)
                Update_Cmd="dnf upgrade --refresh -y"
                Install_Cmd="dnf install -y"
                Uninstall_Cmd="dnf remove -y"
                ;;
            *)
                Os="Unsupported"
                return 1
                ;;
        esac
        
    }

    Log(){
        echo "$1" >> "$Log_File"
    }
    
    CheckLog(){
        grep -Fq "$1" "$Log_File"
    }

    ParseUserFromRecord(){
        local -n _arr=$1
        readarray -r _arr < "$User_Record"
    }

    CheckOsSupport(){
        echo "$Os" | grep -iqE "unsupported|unknown" && return 1 || return 0
    }
}

InitializeRemoteSetUp(){
    declare -I TIMESTAMP WORKING_DIR SSH_PORT
    
    Os=""
    Update_Cmd=""
    Install_Cmd=""

    Hostname=$(cat "$Hostname_File")

    New_Users=()
    
    Initial_Ssh_Port=$SSH_PORT
    New_Ssh_Port=""

    InitializeSystemInfo(){
        Typing "Some features of this script ${Y}aren't applicable to all Linux distributions${I}. Different distro ships with different packages and different package managing system. The script can't cover them all. Don't worry, those aren't critical. You can always set them up manually."
        
        InitializeDistroInfo || true

        if CheckOsSupport; then
            Typing "${Y}Unfortunately${I} your system $Os is not supported. "
            [[ $Os == "Unknown" ]] && Typing -e "It appears to be a legacy distro."
            Typing "Supported distro: debian, ubuntu, almalinux, centos, rocky and fedora."
        else
            Typing "Your system $Os is ${G}supported${I}."
            Typing "Update command: $Update_Cmd"
            Typing "Installation command: $Install_Cmd"
        fi     
    }

    ChangeHostname(){
        Typing "You can ${Y}rename the system${I}. It may help with identification. "

        local original=$Hostname
        Typing "Your current hostname is $original."
    
        # Retrieve and check new hostname
        local new
        Typing "Have a better name in mind? "
        Typing -n "Type the new hostname (blankspace not allowed), return if no change: "; read -r new
        while  true; do
            new="$(Trim "$new")"
            if [[ -z "$new" ]]; then
                Typing "${G}Skipped${I} changing hostname."
                return 0
            elif echo "$new" | grep -q " "; then
                Typing -n -e "Blankspace is not allowed. Try again: "; read -r new
            else
                break
            fi
        done
        
        CreateBackup "$Hostname_File"
        if cat "$new" > "$Hostname_File"; then
            Log "$Modify_Hostname $original"
            hostname "$new"
        else
            Typing -e "Failed to change hostname. You may need to troubleshoot manually later."
        fi
        Hostname="$new"
        
        Typing "${G}Hostname successfully changed${I} to $(cat "$Hostname_File")"
    }

    EditHostsFile(){
        local Hosts_File="/etc/hosts"
        Typing "We also need to reflect the change in file $Hosts_File. It's a file mapping hostname and local IP. It's still referenced by some tools."
        if ! CheckOsSupport; then
            Typing "However, we don't know the $Hosts_File file structure of your distro."
            Typing "You may need to modify manually afterwards."
            return 0
        fi

        CreateBackup "$Hosts_File"
        Typing "Backup file created."

        Log "$Modify_Hosts_File"
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
        Typing "${G}Successfully modified $Hosts_File.${I}"

        if grep -q "/etc/cloud" /etc/hosts; then
            Typing -w "Your server provider uses Cloud-Init, which means that after reboot, your server will follow cloud templates and forget all about changes we made."
            Typing "To make things persist, you need to manually disable Cloud-Init or change the template."
        fi
    }

    AddNewUser(){
        Typing "${Y}Operating as admin user is discrouraged${I}. They can easily cause irreversible harms accidentally, e.g., permanent deletion of important files."
        Typing "Let's create some non-admin users! They can still gain admin priviledge if they are in the \"sudo\" group, which means \"superuser do.\""
        
        local new_user more="true" 
        while $more; do
            Typing -n "New user name (blank space not allowed, use \"_\" instead): "; read -r new_user
            new_user="$(Trim "$new_user")"
            if ! useradd -m "$new_user"; then
                Typing -e "Failed to add user $new_user."
                Typing "Don't worry. Let's try again."
                more=true
                continue
            else 
                LogUser "$new_user"
                New_Users+=("$new_user")
                echo -e "${G}Added user $new_user${I}"
            fi

            chown -R "$new_user":"$new_user" "/home/$new_user" # In case where new user's home directory belongs the admin user

            local password_matched="false"
            while [[ $password_matched == false ]]; do
                passwd "$new_user" && password_matched=true || Typing "Retrying setting password..."
            done

            local if_sudo; Typing "Add $new_user to the ${G}sudo group${I}? (Y/n):  "; read -r if_sudo
            if CheckYesOrNo "$if_sudo" Y; then
                usermod -aG sudo "$new_user"
                echo -e "${G}Added${I} $new_user to sudo group."
            else 
                echo -e "${G}Skipped${I} adding $new_user to sudo group."
            fi

            Typing -n "Do you wish to add ${G}more${I} users? (y/N): "; read -r more
            CheckYesOrNo "$more" N && more=true || more=false
        done
    }

    EnsureSudoInstalled(){
        Typing "${Y}Some distros need to manually install sudo package${I}. Let's have a check..."
        if sudo -V; then
            Typing "Your system ${G}has already installed${I} sudo"
            return 0
        fi


    }

    EnableSudoGroup(){
        Typing "${Y}Some distros need to manually enable super-user privilege even for sudo group${I}. Let's have a check..."
        
        if grep -q '^ *%sudo ALL=(ALL:ALL) ALL' "$Sudoers_File"; then
            Typing "Your system ${G}has already granted${I} sudo group super user privilege. Let's simply proceed..."
            return 0
        fi
    
        Typing " ${Y}Manual enabling required.${I}."
        # It's risky to directly modify the sudoers file. Visudo is the way to go.
        # .bak file is for restoration process
        local tmp; tmp=$(CreateTmp "$Sudoers_File")
        local bak; bak=$(CreateBackup "$Sudoers_File")
        sed -i 's/^# *\(%sudo ALL=(ALL:ALL) ALL\)/\1/' "$tmp"
        if visudo -csf "$tmp"; then
            mv "$tmp" "$Sudoers_File"
            Log "$Modified_Sudoers"
            Typing "${G}Successfully granted${I} sudo group super-user privilege."
        else 
            rm "$tmp" "$bak"
            Typing -e "Something went wrong. You need manually grant later."
        fi
    }

    GenerateSshKey(){
        Typing "It's much safer to ${Y}use keys to log in${I} instead of password."
        Typing "Keys are essentially files containing long random characters, so attackers can never force their way in."
        Typing "Key can be wrapped in password again, offering double layers of protection."
        Typing "${Y}Let's generate some SSH keys!${I}"
        
        local comment all_users=("${New_Users[@]}" "$(whoami)")
        local u; for u in "${all_users[@]}"; do
            Typing "Do you wish to ${G}comment${I} the key for user ${G}$u${I}? Comment helps with ${G} identification${I}. A common practice is using email. Return if no comment."
            Typing -n "Your comment: "; read -r comment
            comment=$(Trim "$comment")

            ssh-keygen -t ed25519 -o -a 256 -C "$comment" -f "$WORKING_DIR/${Hostname}_${u}_$TIMESTAMP.key"
    
            echo -e "${G}Keys generated for user $u.${I}"
        done
        Typing "${G}All keys generated.${I}"
    }

    AddPublicKey(){
        Typing "Each generation outputs two keys: ${Y}private and public${I}. Private key is the \"passport\", while public key is adminstrator. For one private key to work, the corresponding public key must be recorded under the user's authorized_keys file."
        Typing "(One user can actually have multiple public-private key pairs)"
    
        # Back up orginal root user's key, for restoration
        [[ -f "$Root_Keys" ]] && CreateBackup "$Root_Keys"

        Log "$Added_Public_Key"
        local home all_users=("${New_Users[@]}" "$(whoami)")
        local u; for user in "${all_users[@]}"; do
            home=$(eval "echo ~$user")
            mkdir -p "$home/.ssh"
            cat "$WORKING_DIR/${Hostname}_${user}_*.pub" >> "$home/.ssh/authorized_keys"
            chown "$user:$user" "$home/.ssh/authorized_keys"
            chmod 600 "$home/.ssh/authorized_keys"
            echo -e "Added key for user $user"
        done
        Typing "${G}Successfully added all public keys.${I}"
    }

    CheckUserShell(){
        Typing "To enhance user experience, it's good to ${G}check the users' shell${I}."
        Typing "Shells are essentially interfaces allowing you to interact with the kernel with command lines, like a shell wrapper, therefore the name."
        Typing "There are many shells: dash, bash, zsh, ksh, fish... Some are optimized for desktop environment, and some are for special scenariOs, like git-shell."
        Typing "Shells are not always compatible. Thus, one shell's script may work on another."
        Typing "${G}Bash${I} should be the safest choice for most servers. It's default on many distros and the most common one. You can also try zsh if you want something fancier."

        Typing "Here's a list of shells installed on your system:"
        cat /etc/shells || { 
            Typing -e "Command \`cat /etc/shells\` can't list installed shells. You may need to manually check later."; 
            return 0; 
        }

        local answer
        for user in "${New_Users[@]}"; do
            echo -e "User $user's shell is $(getent passwd "$user" | cut -d: -f7)"
            if ! ( getent passwd "$user" | cut -d: -f7 | grep -q "/bin/bash" ) && ( grep -q "/bin/bash" /etc/shells ); then
                Typing -n "Change to bash? (Y/n): "; read -r answer
                if CheckYesOrNo "$answer" Y; then
                    chsh -s /bin/bash "$user"
                    echo -e "${G}Successfully changed${I} user $user's shell to bash."
                else 
                    echo -e "${G}Skipped${I} changing user $user's shell."
                fi
            fi
        done
        Typing "Checked all users' shell."
    }

    CheckTimeSynchronization(){
        Typing "It's important to have correct ${Y}timekeeping${I} so network and logging can work correctly."
        Typing "${Y}Let's have a fast check${I}..."

        if timedatectl show | grep -qE 'NTPSynchronized|TimeUSec' || ps aux | grep -E 'chronyd|ntpd|openntpd'; then
            Typing "${G}The system has correct timekeeping.${I}"
        else
            Typing -e "No NTP process found. You may need to troubleshoot manually later."
        fi
    }

    IncludeSshdDirectives(){
        local esc_line="Include /etc/ssh/ssh_config.d/\*\.conf"

        Typing "We are about to ${Y}edit ssh configurations${I}. It's best we avoid directly modifying $Main_Sshd_Config, but ${Y}add override files${I} under $Sshd_Directive_Dir. This allows easier roll-back just in case."
        Typing "But first we need to make sure $Main_Sshd_Config includes $Sshd_Directive_Dir..."
        if grep -Eq "^[[:space:]]*$esc_line" "$Main_Sshd_Config"; then
            Typing "Already included. Good to go."
        else
            Typing "Not included. Modifying $Main_Sshd_Config..."
            CreateBackup "$Main_Sshd_Config"
            Typing "${G}Backup created.${I}"
            Log "$Modified_Main_Ssh_Config"
            if grep -Eq "$esc_line" "$Main_Sshd_Config"; then
                sed -i "s|^[#[:space:]]*$esc_line|$esc_line|" "$Main_Sshd_Config"
            else
                sed -i "1i $esc_line" "$Main_Sshd_Config"
            fi
        fi
    }
     
    EnablePublicKeyAuthentication(){
        Typing "For key auth to work, it needs to be enabled first. Most distros should have it enabled by default."
        Typing "Overriding it nonetheless..."
        cat "PubkeyAuthentication yes" >> "$Sshd_Config"
    }
    
    ChangeSshPortAndAllow(){
        Typing "22 is the convention SSH port. It therefore expects the most attacks. It's advised to ${Y}change${I} to port within ${Y}number 49152 and 65535${I}."
        echo "(Technically you can use any port between 0 and 65535, but ports before 1024 are reserved for well-known use conventions, e.g., 53 for DNS queries and 443 for HTTPS traffic, and numbers between 1024 and 49152 are registered ports for not so well-known or other strict use cases. To avoid conflict in the future, it's best to just leave them alone.)"
        
        [[ $Initial_Ssh_Port -ne 22 ]] && Typing "${G}Your port is already not 22.${I}"

        if ! CheckOsSupport; then
            echo -e "Unfortunately, you distros is not ${Y}supported${I}. It may have default firewall applications. Changing SSH port may not get reflected automatically, therefore blocking connections to the new port."
            Typing "Refer to the distros diagnostic tutorial if you wish to change the port."
            return 0 
        fi

        Typing "Change the SSH port?"
        Typing "(Changing port won't interrupt current connection until SSH service is restarted)"
        local new_port; while true; do
            Typing -n "Type the new port, return if no change: "; read -r new_port
            new_port=$(Trim "$new_port")
            if [[ -z $new_port ]]; then
                Typing "Skipped changing SSH port."
                return 0
            elif [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -gt 0 ] && [ "$new_port" -le 65535 ]; then
                cat "Port $new_port" >> "$Sshd_Config"
                New_Ssh_Port=$new_port
                Typing "SSH port ${G}changed${I}: $(grep "^Port" "$Sshd_Config")"
                break
            else 
                Typing -e "Invalid input. Please choose a number between 0 and 65535. Let's try again."
            fi
        done
    
        if systemctl status firewalld > /dev/null 2>&1; then
            # firewall-cmd --permanent --remove-port="$Initial_Ssh_Port/tcp" # Commented out in case user has changed ssh port but doesn't restart ssh service 
            firewall-cmd --permanent --zone=public --add-port="$new_port/tcp"
            firewall-cmd --reload
        fi
        if sestatus > /dev/null 2>&1; then
            # semanage port -d -t ssh_port_t -p tcp "$Initial_Ssh_Port"
            semanage port -m -t ssh_port_t -p tcp "$new_port"
        fi
        if ufw --version > /dev/null 2>&1; then
            # ufw deny "$Initial_Ssh_Port"
            ufw allow "$new_port/tcp"
        fi
        Typing "Firewall rules updated (if there are any) to allow incoming traffic to $new_port."
        Typing "${Y}WARNING: Some server providers have an external layer of firewall${I}. You need to update it manually."
    }
    
    DisablePasswordLogin(){
        Typing "It's suggested to ${Y}disable password log-in${I} completely to minimize the risk of brute-force or dictionary attack."
        Typing "${R}WARNING${I}: Ensure that you have the private key locally before disabling!"
    
        local response
        Typing -n "Disable it? (Y/n): "; read -r response
        if CheckYesOrNo "$response" Y; then
            cat "PasswordAuthentication no" >> "$Sshd_Config"
            Typing "Password auth ${G}disabled${I}: $(grep "^PasswordAuthentication" "$Sshd_Config")"
        else 
            Typing "Skipped disabling password authentication."
        fi
    }
    
    DisableRootLogin(){
        Typing "It's suggested to ${Y}disable root log-in${I}, especially if you haven't disabled password authentication. You can still switch to root user from normal user using command \`su\`."
        Typing "(Technically you can keep root log-in if password log-in is disabled, but since it's advised to operate as normal users...)"
    
        local response
        Typing -n "Disable it? (Y/n): "; read -r  response
        if CheckYesOrNo "$response" Y; then
            cat "PermitRootLogin no" >> "$Sshd_Config"
            Typing "${G}Disabled${I} root login: $(grep "^PermitRootLogin" "$Sshd_Config")"
        else 
            Typing "${G}Skipped${I} disabling root login."
        fi
    }
    
    ChangeRootPassword(){
        [[ $(whoami) != "root" ]] && return 0
        Typing "One may often find the need to switch to root user. You may wish to ${Y}change the root password${I} to something familiar."
        Typing "${Y}WARNING${I}: This is only recommended if password or root log-in is disabled, else it's much safer to use randomly generated password."
    
        while true; do
            local response; Typing -n "Change root password? (y/N): "; read -r  response
            if CheckYesOrNo "$response" N; then
                if ! passwd; then
                    Typing -e "Something went wrong. Let's try again."
                else
                    Log "$Modified_Root_Password"
                    Typing "${G}Successfully${I} changed the root user's password."
                fi
            else
                Typing "${G}Skipped${I} changing root user's password."
                break
            fi
        done
        
    }
    
    UpdatePackages(){
        Typing "The shipped system from provider may not always be up-to-date. It's generally recommended to ${Y}update all pre-installed packages${I} in case there are security patches."
        Typing "${Y}This may take a while.${I}"
        
        if ! CheckOsSupport; then
            Typing "Unfortunately, we don't know your distro's package manager. You need to perform update manually later."
            return 0
        fi
    
        local answer; echo -n "Update? (y/N): "; read -r answer
        if CheckYesOrNo "$answer" N; then
            Log "$Updating_Packages"
            if eval "$Update_Cmd"; then
                Log "$Updated_Packages"
                Typing "${G}All packages successfully updated.${I}"
            else
                Typing -e "${R}Something went wrong${I}. You may need to troubleshoot manually later."
            fi
        else 
            Typing "${G}Skipped${I} updating packages."
        fi
    }
    
    InstallFirewall(){
        Typing "Internet is ${Y}hostile${I} towards those with public IP. Attacks happen constantly, e.g., the most common brute-force attack or DDOs attack." 
        Typing "Linux uses ${Y}Netfilter${I} to manage network operations. Tools like ${Y}iptables and nftables${I} builds on it, offering interfaces for management."
        Typing "You can use nftables or iptables directly for ${Y}advanced routing rules${I}. But most servers, there are much more user-friendly tools built on them."
    
        case "$Os" in
            debian|ubuntu)
                Typing "For Debian-based distros, ${G}ufw${I} is a solid choice."
                InstallUfw
                ;;
            almalinux|centos|rocky|fedora)
                Typing "RHEL-based distros ship with ${G}Firewalld${I} with predefined rules by default. No more action is needed."
                ;;
            *)
                Typing "Your distro $Os is ${Y}not supported${I}. It may or may not have a firewall pre-installed. Please refer to the distro's official doc."
                ;;
        esac
    }
    
    InstallFail2Ban(){
        Typing "${Y}Fail2Ban${I} is another tool to protect servers. Unlike firewall inspecting raw networks packets directly, Fail2Ban scans the system log and bans visitors with too many failures."
        Typing "It has ${Y}rich and powerful${I} features: It can do random increment, send mails, report malicious IP..."
        Typing "Many features require sepecial configuration, but it still ${Y}works out of box${I} with default protection over many protocols, including SSH."
        Typing "However, it's ${Y}not strictly neccessary${I} to install Fail2Ban, especially if password auth is already disabled."
    
        if command -v fail2ban >/dev/null 2>&1; then
            Typing "${G}Fail2Ban already installed. Skipping...${I}"
            return 0
        fi
    
        local response; Typing -n "Install Fail2Ban? (Y/n): "; read -r response
        if ! CheckYesOrNo "$response" Y; then
            Typing "${G}Skipped${I} installing Fail2Ban."
            return 0
        fi
        
        case "$Os" in
            debian|ubuntu)
                $Install_Cmd fail2ban
                Typing "Fail2Ban ${G}successfully installed${I}."
                ;;
            almalinux|centos|rocky|fedora)
                Typing "For RHEL-based distributions, Fail2Ban is inside Extra Packages for Enterprise Linux (EPEL) repository. (The default Red Hat Enterprise Linux (RHEL) repository only offers core packages.)"
                Typing "Let's first enable that repository."
                $Install_Cmd epel-release
                Typing "EPEL repository ${G}successfully enabled${I}."
                $Install_Cmd fail2ban
                Typing "Fail2Ban ${G}successfully installed${I}."
                ;;
            *)
                Typing "Your system $Os is ${Y}currenly not supported${I}. You may need to install manually later."
                return 0 
        esac \
        && Log "$Installed_Fail2Ban" \
        || { ReportInstallFailure "Fail2Ban"; return 0; }
        

        local default_config="/etc/fail2ban/fail2ban.conf"
        local local_cnfig="/etc/fail2ban/fail2ban.local"
        cp "$default_config" "$local_cnfig"
        local max_retry; max_retry=$(grep -m1 "^maxretry" $local_cnfig | awk -F= '{print $2}' | tr -d ' ')
        local ban_time; ban_time=$(grep -m1 "^bantime" $local_cnfig | awk -F= '{print $2}' | tr -d ' ')
        local find_time; find_time=$(grep -m1 "^findtime" $local_cnfig | awk -F= '{print $2}' | tr -d ' ')
        Typing "Your current configuration bans failed attempts for $ban_time after $max_retry times within $find_time."
    
        systemctl enable fail2ban
        systemctl start fail2ban
        Typing "Fail2Ban started and is now protecting your server."
    }
    
    InstallUfw(){
        Typing "ufw stands for ${Y}Uncomplicated Firewall${I}. It's a simple yet user-friendly firewall tool built on iptables."
        
        if command -v ufw >/dev/null 2>&1; then
            Typing "${G}ufw already installed. Skipping...${I}"
            return 0
        fi
    
        Typing "Install ufw? Don't worry if you don't. A default nftable rules will apply to protect your server."
        local response; Typing -n "Your answer (Y/n): "; read -r response
        if ! CheckYesOrNo "$response" Y; then
            Typing "${G}Skipped${I} installing ufw."
            SetUpDefaultNftablesRules
        else
            Typing "Installing ufw..."
            if $Install_Cmd ufw; then
                Log "$Installed_Ufw" 
                Typing "ufw ${G}successfully installed${I}."
            else
                ReportInstallFailure "ufw"
                return 0
            fi
            
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow "$Initial_Ssh_Port/tcp"
            [[ -n $New_Ssh_Port ]] && ufw allow "$New_Ssh_Port/tcp"
            Typing "Denied all inbound connection except towards SSH port. Allowed any outbound connection."
        
            ufw enable
            Typing "ufw enabled and will start automatically at boot."
        fi
    }
    
    SetUpDefaultNftablesRules(){
        if ! command -v nft > /dev/null 2>&1; then
            Typing "Nftables not installed. Installing..."
            if $Install_Cmd nftables; then
                Log "$Installed_Nftables"
                Typing "${G}Successfully installed.${I}"
            else
                ReportInstallFailure "nftables"
                Typing "You are ${R}strongly advised${I} to set up firewall manually later."
                return 0
            fi
        fi

        nft list ruleset > "$Nftables_Dir/nft.$TIMESTAMP.bak"
        Typing "Original nftables rules backed up."
    
        nft -f <"$(TemplateNftables)"
        Log "$Modified_Nftables_Rule"
        [[ -n $New_Ssh_Port ]] && nft add rule inet filter input tcp dport "$New_Ssh_Port" accept
        Typing "Nftables rules added."

        sudo nft list ruleset | sudo tee /etc/nftables.conf >/dev/null
        systemctl enable nftables
        systemctl start nftables
        Typing "Nftables enabled as system service. The rule will persist after reboot."

        nft add rule inet filter input tcp dport "$Initial_Ssh_Port" accept # In case user has changed ssh port but doesn't restart ssh service 
    }

    CreateBackup(){
        local bak="$1.$TIMESTAMP.bak"
        cp "$1" "$bak"
        echo "$bak"
    }
    
    CreateTmp(){
        local tmp="$1.$TIMESTAMP.tmp"
        cp "$1" "$tmp"
        echo "$tmp"
    }

    LogUser(){
        echo "$1" >> "$User_Record"
    }

    ReportInstallFailure(){
        Typing -e "Something went wrong installing $1. You may need to install manually later."
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
}

RemoteSetUp1(){
    CheckIfSudo

    InitializeSystemInfo
    echo

    ChangeHostname
    echo

    EditHostsFile
    echo

    AddNewUser
    echo

    EnsureSudoInstalled
    echo

    EnableSudoGroup
    echo

    GenerateSshKey
    echo

    AddPublicKey
    echo
}

RemoteSetUp2(){
    CheckIfSudo

    InitializeDistroInfo || true
    ParseUserFromRecord New_Users
    echo

    CheckUserShell
    echo

    CheckTimeSynchronization
    echo

    IncludeSshdDirectives
    echo

    EnablePublicKeyAuthentication
    echo

    ChangeSshPortAndAllow
    echo

    DisablePasswordLogin
    echo

    DisableRootLogin
    echo
    
    ChangeRootPassword
    echo

    UpdatePackages || { 
        Typing -e "Something went wrong. Failed to update packages. You may need to update manually. Skip firewall related setup..."
        exit 0 
    }
    echo

    InstallFirewall
    echo

    InstallFail2Ban
    echo
}

InitializeRemoteRestore(){
    CheckAnySetup(){
        if [[ ! -f "$Log_File" ]]; then 
            Typing "Nothing to restore server-side. Skipping..."
            exit 0
        fi
    }

    InitializeSystemInfo(){
        InitializeDistroInfo || true
        Typing "Uninstall command for your distro $Os is: $Uninstall_Cmd"
    }
    
    FinishUpdate(){
        if ! CheckLog "$Updating_Packages"; then
            Typing "Packages weren't updated. ${G}Skipping${I}..."
            return 0
        fi

        if CheckLog "$Updated_Packages"; then
            Typing "${Y}Packages were updated${I}. It ${Y}can't be reversed${I}, but it won't do you any harm."
            return 0
        fi

        Typing "Package update went wrong mid-way. While this is irreversible, partial update can be dangerous. Let's finish what we started."
        Typing "Finishing packages updating..."
        if eval "$Update_Cmd"; then 
            Log "$Updated_Packages"
            Typing "${G}All packages updated successfully.${I}"
            return 0
        else
            Typing -e "Update failed again :( You need to troubleshoot manually later."
            return 1
        fi
    }  
    
    UninstallFail2Ban(){
        if ! CheckLog "$Installed_Fail2Ban"; then
            Typing "Didn't install Fail2Ban. Skipping..."
            return 0
        fi
        
        if UninstallElseReport fail2ban; then
            rm -rf /etc/fail2ban
            rm -rf /var/log/fail2ban.log /var/lib/fail2ban
        fi
    }
    
    UninstallUfw(){
        if ! CheckLog "$Installed_Ufw"; then
            Typing "Didn't install ufw. Skipping..."
            return 0
        fi

        UninstallElseReport ufw || true
    }
    
    RestoreNftables(){
        if CheckLog "$Installed_Nftables"; then
            UninstallElseReport ufw || true
        elif CheckLog "$Modified_Nftables_Rule"; then
            nft flush ruleset
            nft -f "$Nftables_Dir/"*"$TIMESTAMP".bak
            Typing "${G}Nftable rules recovered${I}."
        else
            Typing "Didn't configure nftable. ${G}Skipping${I}"
        fi
    }
    
    RestoreHostname(){
        if ! CheckLog "$Modify_Hostname"; then
            Typing "Hostname not changed. ${G}Sikpping...${I}"
            return 0
        fi
    
        RestoreBackup "$Hostname_File"
    
        if ! CheckLog "$Modify_Hosts_File"; then
            Typing "File /etc/hosts not touched. ${G}Sikpping...${I}"
        else
            RestoreBackup "$Hosts_File"
            Typing "${G}Restored $Hosts_File.${I}"
        fi
    }
    
    RestoreSudoers(){
        if ! CheckLog "$Modified_Sudoers"; then
            Typing "Sudoers file wasn't modified. ${G}Skipping${I}."
            return 0
        fi
    
        RestoreBackup "$Sudoers_File"
        Typing "${G}Restored $Sudoers_File.${I}"
    }
    
    RemoveUsers(){
        if [[ ! -f "$User_Record" ]]; then
            Typing "No new user was created. ${G}Skipping${I}"
            return 0
        fi
    
        local -a users
        ParseUserFromRecord users
        local u; for u in "${users[@]}"; do
            pkill -u "$u"
            userdel -r "$u"
            Typing "Removed user $u."
        done
    
        Typing "${G}All created users removed.${I}"
        Typing "Remaining user:"
        ls /home
        Typing "There may be existing users before thisscript or whom holding others' files. You may need to remove them manually later."
    }
    
    RestoreRootKey(){
        ! CheckLog "$Added_Public_Key" && return 0
        RestoreBackup "$Root_Keys"
    }
    
    RestoreSshdConfig(){
        if ! CheckLog "$Modified_Main_Ssh_Config"; then
            Typing "Didn't modify $Main_Sshd_Config. ${G}Skipping${I}"
            return 0
        fi

        RestoreBackup "$Main_Sshd_Config"
        
        # local initial_port=$SSH_PORT
        local new_port; new_port=$(grep -E "^[[:space:]]*Port" "$Sshd_Config" | awk '{print $2}')
        if systemctl status firewalld > /dev/null 2>&1; then
            firewall-cmd --permanent --remove-port="$new_port/tcp"
            # firewall-cmd --permanent --zone=public --add-port="$initial_port/tcp"
            firewall-cmd --reload
        fi
        # if sestatus > /dev/null 2>&1; then
        #   semanage port -m -t ssh_port_t -p tcp "$initial_port"
        # fi
        if ufw --version > /dev/null 2>&1; then 
            ufw deny "$new_port"
            # ufw allow "$initial_port/tcp"
        fi
        Typing "Firewall rules restored."

        rm "$Sshd_Config"
        Typing "SSH config restored. "
    }
    
    InformRootPasswordChange(){
        if CheckLog "$Modified_Root_Password"; then
            Typing "Root user passwrod changed. However, this is irreversible as original password isn't recorded."
        fi
    }

    UninstallElseReport(){
        if [[ -z $1 ]]; then
            Typing -b "Uninstall is called without argument."
            return 0
        fi
        if $Uninstall_Cmd $1; then
            Typing "${G}$1 uninstalled${I}."
            return 0
        else
            Typing -e "Something went wrong uninstalling $1. You may need to uninstall manually later."
            return 1
        fi
    }

    RestoreBackup(){
        local file_name=$1
        local folder; folder=$(dirname "$1")
        [[ ! -f file_name ]] && { Typing -b "Not providing file path"; exit 1; }
        mv "$folder"/*"$TIMESTAMP"* "$file_name"
    }
}

RemoteRestoreMain(){
    CheckIfSetupAnything

    InitializeSystemInfo
    echo

    FinishUpdate
    echo

    UninstallFail2Ban
    echo

    UninstallUfw
    echo

    UninstallOrRestoreNftables 
    echo

    RestoreHostname
    echo

    RestoreSudoers
    echo

    RemoveUsers
    RestoreRootKey
    echo

    RestoreSshdConfig
    echo

    InformRootPasswordChange
    echo
}

set -eu
InitializeAllShared
InitializeLocal
LocalMain "$@"