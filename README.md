# server-init
Lightweight Bash scripts for initializing remote Linux servers.


## Highlights

1. A **rollback failsafe** that recovers from failures during setup and helps prevent lockouts
2. **Fully automated** setup through CLI arguments, or a beginner-friendly **interactive questionnaire**
3. A **survey and validation phase** that runs before setup to catch invalid configuration early and reduce the risk of partial changes


## Prerequisites

On the server side, only Debian, Ubuntu, AlmaLinux, CentOS, Rocky Linux, and Fedora are supported.

On the client side, most Linux systems should already have the required dependencies. The script checks for them before setup.


## Quick start

### 1. Clone the project

Clone the project to your local machine:
```bash
git clone https://github.com/red-bean-pasta/server-init
cd server-init
```

> `server-init` runs on your **local machine** and connects to the remote server over SSH.
> This allows it to create and retain private SSH keys locally.

### 2. Start the setup

The initial SSH connection must authenticate as `root`.

#### Run interactively

Run the script without arguments:
```bash
bash launch.sh
```

The script first asks whether to enable the typing effect, then prompts you for each setup option.

> No changes are applied until the survey is complete and all values have been validated.

#### Run fully automated

First, review the available arguments:
```bash
bash launch.sh -h
```

Then pass the required arguments. For example:
```bash
bash launch.sh --host example.com --port 22 --user lily '$y$...' true bash --new-port 40022 --disable-password --disable-root --update --ufw
```

> Both modes create a persistent SSH connection and upload temporary setup files. These resources are cleaned up automatically.

> Generated private keys are stored locally under `~/.ssh/id_ed25519.d/` as `<hostname>_<user>.key`. The matching public keys are installed on the server.

### 3. Recovery

A 90-second recovery timer starts when setup exits. The timer is canceled after the script verifies that the new login works. If verification fails, the server runs the restore script when the timer expires.

Package upgrades cannot be reversed by the restore script.

> As a last resort, rebuild the server through your cloud provider’s web console.


## Supported tasks

- Install and enable **`sudo`**
- **Create users**
- Generate and install **SSH keys**
- Change the **root password**
- Change the **hostname**
- Change the **timezone**
- Check system time synchronization
- Change the **SSH port**
- Disable **password-based SSH login**
- Disable **SSH login for `root`**
- Update **system packages**
- Install a firewall with **UFW**, **firewalld**, or **nftables**
- Install **Fail2Ban**
- **Automatic recovery** after setup failure


## Project history

- 1.0 – Multi-script prototype
- 2.0 – Experimental single-file architecture
- 3.0 – Introduced survey, setup, and recovery phases with an automatic rollback timer
