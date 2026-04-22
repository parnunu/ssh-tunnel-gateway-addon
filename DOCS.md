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

## Step-by-step setup

### 1. Prepare the remote SSH server

Create or choose a remote SSH account that is allowed to log in with a key and reach the service you want to expose.

Example goal:

- remote SSH server: `bastion.example.com`
- remote service only reachable from that server: `127.0.0.1:3000`
- Home Assistant LAN endpoint you want: `http://<HA-IP>:3000`

Before touching Home Assistant, confirm the remote service actually works from the SSH server side.

### 2. Create a dedicated SSH key pair

Create a dedicated key pair on your PC:

```bash
ssh-keygen -t ed25519 -f id_ed25519 -C "ha-ssh-tunnel-gateway"
```

This gives you:

- `id_ed25519` -> private key used by the add-on
- `id_ed25519.pub` -> public key to install on the remote SSH server

Copy the public key to the remote server's `~/.ssh/authorized_keys` for the SSH user you plan to use.

Use a dedicated key without an interactive passphrase. The add-on cannot answer a password or passphrase prompt.

### 3. Create known_hosts

If you want the default secure mode, build a `known_hosts` file before starting the add-on:

```bash
ssh-keyscan -p 22 bastion.example.com > known_hosts
```

If your SSH server uses a non-default port, change `22` to that port.

### 4. Find the add-on config folder

The add-on reads:

- `/config/ssh/id_ed25519`
- `/config/ssh/known_hosts`

In Home Assistant terms, this is the add-on's public config folder. On disk it is the folder under `addon_configs` whose name ends with `_ssh_tunnel_gateway`.

If that folder does not exist yet, start the add-on once. It will create the `ssh/` directory and then fail fast if the key is missing. That first failure is expected.

You can place the files there using any method that can access Home Assistant files, for example:

- Samba Share
- Studio Code Server
- SSH to the Home Assistant host

Expected final layout:

```text
.../_ssh_tunnel_gateway/
  ssh/
    id_ed25519
    known_hosts
```

### 5. Copy the key files

Copy these files into the add-on config folder:

- `id_ed25519` -> save as `ssh/id_ed25519`
- `known_hosts` -> save as `ssh/known_hosts`

Do not rename the private key file. The add-on looks specifically for `id_ed25519`.

### 6. Configure one tunnel first

Start with one simple tunnel before adding more.

Example:

```yaml
tunnels:
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
```

Meaning:

- Home Assistant listens on `0.0.0.0:3000`
- traffic is forwarded over SSH to `bastion.example.com`
- the remote SSH server then connects to `127.0.0.1:3000` on its own side

### 7. Start the add-on

Start the add-on and open the log.

Healthy startup looks like this in plain terms:

- config validated
- key files found
- tunnel count reported
- one "Starting tunnel" line per configured tunnel

### 8. Test from another LAN device

Use the Home Assistant host IP and the configured `local_port`.

Examples:

- web UI: `http://<HA-IP>:3000`
- custom TCP client: connect to `<HA-IP>:3000`

Do not test with `localhost` from your laptop or phone. Use the actual Home Assistant IP on your LAN.

### 9. Add more tunnels

Once the first tunnel works, add more entries under `tunnels:`.

Each tunnel must have:

- a unique `name`
- a unique `local_port`

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

## Common patterns

### Expose a remote web UI to your LAN

If the remote service is only listening on `127.0.0.1:8006` on the SSH server:

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
```

Then browse to:

```text
http://<HA-IP>:8006
```

### Reach a remote host that is not localhost on the SSH server

If the SSH server can see another host on its own network, change `remote_host`.

Example:

```yaml
tunnels:
  - name: nas-ui
    ssh_host: bastion.example.com
    ssh_port: 22
    ssh_user: ha_tunnel
    local_port: 5001
    remote_host: 192.168.50.20
    remote_port: 5001
    server_alive_interval: 30
    server_alive_count_max: 3
    strict_host_key_checking: true
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
- invalid port values outside `1-65535`
- the SSH key is passphrase-protected

### Tunnel keeps reconnecting

Common causes:

- SSH credentials rejected
- SSH host key mismatch
- target local port already in use on the Home Assistant host
- remote service not reachable from the SSH server
- SSH server blocks TCP forwarding for that user

### Port is not reachable from another LAN device

Check:

- the add-on is running
- the configured `local_port` is not blocked elsewhere on the host
- the client uses the Home Assistant host IP, not `localhost`
- the remote service is reachable from the SSH server at `remote_host:remote_port`

### Remote host key changed

Update `/config/ssh/known_hosts` with the new host key and restart the add-on.

### First run created the folder and then failed

That is normal if the add-on was started before `ssh/id_ed25519` existed. Copy the key files into the created folder and start it again.
