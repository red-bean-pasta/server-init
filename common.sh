#! /bin/bash

# Color code when displaying message in e.g. echo, cat, etc. command
R=$'\e[0;31m'
G=$'\e[0;32m'
B=$'\e[0;34m'
M=$'\e[0;35m'
Y=$'\e[0;33m'
# Reset/Init
I=$'\e[0m'

# Exit code
INVALID_ARGUMENT=1
PERMISSION_ERROR=2
INVALID_INPUT=3
SSH_FAILED=4
UNKNOWN_ERROR=5

# Log code
SUDOERS_LOG="Sudoers file modified"
HOSTNAME_LOG="Host name changed from"
SSH_BACKUP_LOG="ssh_config.bak created"
ROOT_PASSWORD_LOG="Root user password changed"
FAIL2BAN_LOG="Fail2Ban installed"
UFW_LOG="ufw installed"
NFTABLES_LOG="Nftables installed"
NFTABLES_RULE_LOG="Nftables rules added"
FILES_UPLOADED_LOG="Setup files copied to server"
FILES_DOWNLOADED_LOG="Restoration files and private keys downloaded"
PUBLIC_KEY_LOG="All public key added"
UPDATE_LOG="Initiated updating for all packages"
UPDATE_FINISHED_LOG="All packages updated"
HOSTS_FILE_MODIFIED_LOG="/etc/hosts modified"

CheckIfSudo(){
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script requires root privileges. Please log into the server as root user."
        exit $PERMISSION_ERROR
    fi
}

CheckIfTyping(){
    local answer

    echo -e "Before everything, do you wish to enable ${Y}typing effect${I} for this script's messages? It can improve readability and interactivity."
    echo -e -n "Your answer?(y/n): "
    read -r answer

    CheckYesOrNo "$answer" && IS_TYPING=true || IS_TYPING=false
}

CheckYesOrNo() {
    local input=$1
    
    if [[ -z $input ]]; then
        input=$2
    fi

   if [[ "$input" =~ ^[:space:]*[Yy].* ]]; then
        return 0
    elif [[ "$input" =~ ^[:space:]*[Nn].* ]]; then
        return 1
    else 
        echo "Unknown Input, please type Y or y or N or n."
        exit $INVALID_INPUT
    fi
}

Log(){
    echo "$1" >> "$LOG_PATH"
}

CheckLog(){
    grep -Fq "$1" "$LOG_PATH"
}

Trim(){
    echo "$1" | sed -E 's/^\s+//;s/\s+$//'
}

Typing(){
    local text=""
    local if_new_line=true
    # ANSI code flag to skip applying delay and typing effect
    # ANSI code is used to format text in terminal. A convention from early days
    local is_ansi=false

    local opt=""
    local OPTIND=1
    local OPTARG=""

    while getopts "n" opt; do
        case $opt in
            n) if_new_line=false ;;
            *) echo "common.sh.Typing: ${R}Error${I}: Unknown option: -$OPTARG" >&2; return 1 ;;
        esac
    done

    shift $((OPTIND-1))

    if [[ $# -eq 0 ]]; then
        echo "common.sh.Typing: ${R}Error${I}: No text provided" >&2
        return 1
    elif [[ $# -gt 1 ]]; then
        echo "common.sh.Typing: ${R}Error${I}: Too many arguments" >&2
        return 1
    else
        text="$1"
    fi

    if [[ $IS_TYPING == "false" ]]; then
        echo -e -n "$text"
    elif [[ $IS_TYPING == "true" ]]; then
        for (( i=0; i<${#text}; i++ )); do

            if [[ $is_ansi == "false" && "${text:$i:1}" = $'\e' ]]; then
                is_ansi=true
            elif [[ $is_ansi == "true" && "${text:$i:1}" = "m" ]]; then
                is_ansi=false
            fi

            echo -e -n "${text:$i:1}"

            [[ $is_ansi == "false" ]] && sleep 0.034

        done
    else
        echo -e "common.sh.Typing: ${R}Error${I}: global argument IS_TYPING not set or not set to \"true\" or \"false\"."
    fi
    
    if [[ $if_new_line == "true" ]]; then
        echo
    fi
}