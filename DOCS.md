# SSH Tunnel Gateway

SSH Tunnel Gateway exposes remote services to your LAN using persistent SSH local port forwarding from Home Assistant.

Traffic flow:

`LAN device -> Home Assistant host IP:local_port -> SSH tunnel -> remote service`

The add-on binds on the Home Assistant host network and uses `0.0.0.0:local_port` for each configured tunnel so the listening port is reachable from other devices on your LAN.

## Install through the central add-on repo

1. In Home Assistant, open **Settings -> Add-ons -> Add-on Store**.
2. Open the top-right menu -> **Repositories**.
3. Add:
   `https://github.com/parnunu/home-assistant-addons`
4. Refresh the store.
5. Install **SSH Tunnel Gateway**.

## Key material

The add-on expects these files:

- `/config/ssh/id_ed25519`
- `/config/ssh/known_hosts`

Inside the container, `/config` is the add-on's public config folder created by Home Assistant. On the host this lives under the add-on's `addon_configs` directory, in the folder ending with `_ssh_tunnel_gateway`.

The add-on copies those files into `/data/ssh/` on startup so they stay in persistent add-on storage.

### Private key

Use an SSH private key that is allowed to connect to the remote SSH server and create local forwards. Recommended permissions:

- key type: `ed25519`
- file name: `id_ed25519`
- no password prompt at runtime

If your key is passphrase-protected, the add-on cannot answer the prompt, so use a dedicated deployment key without an interactive passphrase.

### known_hosts

If `strict_host_key_checking` is `true`, `known_hosts` must contain the remote SSH host key. Example:

```bash
ssh-keyscan -p 22 bastion.example.com >> known_hosts
```

If `strict_host_key_checking` is `false`, the add-on allows the connection without requiring a populated `known_hosts` file, but that is less secure.

## Configuration reference

`tunnels` is a list of tunnel definitions.

Each tunnel supports:

- `name`: Friendly label used in logs.
- `ssh_host`: Hostname or IP address of the SSH server.
- `ssh_port`: SSH server port. Default: `22`.
- `ssh_user`: SSH username.
- `local_port`: Port to listen on from the Home Assistant host network.
- `remote_host`: Host to reach from the remote SSH server. Default: `127.0.0.1`.
- `remote_port`: Port to reach from the remote SSH server.
- `server_alive_interval`: SSH keepalive interval in seconds. Default: `30`.
- `server_alive_count_max`: Failed keepalives before SSH exits. Default: `3`.
- `strict_host_key_checking`: Whether SSH host key validation is enforced. Default: `true`.

## Example configuration

```yaml
tunnels:
  - name: proxmox-web
    ssh_host: bastion.example.com
    ssh_port: 22
    ssh_user: ha_tunnel
    local_port: 8006
    remote_host: 127.0.0.1
    remote_port: 8006
    server_alive_interval: 30
    server_alive_count_max: 3
    strict_host_key_checking: true

  - name: grafana
    ssh_host: bastion.example.com
    ssh_port: 22
    ssh_user: ha_tunnel
    local_port: 3000
    remote_host: 127.0.0.1
    remote_port: 3000
    server_alive_interval: 30
    server_alive_count_max: 3
    strict_host_key_checking: true

  - name: homebridge
    ssh_host: homebridge-gateway.example.net
    ssh_port: 2222
    ssh_user: bridge
    local_port: 8581
    remote_host: 127.0.0.1
    remote_port: 8581
    server_alive_interval: 20
    server_alive_count_max: 3
    strict_host_key_checking: false
```

## Behavior

On startup the add-on:

1. validates the add-on configuration
2. validates the SSH key files
3. copies key material into persistent `/data/ssh`
4. starts one SSH process per tunnel
5. keeps each tunnel in a reconnect loop

Each tunnel uses `ExitOnForwardFailure=yes`, so bind failures and forwarding setup failures are logged immediately.

## Security notes

- `host_network: true` is required so the forwarded ports bind on the Home Assistant host IP and are reachable from the LAN.
- Prefer `strict_host_key_checking: true` with a populated `known_hosts` file.
- Use a dedicated SSH user with the minimum server-side permissions needed.
- Prefer a dedicated deployment key rather than reusing a personal key.
- Every `local_port` you expose becomes reachable on your LAN, so only publish services you actually want available there.

## Troubleshooting

### Add-on fails immediately

Common causes:

- no tunnels configured
- missing `/config/ssh/id_ed25519`
- `strict_host_key_checking: true` with an empty or missing `known_hosts`
- duplicate `local_port` values

### Tunnel keeps reconnecting

Common causes:

- SSH credentials rejected
- SSH host key mismatch
- target local port already in use on the Home Assistant host
- remote service not reachable from the SSH server

### Port is not reachable from another LAN device

Check:

- the add-on is running
- the configured `local_port` is not blocked elsewhere on the host
- the client uses the Home Assistant host IP, not `localhost`
- the remote service is reachable from the SSH server at `remote_host:remote_port`

### Remote host key changed

Update `/config/ssh/known_hosts` with the new host key and restart the add-on.
