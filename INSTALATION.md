# Installation Guide

This guide is designed to help you set up a clean local installation for FreeRADIUS. Follow the steps carefully to ensure a proper and functional setup.  
This project is specifically designed to be executed in the root folder of **Debian-based systems**. Running it outside the root folder or on non-Debian systems will be blocked due to missing permissions or capabilities for a proper configuration.

The hybrid connector installs FreeRADIUS, radsecproxy, and (optionally) PostgreSQL directly on the host via native packages/systemd — no Docker is required.

## Table of Contents
[Get Started](#get-started)
1. [Project Clone](#1-project-clone)
2. [Requirements](#2-requirements)
3. [Running the prepare-debian11.sh Script](#3-running-the-prepare-debian11sh-script)
4. [Verifying Services](#4-verifying-services)
---

## Get Started

Begin by preparing the system using the provided configuration script: **`prepare-debian11.sh`**.  
It configures FreeRADIUS by performing key steps such as installing dependencies, validating required certificates, and preparing the necessary configurations for deployment. This ensures a smooth and consistent installation process.

- Ensure that the **`prepare-debian11.sh`** script is run **only once**:
   - After the first run, the configuration variables will be removed and overwritten.
   - To rerun the script or fix issues, you must either start the entire guide again or selectively modify specific files under `/etc/radsecproxy.conf`, `/etc/freeradius/3.0/`, and re-run the relevant `systemctl restart` command.
   - For more details on which files to modify, review **Section Two** of the [WBA OpenRoaming Connector Installation Guide](#).

---

### 1. Project Clone

To begin, clone the project repository or download it directly from the official GitHub link below:

- **GitHub Repository**:  
  [https://github.com/wireless-broadband-alliance/wba-openroaming-connector](https://github.com/wireless-broadband-alliance/wba-openroaming-connector)

#### Steps to Retrieve the Project:
1. **Clone via Git**:
   ```bash
   git clone https://github.com/wireless-broadband-alliance/wba-openroaming-connector.git
   ```

2. **Download as a ZIP file**:
   - Navigate to the repository on GitHub, select the **Code** button, and click **Download ZIP**.

The script will prompt you interactively for your realm name, client CIDR/secret, and database credentials (including whether to install PostgreSQL locally or point at a remote/managed database host) — there is no `.env` file to prepare beforehand.

---


### 2. Requirements

Ensure the following requirements are met before starting the installation process:

1. **Run with Root Privileges**:
   - Use `sudo` or switch to the root user if not already running with root privileges:
     ```bash
     sudo su
     ```

2. **Certificates and Keys**:
   - Make sure the necessary certificates and keys are placed in their respective paths:

   **WBA Certificates**:
   - `/root/wba-openroaming-connector/certs/wba/key.pem`: Your certificate private key.
   - `/root/wba-openroaming-connector/certs/wba/client.pem`: Your OpenRoaming certificate.

   **FreeRADIUS Certificates**:
   - `/root/wba-openroaming-connector/certs/freeradius/cert.pem`: FreeRADIUS certificate (e.g., Let’s Encrypt certificate).
   - `/root/wba-openroaming-connector/certs/freeradius/chain.pem`: FreeRADIUS chain file.
   - `/root/wba-openroaming-connector/certs/freeradius/fullchain.pem`: FreeRADIUS full chain file.
   - `/root/wba-openroaming-connector/certs/freeradius/privkey.pem`: FreeRADIUS private key.

#### Note:
Failing to provide these files in the correct locations will cause the installation process to halt.

---

### 3. Running the `prepare-debian11.sh` Script

After meeting the requirements, execute the **`prepare-debian11.sh`** script to perform configuration and installation tasks.

#### How to Run the Script:
1. Make sure you are in the root folder of the project:
   ```bash
   cd ~/wba-openroaming-connector
   ```

2. Execute the script:
   ```bash
   ./prepare-debian11.sh
   ```

#### Example:
```bash
root@tetrapi-XPS-15-7590:~/wba-openroaming-connector# ./prepare-debian11.sh
```

---

#### Notes:
- **Only Run Once**: Running the script multiple times may overwrite existing configurations.
- If interrupted or rerunning is required, ensure:
   - The environment is cleaned.
   - Certificates are correctly placed.
- The script validates the presence of all required certificates in `/root/wba-openroaming-connector/certs`.

---

# 4. Verifying Services

Once the setup is complete, verify that all expected services are running using `systemctl`.

#### Command:
```bash
systemctl status radsecproxy freeradius postgresql
```

#### Example Output:
```plaintext
● radsecproxy.service - RadSec Proxy (OpenRoaming hybrid connector)
     Loaded: loaded (/etc/systemd/system/radsecproxy.service; enabled)
     Active: active (running)

● freeradius.service - FreeRADIUS multi-protocol policy server
     Loaded: loaded (/lib/systemd/system/freeradius.service; enabled)
     Active: active (running)

● postgresql.service - PostgreSQL database server
     Loaded: loaded (/lib/systemd/system/postgresql.service; enabled)
     Active: active (running)
```
(`postgresql` only appears here if you chose the local-install option; skip it if you pointed the installer at a remote/managed database host.)

---

#### Key Points to Verify:
- All three units show **active (running)**.
- **Port Mapping**: Verify the following are listening (`ss -tulnp`):
   - UDP ports `11812`/`11813` on radsecproxy (local NAS/AP clients).
   - TCP/UDP port `2083` on radsecproxy (RadSec federation).
   - UDP ports `1812`/`1813` on FreeRADIUS (localhost only).
   - TCP port `5432` on PostgreSQL (localhost only, unless using a remote/managed host).
- **Logs**: `journalctl -u radsecproxy -f` and `journalctl -u freeradius -f` for live troubleshooting.

---

### Final Steps

After verifying everything is running correctly, validate that relevant ports are open on your firewall/cloud security group. Use the following command to allow required ports via UFW:
```bash
for port in 11812/tcp 11812/udp 11813/tcp 11813/udp 2083/tcp 2083/udp; do sudo ufw allow $port; done
```

Only expose `2083` (RadSec) externally if this node needs to be reachable by federation peers; keep `1812`/`1813`/`5432` bound to localhost.

---