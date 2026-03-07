#! /bin/bash

R=$'\e[0;31m'
G=$'\e[0;32m'
B=$'\e[0;34m'
Y=$'\e[0;33m'
I=$'\e[0m' # Reset/Init


CheckIfRoot(){
	if [[ "$EUID" -ne 0 ]]; then
		Typing -e "Root privilege required"
		exit 1
	fi
}


CheckIfTyping(){
	[[ -n "${TYPING:-}" ]] && [[ $TYPING == "true" || $TYPING == "false" ]] && return 0
	local answer; read -rp "Do you wish to enable ${Y}typing effect${I} to improve readability and interactivity?: " answer
	CheckYesNo "$answer" && TYPING=true || TYPING=false
}


PromptForAnswer(){
	local answer; Typing -n "$1"; read -r answer
	answer=$(Trim "$answer")
	: "${answer:=${2:-}}"
	echo "$answer"
}


PromptForYesNo(){
	local answer; Typing -n "$1"; read -r answer
	answer=$(Trim "$answer")
	CheckYesNo "$answer" "${2:-}"
}


Typing(){
	local text prefix if_new_line=true disable_typing=false
	local is_ansi=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-n) if_new_line=false; shift ;;
			-d) disable_typing=true; shift;; 
			-w) prefix="${Y}WARNING: ${I}"; shift ;;
			-e) prefix="${R}ERROR: ${I}"; shift ;;
			-b) prefix="${R}BUG: ${I}"; shift ;;
			*) break ;;
		esac
	done
	
	if [[ $# -eq 0 ]]; then
		Typing -b "Calling Typing when no text is provided"
		return 1
	else
		text="${prefix:-}$*"
	fi

	local typing; typing=$($disable_typing && echo false || echo "${TYPING:-}")
	if [[ -z ${typing:-} ]]; then 
		TYPING=false Typing -b 'Environment variable $TYPING not set'
		typing=false
	fi
	local i; for (( i=0; i<${#text}; i++ )); do
		if $is_ansi && [[ "${text:$i:1}" == $'\e' ]]; then
			is_ansi=true
		elif $is_ansi && [[  "${text:$i:1}" == "m" ]]; then
			is_ansi=false
		fi
		echo -e -n "${text:$i:1}" >&2
		$typing && ! $is_ansi && sleep 0.034
	done
	$if_new_line && echo >&2 || return 0
}


Log(){
	Typing -d "$@"
}


CheckYesNo() {
	local input
	[[ -n ${1:-} ]] && input=$1 || input=${2:-}

	if [[ "$input" =~ ^[:space:]*[Yy].* ]]; then
		return 0
	elif [[ "$input" =~ ^[:space:]*[Nn].* ]]; then
		return 1
	else
		local answer; read -rp "Unknown Input, please type Y, y, N or n. Try again: " answer
		CheckYesNo "$answer" && return 0 || return 1
	fi
}


CheckIfSet(){
	[ "${1+x}" = x ]
}


Trim(){
	if [[ -n "${1+x}" ]]; then
        sed -E 's/^\s+//;s/\s+$//' <<< "$1" 
    elif [[ ! -t 0 ]]; then
        sed -E 's/^\s+//;s/\s+$//'
    else
        return 0
    fi
}


RemoveDirectory(){
	rm -rf "${1:?}"
}


IndexArrayValue(){
	local -n _array=$1
	local i=0; local item; for item in "${_array[@]}"; do
		if [[ $2 == "$item" ]]; then
			echo "$i"
			return 0
		fi
		((i++))
	done
	echo -1
	return 1
}