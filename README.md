# SSH Tunnel Gateway Add-on Source Repository

This repository is the source of truth for the `SSH Tunnel Gateway` Home Assistant add-on.

Users do not add this repository directly in Home Assistant. The install target is the central add-on repository:

- `https://github.com/parnunu/home-assistant-addons`

The add-on is published there as the root-level folder `ssh_tunnel_gateway`.

## What the add-on does

SSH Tunnel Gateway exposes remote services to devices on your LAN by running persistent SSH local port forwards on the Home Assistant host network.

Traffic flow:

`LAN device -> Home Assistant host IP:local_port -> SSH tunnel -> remote server 127.0.0.1:remote_port`

The add-on:

- supports multiple tunnel definitions
- expects key-based SSH authentication
- lets each tunnel choose a private key file by name
- keeps SSH private keys and managed host keys in persistent add-on storage
- validates configuration before starting
- reconnects tunnels automatically if they drop
- logs starts, failures, and reconnect attempts clearly

## Installation flow

1. In Home Assistant, add `https://github.com/parnunu/home-assistant-addons` as a custom add-on repository.
2. Install `SSH Tunnel Gateway`.
3. Generate or choose an SSH private key for the add-on.
4. Put the private key file into the add-on's public config folder under `ssh/keys/`.
5. Configure one or more tunnels.
6. Start the add-on and verify the logs.

Detailed usage, configuration, security notes, and troubleshooting are in [DOCS.md](DOCS.md).

## Quick setup

1. Install `SSH Tunnel Gateway` from the central Home Assistant repo.
2. Prepare the remote SSH server so it accepts a key-based login for the tunnel user.
3. Create a dedicated key pair, for example:

   ```bash
   ssh-keygen -t ed25519 -f id_ed25519 -C "ha-ssh-tunnel-gateway"
   ```

4. Add the public key to the remote server's `authorized_keys`.
5. Copy the private key into the add-on config folder under `ssh/keys/`. You can keep the filename `id_ed25519` or use your own file name.
6. Save an add-on config such as:

   ```yaml
   tunnels:
     - name: grafana
       ssh_host: bastion.example.com
       ssh_port: 22
       ssh_user: ha_tunnel
       ssh_private_key: id_ed25519
       local_port: 3000
       remote_host: 127.0.0.1
       remote_port: 3000
       server_alive_interval: 30
       server_alive_count_max: 3
       strict_host_key_checking: true
   ```

7. Start the add-on. It will learn the SSH host key automatically and store it in persistent add-on data.
8. Open `http://<HA-IP>:3000` from another LAN device to test the tunnel.

## Publishing to the central repo

This source repo publishes the installable add-on folder into:

- `https://github.com/parnunu/home-assistant-addons`

The publish workflow copies this repo's add-on files into the central repo folder:

- `ssh_tunnel_gateway/`

## Required GitHub secret

Add this repository secret in `parnunu/ssh-tunnel-gateway-addon`:

- `CENTRAL_REPO_PAT`

Recommended permissions for a fine-grained token:

- repository access: `parnunu/home-assistant-addons`
- repository permissions: `Contents: Read and write`

A classic PAT with `repo` scope also works, but a fine-grained token is tighter.

## How the publish workflow works

1. A push to `main` or a manual workflow run starts the publish workflow.
2. The workflow checks out this repo and the central repo.
3. It replaces `ssh_tunnel_gateway/` in the central repo with this add-on's published files.
4. If anything changed, it commits and pushes to `parnunu/home-assistant-addons`.

That keeps this repo as the source of truth while the central repo stays the only repository users paste into Home Assistant.
