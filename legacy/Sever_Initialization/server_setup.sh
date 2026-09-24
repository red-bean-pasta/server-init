#! /bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG_PATH="$SCRIPT_DIR/log"
USER_LOG_PATH="$SCRIPT_DIR/user.log"

source "$SCRIPT_DIR/common.sh"

NFTABLES_BASE="$SCRIPT_DIR/base.nft"
NFTABLES_BACKUP="$SCRIPT_DIR/backup.nft"
ROOT_KEYS_BACKUP="$SCRIPT_DIR/root_authorized_keys"

SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
SUDOERS_CONFIG_FILE="/etc/sudoers"

NEW_USERS=()

OS=""
UPDATE_CMD=""
INSTALL_CMD=""

SSH_PORT=$(grep -E "^[[:space:]]*#?[[:space:]]*Port" $SSHD_CONFIG_FILE | awk '{print $2}')
NEW_SSH_PORT=""

HOSTNAME=""

Main(){
    # Exit once error is encountered rather than continuing
    set -e

    CheckIfSudo

    InitializeSystemInformation
    echo

    if [[ $1 == "--part1" ]]; then
        ChangeHostname
        echo

        AddNewUser
        echo

        EnableSudoGroup
        echo

        GenerateSshKey
        echo

        AddPublicKey
        echo

        CheckUserShell
        echo
    elif [[ $1 == "--part2" ]]; then
        CheckTimeSynchronization
        echo

        CreateSshConfigBackup
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

        UpdatePackages || ( Typing "${R}ERROR${I}: Failed to update packages. You may need to update manually. Skip firewall related setup..." && exit 0 )
        echo

        InstallFirewall
        echo

        InstallFail2Ban
    else
        echo "Error: Unknown command: $1"
    fi
}

InitializeSystemInformation(){
    Typing "Some features of this script ${Y}aren't applicable to all Linux distributions${I}. Different distribution has different package managing system and default environment, and this script can't cover all of them. Don't worry, those features aren't that big a deal, and you can always set them up manually."

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS=$ID
    else 
        Typing "${R}ERROR${I}: Can't determine your system's distribution. Maybe it's a legacy version, as we can't find the file /etc/os-release."
        OS="unsupported"
        return 1
    fi

    case "$OS" in
        almalinux|centos|rocky)
            UPDATE_CMD="dnf update -y"
            INSTALL_CMD="dnf install -y"
            ;;
        debian|ubuntu)
            UPDATE_CMD="export DEBIAN_FRONTEND=noninteractive && apt-get update -y && apt-get dist-upgrade -o Dpkg::Options::=\"--force-confold\" -o Dpkg::Options::=\"--force-confdef\" && apt-get autoremove -y"
            INSTALL_CMD="apt-get install -y"
            ;;
        fedora)
            UPDATE_CMD="dnf upgrade --refresh -y"
            INSTALL_CMD="dnf install -y"
            ;;
        *)
            Typing "${Y}Unfortunately${I} your system $OS is currenly not supported. Currently we only support debian, ubuntu, almalinux, centos, rocky and fedora."
            OS="unsupported"
            return 1
            ;;
    esac

    Typing "Your system $OS is ${G}supported${I}."
    echo -e "The command to update packages is: $UPDATE_CMD"
    echo -e "The command to install new packages is: $INSTALL_CMD"
}

ChangeHostname(){
    Typing "You can ${Y}name this system${I}. It helps with identification. "

    # Check current hostname
    local original_hostname
    if hostnamectl status --static > /dev/null ; then
        original_hostname=$(hostnamectl status --static)
        HOSTNAME="$original_hostname"
        Typing "Your current host name is $original_hostname."
    else
        echo -e "${R}Error${I}: Can't check your current hostname."
        Typing "No worries. Let's proceed first. You can always change your hostname manually afterwards."
        return 0
    fi

    # Retrieve and check new hostname
    Typing "Maybe you have some better name in mind?"

    local new_hostname
    Typing -n "Type the new hostname, or blank if you don't wish to change(Note that blank space is not allowed): "
    read -r new_hostname
    new_hostname="$(Trim "$new_hostname")"

    while echo "$new_hostname" | grep -q " "; do
        echo -e -n "${R}Error${I}: You seemed to have typed some blank spaces. ${R}NO BLANK SPACE IS ALLOWED${I}. Please try again: "
        read -r new_hostname
        new_hostname="$(Trim "$new_hostname")"
    done

    if [[ -z "$new_hostname" ]]; then
        Typing "${G}Skipped${I} changing hostname."
    else
        HOSTNAME="$new_hostname"
        hostnamectl set-hostname "$new_hostname"
        Log "$HOSTNAME_LOG $original_hostname"
        Typing "Hostname ${G}successfully changed${I} to $(hostnamectl status --static)."

        Typing "We also need to make changes to the file /etc/hosts. It's a historic file recording the mapping between hostname and local IP, and is still referenced by some tools."
        if [[ $OS == "unsupported" ]]; then
            Typing "However, since we don't know your distribution nor the structure of your /etc/hosts file, we can't make changes."
            Typing "You may need to modify it manually afterwards."
            return 0
        fi

        cp /etc/hosts /etc/hosts.bak
        Typing "Backup file created: /etc/hosts.bak"
        Log "$HOSTS_FILE_MODIFIED_LOG"

        if grep -q "/etc/cloud/" /etc/hosts; then
            Typing "Your server's provider uses Cloud-Init to manage systems, which means after your server machine reboot, it will automatically follow templates provided by the cloud, thus erase any change made to the local configs, including hostname."
            Typing "You may need to manually disable Cloud-Init or change the template to make things persist."
        fi

        case "$OS" in
            debian|ubuntu)
                if grep -q "127.0.1.1" /etc/hosts; then
                    sed -i "s/^ *127.0.1.1.*/127.0.1.1 $new_hostname/" /etc/hosts
                else
                    echo "127.0.1.1 $new_hostname" > /etc/hosts
                fi
                ;;
            almalinux|centos|rocky|fedora)
                if grep -q "127.0.0.1" /etc/hosts; then
                    sed -i "s/^ *127.0.0.1.*/127.0.0.1 $new_hostname $new_hostname.localdomain $new_hostname.localdomain4/" /etc/hosts
                else
                    echo "127.0.0.1 $new_hostname $new_hostname.localdomain $new_hostname.localdomain4" > /etc/hosts
                fi

                if grep -q "::1" /etc/hosts; then
                    sed -i "s/^ *::1.*/::1 $new_hostname $new_hostname.localdomain $new_hostname.localdomain6/" /etc/hosts
                else
                    echo "::1 $new_hostname $new_hostname.localdomain $new_hostname.localdomain6" > /etc/hosts
                fi
                ;;
        esac

        Typing "${G}Successfully modified /etc/hosts.${I}"
    fi
}

AddNewUser(){
    Typing "It's generally advised to operate as ${Y}none-root user${I}. Operating as root user may accidentally cause irreversible harms, e.g. permanent deletion of important files."
    Typing "You can still gain root user's power if the user you're operating is in the \"sudo\" group, which means \"superuser do.\""
    Typing "${Y}So Let's first create a new user!${I}"
    Typing "Note that ${Y}blank space is not allowed in user name${I}, so use _ instead, e.g. \"Teddy_Bear\"."
    
    local is_adding_user=true
    local new_user
    local sudo_response
    local more_user_response
    local is_password_match="false"

    while $is_adding_user; do
        Typing -n "What name you wish for this new user?: "
        read -r new_user

        new_user="$(Trim "$new_user")"

        if useradd -m "$new_user"; then
            echo -e "${G}User $new_user added!${I}"

            LogUser "$new_user"

            while [[ $is_password_match == false ]]; do
                if passwd "$new_user"; then
                    is_password_match=true
                else
                    Typing "Retrying setting password..."
                fi
            done

            # Some server or distributions has weird bug, 
            # that when a new user is added, their home directory is under the root user's control, not theirs.
            chown -R "$user":"$user" "/home/$user"

            NEW_USERS+=("$new_user")

            # Check if it's sudo user 
            Typing "Do you want to add this user to ${G}sudo group${I}?"
            echo -e "As mentioned, anyone inside sudo group can gain super user power by appending \"sudo\" before commands."
            echo -e -n "Your answer? (Y/n):"
            read -r sudo_response

            if CheckYesOrNo "$sudo_response" "y"; then
                usermod -aG sudo "$new_user"
                echo -e "${G}Added${I} $new_user to sudo group."
            else 
                echo -e "${G}Skipped${I} adding $new_user to sudo group."
            fi

            # Check if there's more user to add
            Typing -n "Do you wish to add ${G}more${I} users?(y/N): " 
            read -r more_user_response
            if CheckYesOrNo "$more_user_response" "n"; then
                is_adding_user=true
            else 
                is_adding_user=false
            fi

        else 
            echo -e "${R}Error${I}: Failed to add user $new_user. Did you type blank space? Note that blank space is not allowed."
            Typing "Don't worry. Let's try it again."
            is_adding_user=true
        fi
    done
}

EnableSudoGroup(){
    Typing "${Y}Some Linux distribution might quire manually enabling super user privilege for sudo group${I}, so let's first have a quick check..."
    
    if grep -q '^ *%sudo ALL=(ALL:ALL) ALL' "$SUDOERS_CONFIG_FILE"; then
        Typing "Your system ${G}already granted${I} sudo group super user privilege. Let's simply proceed to the next operation."
        return 0
    fi

    Typing "Your system ${Y}hasn't granted${I} privilege to sudo group."
    
    # It's risky to directly modify the sudoers file. 
    # Linux offers visudo tool to modify and check sudoers file.
    # .bak file is for restoration process
    local tmp_file="$SUDOERS_CONFIG_FILE.tmp"
    local bak_file="$SUDOERS_CONFIG_FILE.bak"
    cp "$SUDOERS_CONFIG_FILE" "$bak_file"
    cp "$SUDOERS_CONFIG_FILE" "$tmp_file"
    sed -i 's/^# *\(%sudo ALL=(ALL:ALL) ALL\)/\1/' "$tmp_file"
    
    if visudo -csf "$tmp_file"; then
        mv "$tmp_file" "$SUDOERS_CONFIG_FILE"
        Typing "${G}Successfully granted${I} sudo group super user privilege."
        Log "$SUDOERS_LOG"
    else 
        rm "$tmp_file" "$bak_file"
        Typing "${R}ERROR${I}: Something went wrong. You may need to grant sudo privilege manually later."
    fi
}

GenerateSshKey(){
    Typing "It's much safer to ${Y}use keys${I} instead of password to log in."
    Typing "Key is essentially a file contains a long sequence of random characters, thus attackers can never force their way."
    Typing "Key can also be wrapped in password, thus double layers of protection."
    Typing "${Y}So let's generate some SSH key pairs!${I}"
    
    local user
    local comment
    local all_users=("${NEW_USERS[@]}" "$(whoami)")
    for user in "${all_users[@]}"; do
        echo -e "Do you wish to ${G}comment${I} the key for user ${G}$user${I}? A common practice is using ${G}your email${I}. Comment can be helpful for ${G}future identification${I}."
        echo -e -n "Your ${G}comment${I}, or simply return if no comment: "
        read -r comment

        ssh-keygen -t ed25519 -o -a 256 -C "$comment" -f "$SCRIPT_DIR/${HOSTNAME}_${user}.key"

        echo -e "${G}Key for user $user generated.${I}"
    done

    Typing "${G}All key pairs generated.${I}"
}

AddPublicKey(){
    Typing "We've actually generated both ${Y}private and public${I} keys. Private Key is kept at the your end as your \"passport\", while public key is kept by the server to adminstrate."
    Typing "One user can have multiple public-private key pairs, though normally one should suffice."
    Typing "Let's add generated public keys to corresponding user! Normally, one user's public keys are all recorded in a single file called \"authorized_keys\", under their own \".ssh\" folder."

    local user
    local user_home_dir
    local all_users=("${NEW_USERS[@]}" "$(whoami)")

    # Back up orginal root user's key, for restoration
    if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
        cp "$HOME/.ssh/authorized_keys" "$ROOT_KEYS_BACKUP"
    fi

    for user in "${all_users[@]}"; do
        user_home_dir=$(eval echo ~"$user")
        mkdir -p "$user_home_dir/.ssh"

        cat "$SCRIPT_DIR/${HOSTNAME}_${user}.key.pub" >> "$user_home_dir/.ssh/authorized_keys"
        
        chmod 600 "$user_home_dir/.ssh/authorized_keys"
        chown "$user:$user" "$user_home_dir/.ssh/authorized_keys"

        echo -e "${G}Added${I} key for user $user"
    done

    Log "$PUBLIC_KEY_LOG"

    Typing "${G}All public keys are successfully added${I}."
}

CheckUserShell(){
    Typing "To enhance user experience, it's a great idea to ${G}check user's shell${I}. Shell is essentially an application that allows you to interact the operating system by typing command lines, like the one you are using right now! It's called \"Shell\" exactly because it acts like a shell wrapper around the kernel of the operating system."
    Typing "There're various of shells: dash, bash, zsh, ksh, fish... Some of them are optimized for desktop environment, with rich user-friendly features, and some are for special use cases, e.g. git-shell and systemd-home-fallback-shell."
    Typing "While they are all shells, they are not always compatible, thus the shell script you wrote or downloaded may not always work."
    Typing "For most server, ${G}bash${I} should be the best choice. It's also the default shell on many distributions, also the most common one for scripting. If you want something fancier, you could also try zsh, it's compatible with bash."

    Typing "Here's a list of shells installed on your system:"

    cat /etc/shells || ( Typing "${Y}ERROR${I}: Something seems to go wrong. Command \`cat /etc/shells\` can't list installed shells. You may need to trouble shoot manually later. Don't worry, we can still proceed!" ; return 0 )

    for user in "${NEW_USERS[@]}"; do
        echo -e "User $user's shell is $(getent passwd "$user" | cut -d: -f7)"
        
        local answer
        if ! ( getent passwd "$user" | cut -d: -f7 | grep -q "/bin/bash" ) && ( grep -q "/bin/bash" /etc/shells ); then
            Typing -n "Do you wish to change their shell to bash? (y/N): "
            read -r answer

            if CheckYesOrNo "$answer" "n"; then
                chsh -s /bin/bash "$user"
                echo -e "${G}Successfully changed${I} user $user's shell to bash."
            else 
                echo -e "${G}Skipped${I} changing user $user's shell."
            fi
        fi
    done

    Typing "All user's shell checked."
}

CheckTimeSynchronization(){
    Typing "It's important to have correct ${Y}timekeeping${I} so that network and log can work correctly."
    Typing "Most Linux distributions handles this ${Y}automatically${I} using systemd-timesyncd service, yet still let's have a fast ${Y}check${I}..."

    local status
    # If the timesyncd service is not loaded or active, systemctl will throw error besides outputing information
    # causing the whole script exit 
    # thus use || true to catch error
    status="$(systemctl status systemd-timesyncd || true)"
    
    echo -e "$status"

    if echo "$status" | grep -q "Loaded: loaded"; then
        Typing "systemd-timesyncd service is ${G}loaded${I}."
    else
        Typing "systemd-timesyncd service ${R}is not loaded${I}."
        Typing "${R}You may need to check what's wrong later manually.${I}"
        return 0
    fi

    if echo "$status" | grep -q "Active: active (running)"; then
        Typing "systemd-timesyncd service is ${G}active and running${I}."
    else
        Typing "systemd-timesyncd service is ${R}not active${I}."
        Typing "${R}You may need to check what's wrong later manually.${I}"
        return 0
    fi

    Typing "${B}(If the status is connected with some IP or server, it should mean it's working)${I}"
}

CreateSshConfigBackup(){
    Typing "We are about to ${Y}edit the server's ssh config${I} file to improve security..."
    cp -i "$SSHD_CONFIG_FILE" "${SSHD_CONFIG_FILE}.bak"
    Typing "${G}Backup created${I} under $SSHD_CONFIG_FILE.bak"
    Log "$SSH_BACKUP_LOG"
}

EnablePublicKeyAuthentication(){
    Typing "For public key authentication to work, we first need to make sure it's enabled. Most distributions should enabled it by default."
    grep -q "PubkeyAuthentication yes" "$SSHD_CONFIG_FILE" && Typing "Public key authentication already enabled. ${G}Skipping...${I}" && return 0
    Typing "Public key authentication isn't enabled. Let's enable it."
    sed -i "s/^ *PubkeyAuthentication.*/PubkeyAuthentication yes/" "$SSHD_CONFIG_FILE"
    Typing "Public key authentication ${G}enabled${I}: $(grep "PubkeyAuthentication" "$SSHD_CONFIG_FILE")"
}

ChangeSshPortAndAllow(){
    Typing "22 is the default SSH port for almost all servers, so it will also expect most attacks. It's advised to ${Y}change it${I}."
    Typing "Port within ${Y}number 49152 and 65535${I} would a good choice. Why? Well, technically you can use any number between 0 and 65535, but numbers before 1024 are normally reserved for well-known use conventions, e.g. 53 for DNS queries and 443 for HTTPS traffic; and numbers between 1024 and 49152 are registered ports, with registered but not that well-known or strict use cases. To avoid conflict in the future, it's best to just leave them alone."
    
    if [[ $OS == "unsupported" ]]; then
        echo -e "However, since your distribution is ${Y}unsupported${I}, we can't perform such operation, as your system may has some network firewall application whose rules aren't updated automatically, and then you may lose connection with this server, forever!"
        Typing "If you want to change your SSH port, you may need to follow tutorials specific to your distribution."
        return 0 
    fi

    local is_changing_port=true
    local new_port=""

    Typing "Do you wish to change SSH port? Don't worry, changing the port won't affect current connection. It will only take effect after someone restarts the SSH service."
    while [[ $is_changing_port == true ]]; do
        Typing -n "Type the new port, or simply return if you don't wish to change: "
        read -r new_port

        if [[ -z $(Trim "$new_port") ]]; then
            Typing "SSH port ${G}not changed${I}."
            is_changing_port=false
            return 0
        elif [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -gt 0 ] && [ "$new_port" -le 65535 ]; then
            sed -i "s/^#\?Port.*/Port $new_port/" "$SSHD_CONFIG_FILE"
            NEW_SSH_PORT=$new_port
            Typing "SSH port ${G}changed${I}: $(grep "^Port" "$SSHD_CONFIG_FILE")"
            is_changing_port=false
            return 0
        else 
            Typing "${R}Error${I}: Your input seems to be invalid. Please choose a number between 0 and 65535. Don't worry, let's try again."
            is_changing_port=true
        fi
    done

    if systemctl status firewalld > /dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="$SSH_PORT/tcp"
        firewall-cmd --permanent --zone=public --add-port="$new_port/tcp"
        firewall-cmd --reload
    fi

    if sestatus > /dev/null 2>&1; then
        semanage port -m -t ssh_port_t -p tcp "$new_port"
    fi

    if ufw --version > /dev/null 2>&1; then
        ufw deny "$SSH_PORT"
        ufw allow "$new_port/tcp"
    fi

    Typing "Firewall rules updated(if there are any) to allow traffic to $new_port."
    Typing "${Y}Some server providers may even have another layer of firewall${I}. If so, you may need to update it manually, typically at [Provider's Official Website - Your Account Page - Control Panel of This Server - Firewall]."
}

DisablePasswordLogin(){
    Typing "It's suggested to ${Y}disable password log-in${I} completely to maximize security. Then, only ones with ${Y}private keys${I} can log in, minimizing the risk of brute-force or dictionary attack."
    Typing "${R}WARNING:${I} ${Y}Ensure that you can keep the private key on your local machine before disabling this!${I}"

    local response
    Typing -n "Disable it? (Y/n):" 
    read -r response

    if CheckYesOrNo "$response" "y"; then
        sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" "$SSHD_CONFIG_FILE"
        Typing "Password authentication ${G}disabled${I}: $(grep "^PasswordAuthentication" "$SSHD_CONFIG_FILE")"
    else 
        Typing "${G}Skipped${I} disabling password authentication."
    fi
}

DisableRootLogin(){
    Typing "It's suggested to ${Y}disable root log-in${I} completely for security, especially if you haven't disabled password authentication. You can still switch to root user from normal user using command \"su\"."
    Typing "Technically you can keep root log-in if password authentication is disabled. But since it's advised to operate as normal user, disabling root log-in is simply an ensurement of that."

    local response
    Typing -n "Disable it? (Y/n): "
    read -r  response

    if CheckYesOrNo "$response" "y"; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG_FILE"
        Typing "${G}Disabled${I} root login: $(grep "^PermitRootLogin" "$SSHD_CONFIG_FILE")"
    else 
        Typing "${G}Skipped${I} disabling root login."
    fi
}

ChangeRootPassword(){
    Typing "One may still need to switch to root user under some special cases. You may want to ${Y}change the root password${I} to something easier to memorize."
    Typing "${Y}Note${I}: This is only recommended if you've disabled password authentication or root log-in, else it's much safer to use the password your provider radomly generated."

    local response
    Typing -n "Change it? (y/N): "
    read -r  response

    if CheckYesOrNo "$response" "n"; then
        while ! passwd; do
            echo -e "${R}Error${I}: something seems to go wrong in changing the password. Let's try again."
        done
        
        Log "$ROOT_PASSWORD_LOG"

        Typing "${G}Successfully${I} changed the root user's password."
    else
        Typing "${G}Skipped${I} changing root user's password."
    fi
}

UpdatePackages(){
    Typing "When you made your purchase, the shipped system may not always be the most up to date. It's generally recommended to ${Y}update all the pre-installed packages${I}, as they may contain essential security patches."
    Typing "It ${Y}may take a while${I}, depending the package count, and the network environment."
    
    if [[ $OS == "unsupported" ]]; then
        Typing "However, we don't know your system's package manager and update command. If you wish to update your packages, you may need to do it manually later."
        return 0
    fi

    local answer
    Typing -n "Do you wish to update all pre-installed packages? (y/N): "
    read -r answer

    if CheckYesOrNo "$answer" "n"; then
        Log "$UPDATE_LOG"
        eval "$UPDATE_CMD"
        Log "$UPDATE_FINISHED_LOG"
        Typing "${G}All packages successfully updated.${I}"
    else 
        Typing "${G}Skipped${I} updating packages."
    fi
}

InstallFirewall(){
    Typing "The ${Y}internet is a dangerous place${I} for server with public IP. You may expect many attacks, e.g. the most common brute-force attack or DDoS attack." 
    Typing "Linux system manages network related operations with ${Y}Netfilter${I}. There are tools like ${Y}iptables and nftables built on it that offers interfaces${I} to manage netfilter."
    Typing "Nftables is iptables' successor. It's main advantage is much more flexible syntax. But they are compatible and can co-exist."
    Typing "You can use nftables or iptables if you need ${Y}advanced routing rules${I} that rerquires manual setup. But ${Y}for most anti-attack use cases${I}, firewall tools built on them should suffice, and offers much more user-friendliness."

    case "$OS" in
    debian|ubuntu)
        Typing "For Debian-based system, such as Debian itself, or Ubuntu, tool like ufw is a solid choice."
        InstallUfw
        ;;
    almalinux|centos|rocky|fedora)
        Typing "RHEL-based distributions, such as your $OS, tool ${G}Firewalld is shipped${I} with predefined rules by default, so no more action is needed."
        ;;
    *)
        echo -e "Your system $OS is ${Y}currenly not supported${I}. It may or may not has a firewall shipped with predefined rules already. You may need to refer to the distribution's official page."
        ;;
    esac

    Typing "You can further mitigate risk with ${G}Cloudflare CDN${I} or ${G}Virtual Local Area network${I}, depending on your use case. These are quite advanced, and requires your manual setup."
}

InstallFail2Ban(){
    Typing "${Y}Fail2Ban${I} is another tool that offers more protection. Unlike firewall that counts abnormal network packet frequency, Fail2Ban inspects the system log and bans IP that failed too many times."
    Typing "It has many ${Y}rich and powerful${I} features: It can randomly increment ban time, send mails to your account about banned IP, and help reporting them to related websites. Its protection covers many use cases, whether your server is for hosting websites, or storaging files, or resolving DNS queries."
    Typing "While many of that requires sepecial configuration, Fail2Ban still ${Y}works out of box${I}, with default protection over many services, including SSH."
    Typing "However, it's not strictly neccessary to install Fail2Ban, especially if password authentication is already disabled."

    if systemctl status fail2ban > /dev/null 2>&1; then
        echo -e "${G}Fail2Ban already installed. Skipping...${I}"
        return 0
    fi

    if [[ $OS == "unsupported" ]]; then
        echo -e "Your system $OS is ${Y}currenly not supported${I}. If you wish, you may need to install manually later ."
        return 1 
    fi

    local response
    Typing -n "Do you wish to install Fail2Ban? (Y/n):"
    read -r response

    if ! CheckYesOrNo "$response" "y"; then
        Typing "${G}Skipped${I} installing Fail2Ban."
        return 0
    fi

    case "$OS" in
        debian|ubuntu)
            eval "$INSTALL_CMD fail2ban"
            Typing "Fail2Ban ${G}successfully installed${I}."
            ;;
        almalinux|centos|rocky|fedora)
            Typing "For RHEL-based distributions, such as your $OS, Fail2Ban is inside Extra Packages for Enterprise Linux (EPEL) repository. The default Red Hat Enterprise Linux (RHEL) repository only offers core packages."
            Typing "Let's first enable this repository."
            eval "$INSTALL_CMD epel-release"
            Typing "EPEL repository ${G}successfully enabled${I}."
            eval "$INSTALL_CMD fail2ban"
            Typing "Fail2Ban ${G}successfully installed${I}."
            ;;
    esac
    
    Log "$FAIL2BAN_LOG"

    Typing "It's suggested to copy Fail2Ban's default configuration file \"fail2ban.conf\" as \"fail2ban.local\", and use it instead. Because Fail2Ban may overwrite the default config file after update. Don't worry, fail2ban.local will be read and has higher priority."
    cp /etc/fail2ban/fail2ban.conf /etc/fail2ban/fail2ban.local
    echo -e "fail2ban.local copied."

    local local_cnfig_file="/etc/fail2ban/fail2ban.local"
    local max_retry
    max_retry=$(grep -m1 "^maxretry" $local_cnfig_file | awk -F= '{print $2}' | tr -d ' ')
    local ban_time
    ban_time=$(grep -m1 "^bantime" $local_cnfig_file | awk -F= '{print $2}' | tr -d ' ')
    local find_time
    find_time=$(grep -m1 "^findtime" $local_cnfig_file | awk -F= '{print $2}' | tr -d ' ')

    Typing "Your current configuration bans failed attempts for $ban_time after $max_retry times within $find_time."

    systemctl enable fail2ban
    systemctl start fail2ban
    Typing "Fail2Ban started and is now protecting your server."
}

InstallUfw(){
    Typing "ufw stands for ${Y}Uncomplicated Firewall${I}. It's a simple and user-friendly firewall tool built on iptables."
    
    if ufw --version > /dev/null 2>&1; then
        echo -e "${G}ufw already installed. Skipping...${I}"
        return 0
    fi

    local response
    Typing "Do you wish to install ufw? Don't worry if you don't, we will add nftable rules for temporary protection. (Note that it'll lose effect after the server reboots)"
    Typing -n "Your answer(Y/n): "
    read -r response

    if CheckYesOrNo "$response" "y"; then
        Typing "${G}Installing${I} ufw..."
        eval "$INSTALL_CMD ufw"
        Typing "ufw ${G}successfully installed${I}."

        Log "$UFW_LOG"

        ufw default deny incoming
        ufw default allow outgoing
        ufw allow "$SSH_PORT/tcp"
        Typing "Denied all inbound connection except $SSH_PORT for SSH connection. Allowed any outbound connection."
    
        ufw enable
        Typing "ufw enabled and will start automatically at boot."
    else
        Typing "${G}Skipped${I} installing ufw."
        SetupDefaultNftablesRules
    fi
}

SetupDefaultNftablesRules(){
    if ! command -v nft > /dev/null 2>&1; then
        Typing "Nftables not installed. Installing..."
        eval "$INSTALL_CMD nftables"

        Log "$NFTABLES_LOG"
    else 
        nft list ruleset > "$NFTABLES_BACKUP"
    fi
    
    Typing "Original nftables rules backed up."

    Typing "Nftables installed. Adding temporary rules."
    nft -f "$NFTABLES_BASE"
    nft add rule inet filter input tcp dport "$SSH_PORT" accept # In case when user changed ssh port but doesn't restart ssh service 
    [[ -n $NEW_SSH_PORT ]] && nft add rule inet filter input tcp dport "$NEW_SSH_PORT" accept
    
    Log "$NFTABLES_RULE_LOG"

    Typing "Temporary rules added."
}

LogUser(){
    echo "$1" >> "$USER_LOG_PATH"
}

Main "$@"