# server-init
Lightweight bash scripts help initializing remote Linux servers, with **rollback failsafe** support. It support both CLI-driven **full automation** as well as beginner-friendly **Q&A interaction** setup. **A survey stage** takes place before executing the setup in both modes, to help catching bad configuration early and avoiding midway system corruption. 


# Quickstart

Only Debian, Ubuntu, AlmaLinux, CentOS, Rocky Linux and Fedora are supported.

1. Clone this project to local
```bash
git clone https://github.com/red-bean-pasta/server-init
cd server-init
```

`server-init` runs on a **local machine** instead of the remote server to hanndle SSH key creation and installing securely.

2. Start

A. Run interactively
Simply pass no arguments
```bash
bash launch.sh
```

It will first ask about enabling typing effect or not, then prompt for each setup configuration item. No setup is executed during the interaction until the survey is finished and everything is valid.

B. Run fully automated
First, check supported arguments with
```bash
bash launch.sh -h
```

Then pass needed arguments:
```bash
bash launch.sh --host example.com --port 22 --user lily '$y$...' true true bash --new-port 40022 --disable-password --disable-root --update --ufw
```

Certain steps **may still require manual interaction**, such as SSH password login, SSH key generation and firewall confirmations.


## Supported tasks
- Install and enable sudo
- Add users
- Install public keys on the server
- Add private key to local `~/.ssh/`
- Change root password
- Change hostname
- Change timezone
- Check system time synchronization
- Enable public key authentication
- Change SSH port
- Disable password login
- Disable root login
- Update system packages
- Install firewall: firewalld, ufw or nftables
- Install fail2ban
- Automatic recovery


## Project history
- 1.0 – multi-script prototype
- 2.0 – experimental single-file architecture
- 3.0 – introduce survey, setup and recovery phases with automatic rollback timer
