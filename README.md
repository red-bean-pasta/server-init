# server-init
Prototype script that runs locally and initializes remote Linux servers interactively.
The goal is to simplify first-time server setup for beginners while still allowing automation through command-line arguments.

## Features
This tool aims to be:
- **Beginner friendly** — interactive prompt-and-answer workflow
- **Reversible** — allows recovery if setup is interrupted
- **Single-file** — simplifies distribution and execution

### Supported setup tasks
- Change hostname
- Add users
- Enable sudo group
- Generate and install SSH keys
- Change user shells
- Check system time synchronization
- Enable public key authentication
- Change SSH port
- Disable password login
- Disable root login
- Change root password
- Update system packages
- Install firewall (firewalld / ufw) or configure nftables
- Install fail2ban

## Workflow
1. Upload setup scripts to the remote server
2. Create users and generate SSH keys on the remote system
3. Retrieve generated private keys to the local machine and add them to `~/.ssh/config`
4. Apply system configuration:
   - change hostname
   - update SSH configuration
   - update packages
   - configure firewall
5. Retrieve and store a setup log locally for potential recovery

## Limitations
- No complete automation support via command-line arguments
- SSH keys are generated on the remote server, and private keys are transferred over the network
- Private keys are stored in the local script directory
- Recovery is not automatic and requires running the script again
- Recovery depends on logs being successfully retrieved from the remote server
- Assumes `sudo` is already installed and available
