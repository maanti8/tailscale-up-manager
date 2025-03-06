# Tailscale Up Manager

**Tailscale Up Manager** is a Bash script that automatically detects Docker networks and advertises the corresponding subnets to your Tailscale VPN node. The script performs the following tasks:

- **Detect Docker Networks:** It scans for Docker networks and extracts their subnet information.
- **Create/Update Configuration:** It saves the selected subnets in a JSON configuration file at `/etc/tailscale-up-config.json`.
- **Create/Update a systemd Service:** It creates a systemd service (`/etc/systemd/system/tailscale-up.service`) that runs at boot time, ensuring that Tailscale is configured with the selected routes.
- **Interactive Management:** It provides an interactive menu for managing the configuration, including options to add/remove networks or completely uninstall the service and configuration.
- **Wait/Retry Mechanism:** The service uses an `ExecStartPre` command that loops until Tailscale reports a "Running" state before executing the main command.

## Features

- **Automatic Docker Network Detection:**  
  Automatically retrieves all Docker networks and their subnets.

- **Interactive Configuration:**  
  Allows you to select which subnets to advertise via an interactive menu.

- **Systemd Service Integration:**  
  The service is configured to depend on `tailscaled.service` (using `After=` and `Requires=`) to ensure the Tailscale daemon is running.

- **Wait/Retry Mechanism:**  
  Before advertising routes, the service waits until Tailscale reports a "Running" state. If the state isn’t reached within a set timeout (e.g., 60 seconds), it exits with an error and retries automatically.

- **Uninstall Option:**  
  Easily remove the service and configuration file via an uninstall option in the interactive menu.

## Prerequisites

- **Docker:**  
  Used for detecting network subnets.

- **Tailscale:**  
  Must be installed and properly configured. The Tailscale daemon (`tailscaled`) must be running.

- **jq:**  
  A JSON processor needed for parsing Tailscale status and handling the configuration file.

- **systemd:**  
  The script creates and manages a systemd service.

## Installation

1. **Download the Script:**

   Clone this repository or download the `tailscale-up-manager.sh` file.

2. **Make the Script Executable:**

   ```bash
   chmod +x tailscale-up-manager.sh

3. Run the Script as Root:
    ```bash
    sudo ./tailscale-up-manager.sh


## Usage
### Initial Setup
When you run the script for the first time, it will perform an initial configuration:

1. It detects the available Docker networks and displays their subnets.
2. You are prompted to select the networks (by number) you want to advertise.
3. Your selection is saved in /etc/tailscale-up-config.json.
4. A systemd service (tailscale-up.service) is created and enabled. This service uses an ExecStartPre command that loops until Tailscale reports a "Running" state, ensuring that routes are only advertised when Tailscale is connected.

### Interactive Menu Options
After the initial setup, running the script again brings up an interactive menu with the following options:

1. Add Network:
Add additional Docker subnets to the advertised list.

2. Remove Network:
Remove one or more subnets from the advertised list.

3. Remove Invalid Routes:
Automatically clean up routes that no longer exist.

4. Quit:
Exit the script.

5. Uninstall:
Uninstall the tailscale-up service and remove the configuration file.


## How It Works
Docker Network Detection:
The script uses docker network ls and docker network inspect to retrieve the names and subnet information of all Docker networks.

Systemd Service Creation:
The service is configured to require and start after tailscaled.service:

ini
Kopieren

    
    [Unit]
    After=tailscaled.service
    Requires=tailscaled.service

The ExecStartPre command waits (with a retry loop) until Tailscale is in the "Running" state:

    ExecStartPre=/usr/bin/bash -c "n=0; while ! tailscale status --json 2>/dev/null | jq -e '.BackendState==\"Running\"' >/dev/null; do if [ \$n -ge 12 ]; then echo 'Tailscale did not reach Running state within 60 seconds.'; exit 1; fi; echo 'Waiting for Tailscale connection...'; n=\$((n+1)); sleep 5; done"

Once the state is confirmed, the main command executes:
    
    ExecStart=/usr/bin/tailscale up --advertise-routes=ROUTES_PLACEHOLDER

Retry Mechanism:
If Tailscale does not report a "Running" state within the timeout period, the service will exit with an error and be automatically restarted after a short delay (RestartSec=10).

## Troubleshooting
Service Hanging in Wait Loop:
Verify Tailscale’s status manually using:

    tailscale status --json

Ensure that there is a stable internet connection and that tailscaled is indeed running.

ExecStartPre Errors:
Check that the jq filter’s quote escaping is correct, ensuring the string "Running" is parsed properly.

View Logs:
Use the following command to check the service logs:

    journalctl -xeu tailscale-up.service

## License
This project is licensed under the MIT License.

## Contributing
Contributions are welcome! Please feel free to open an issue or submit a pull request if you have suggestions, bug reports, or improvements.


## Disclaimer
This script is provided "as is" without any warranty. Use it at your own risk.