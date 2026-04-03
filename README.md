# server-init
Lightweight tool that runs locally and interactively initializes remote Linux servers for first-time setup.

## Status
This project is still experimental and under active testing and development.

## Design goals
- **Safety first** — avoid locking users out of servers
- **Beginner friendly** — interactive prompts guide the setup process with coloring and optional typing effect
- **Automation capable** — all steps can be driven by command-line arguments
- **Recoverable** — automatic rollback if setup fails with counting-down timer
- **Transparent** — actions are logged and reversible
- **Multi-platform** — supports launching from Linux, macOS and Windows
- **Multi-staged** - separates survey, setup and recovery phases
- **Privacy** - passwords are not displayed during input. SSH keys are generated locally and only public keys are transferred

## Supported setup tasks
- Install and enable sudo
- Add users (name, home directory, sudo access, shell)
- Generate keys locally and install public keys on the server
- Add private key to `~/.ssh/` locally
- Change root password
- Change hostname
- Change timezone
- Check system time synchronization
- Enable public key authentication
- Change SSH port
- Disable password login
- Disable root login
- Update system packages
- Install firewall (firewalld / ufw) or configure nftables
- Install fail2ban
- Automatic recovery
- Automatic cleanup on failure

## Workflow
1. Upload setup scripts to the remote server
2. Run the **survey phase** to collect configuration and generate a task list
3. Start the **setup phase**
4. Start a recovery timer on the remote server
5. Log in using the generated SSH key to confirm success and cancel the recovery timer

## Limitations
- Currently supports Debian, Ubuntu, AlmaLinux, CentOS, Rocky Linux and Fedora
- Tested primarily on Debian
- macOS support is limited due to its outdated Bash version
- Windows support is limited to launching the tool
- Some steps still require manual interaction (SSH password login, SSH key generation, firewall confirmations)

## Logging
Logs are written to temporary files both locally and on the remote server.
Recovery logs are written on the server because the SSH session is detached during recovery.

## Quick start
```bash
git clone https://github.com/red-bean-pasta/server-init
cd server-init
bash launch.sh -h
```

## Project history
- Initial – multi-script prototype
- Refactor – experimental single-file architecture
- Redesign – introduce survey, setup and recovery phases with automatic rollback timer
