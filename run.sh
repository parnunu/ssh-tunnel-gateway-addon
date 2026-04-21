#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/lib/bashio/bashio.sh

readonly OPTIONS_FILE="/data/options.json"
readonly PUBLIC_CONFIG_DIR="/config"
readonly PUBLIC_SSH_DIR="${PUBLIC_CONFIG_DIR}/ssh"
readonly RUNTIME_SSH_DIR="/data/ssh"
readonly PRIVATE_KEY_SOURCE="${PUBLIC_SSH_DIR}/id_ed25519"
readonly KNOWN_HOSTS_SOURCE="${PUBLIC_SSH_DIR}/known_hosts"
readonly PRIVATE_KEY_TARGET="${RUNTIME_SSH_DIR}/id_ed25519"
readonly KNOWN_HOSTS_TARGET="${RUNTIME_SSH_DIR}/known_hosts"
readonly RECONNECT_DELAY_SECONDS=5

fail() {
    bashio::log.error "$1"
    exit 1
}

json_value() {
    local expression=${1}
    local document=${2}

    jq -r "${expression}" <<<"${document}"
}

normalize_tunnels() {
    jq -c '
        (.tunnels // [])
        | if type != "array" then
            error("The tunnels option must be a list.")
          else
            map({
              name: (.name // "" | tostring),
              ssh_host: (.ssh_host // "" | tostring),
              ssh_port: (.ssh_port // 22),
              ssh_user: (.ssh_user // "" | tostring),
              local_port: (.local_port // 0),
              remote_host: (.remote_host // "127.0.0.1" | tostring),
              remote_port: (.remote_port // 0),
              server_alive_interval: (.server_alive_interval // 30),
              server_alive_count_max: (.server_alive_count_max // 3),
              strict_host_key_checking: (.strict_host_key_checking // true)
            })
          end
    ' "${OPTIONS_FILE}"
}

validate_port() {
    local label=${1}
    local value=${2}

    [[ "${value}" =~ ^[0-9]+$ ]] || fail "${label} must be an integer."
    (( value >= 1 && value <= 65535 )) || fail "${label} must be between 1 and 65535."
}

validate_positive_integer() {
    local label=${1}
    local value=${2}

    [[ "${value}" =~ ^[0-9]+$ ]] || fail "${label} must be an integer."
    (( value >= 1 )) || fail "${label} must be at least 1."
}

prepare_ssh_material() {
    mkdir -p "${PUBLIC_SSH_DIR}" "${RUNTIME_SSH_DIR}"

    if [[ ! -s "${PRIVATE_KEY_SOURCE}" ]]; then
        fail "Missing SSH private key at ${PRIVATE_KEY_SOURCE}. Put your key in the add-on config folder and restart."
    fi

    install -m 600 "${PRIVATE_KEY_SOURCE}" "${PRIVATE_KEY_TARGET}"

    if [[ -f "${KNOWN_HOSTS_SOURCE}" ]]; then
        install -m 600 "${KNOWN_HOSTS_SOURCE}" "${KNOWN_HOSTS_TARGET}"
    else
        : > "${KNOWN_HOSTS_TARGET}"
        chmod 600 "${KNOWN_HOSTS_TARGET}"
        bashio::log.warning "No known_hosts file found at ${KNOWN_HOSTS_SOURCE}. Tunnels with strict host key checking enabled will fail validation."
    fi
}

validate_tunnels() {
    local tunnels_json=${1}
    local strict_host_key_count=0
    local count
    declare -A seen_names=()
    declare -A seen_local_ports=()

    count=$(jq 'length' <<<"${tunnels_json}")
    (( count > 0 )) || fail "At least one tunnel must be configured."

    local index=0
    while IFS= read -r tunnel; do
        local name
        local ssh_host
        local ssh_port
        local ssh_user
        local local_port
        local remote_host
        local remote_port
        local server_alive_interval
        local server_alive_count_max
        local strict_host_key_checking

        name=$(json_value '.name' "${tunnel}")
        ssh_host=$(json_value '.ssh_host' "${tunnel}")
        ssh_port=$(json_value '.ssh_port' "${tunnel}")
        ssh_user=$(json_value '.ssh_user' "${tunnel}")
        local_port=$(json_value '.local_port' "${tunnel}")
        remote_host=$(json_value '.remote_host' "${tunnel}")
        remote_port=$(json_value '.remote_port' "${tunnel}")
        server_alive_interval=$(json_value '.server_alive_interval' "${tunnel}")
        server_alive_count_max=$(json_value '.server_alive_count_max' "${tunnel}")
        strict_host_key_checking=$(json_value '.strict_host_key_checking' "${tunnel}")

        [[ -n "${name}" ]] || fail "Tunnel #$((index + 1)) is missing name."
        [[ -n "${ssh_host}" ]] || fail "Tunnel '${name}' is missing ssh_host."
        [[ -n "${ssh_user}" ]] || fail "Tunnel '${name}' is missing ssh_user."
        [[ -n "${remote_host}" ]] || fail "Tunnel '${name}' is missing remote_host."

        validate_port "Tunnel '${name}' ssh_port" "${ssh_port}"
        validate_port "Tunnel '${name}' local_port" "${local_port}"
        validate_port "Tunnel '${name}' remote_port" "${remote_port}"
        validate_positive_integer "Tunnel '${name}' server_alive_interval" "${server_alive_interval}"
        validate_positive_integer "Tunnel '${name}' server_alive_count_max" "${server_alive_count_max}"

        if [[ -n "${seen_names[${name}]:-}" ]]; then
            fail "Tunnel name '${name}' is duplicated."
        fi
        seen_names["${name}"]=1

        if [[ -n "${seen_local_ports[${local_port}]:-}" ]]; then
            fail "local_port ${local_port} is duplicated across tunnels."
        fi
        seen_local_ports["${local_port}"]=1

        if [[ "${strict_host_key_checking}" == "true" ]]; then
            strict_host_key_count=$((strict_host_key_count + 1))
        fi

        index=$((index + 1))
    done < <(jq -c '.[]' <<<"${tunnels_json}")

    if (( strict_host_key_count > 0 )) && [[ ! -s "${KNOWN_HOSTS_TARGET}" ]]; then
        fail "strict_host_key_checking=true requires a non-empty known_hosts file at ${KNOWN_HOSTS_SOURCE}."
    fi
}

start_tunnel_manager() {
    local tunnel=${1}
    local name
    local ssh_host
    local ssh_port
    local ssh_user
    local local_port
    local remote_host
    local remote_port
    local server_alive_interval
    local server_alive_count_max
    local strict_host_key_checking
    local destination
    local bind_target

    name=$(json_value '.name' "${tunnel}")
    ssh_host=$(json_value '.ssh_host' "${tunnel}")
    ssh_port=$(json_value '.ssh_port' "${tunnel}")
    ssh_user=$(json_value '.ssh_user' "${tunnel}")
    local_port=$(json_value '.local_port' "${tunnel}")
    remote_host=$(json_value '.remote_host' "${tunnel}")
    remote_port=$(json_value '.remote_port' "${tunnel}")
    server_alive_interval=$(json_value '.server_alive_interval' "${tunnel}")
    server_alive_count_max=$(json_value '.server_alive_count_max' "${tunnel}")
    strict_host_key_checking=$(json_value '.strict_host_key_checking' "${tunnel}")

    destination="${ssh_user}@${ssh_host}"
    bind_target="0.0.0.0:${local_port}:${remote_host}:${remote_port}"

    trap 'exit 0' TERM INT

    while true; do
        local -a ssh_args=(
            -N
            -T
            -g
            -p "${ssh_port}"
            -i "${PRIVATE_KEY_TARGET}"
            -L "${bind_target}"
            -o BatchMode=yes
            -o ConnectTimeout=10
            -o ExitOnForwardFailure=yes
            -o IdentitiesOnly=yes
            -o LogLevel=ERROR
            -o ServerAliveInterval="${server_alive_interval}"
            -o ServerAliveCountMax="${server_alive_count_max}"
            -o TCPKeepAlive=yes
        )

        if [[ "${strict_host_key_checking}" == "true" ]]; then
            ssh_args+=(
                -o StrictHostKeyChecking=yes
                -o UserKnownHostsFile="${KNOWN_HOSTS_TARGET}"
            )
        else
            ssh_args+=(
                -o StrictHostKeyChecking=no
                -o UserKnownHostsFile=/dev/null
            )
        fi

        bashio::log.info "[${name}] Starting tunnel on ${local_port} -> ${remote_host}:${remote_port} via ${destination}:${ssh_port}"

        if ssh "${ssh_args[@]}" "${destination}"; then
            bashio::log.warning "[${name}] SSH exited cleanly. Reconnecting in ${RECONNECT_DELAY_SECONDS}s."
        else
            local exit_code=$?
            bashio::log.warning "[${name}] SSH exited with code ${exit_code}. Reconnecting in ${RECONNECT_DELAY_SECONDS}s."
        fi

        sleep "${RECONNECT_DELAY_SECONDS}"
    done
}

shutdown() {
    local child_pids

    bashio::log.info "Stopping SSH Tunnel Gateway."
    child_pids=$(jobs -pr)

    if [[ -n "${child_pids}" ]]; then
        kill ${child_pids} 2>/dev/null || true
        wait ${child_pids} 2>/dev/null || true
    fi

    exit 0
}

main() {
    local tunnels_json
    local tunnel_count

    [[ -f "${OPTIONS_FILE}" ]] || fail "Missing add-on options file: ${OPTIONS_FILE}."

    prepare_ssh_material
    tunnels_json=$(normalize_tunnels)
    validate_tunnels "${tunnels_json}"

    tunnel_count=$(jq 'length' <<<"${tunnels_json}")

    bashio::log.info "SSH Tunnel Gateway validated ${tunnel_count} tunnel(s)."
    bashio::log.info "Place key material in ${PUBLIC_SSH_DIR}/id_ed25519 and ${PUBLIC_SSH_DIR}/known_hosts."

    trap shutdown TERM INT

    while IFS= read -r tunnel; do
        start_tunnel_manager "${tunnel}" &
    done < <(jq -c '.[]' <<<"${tunnels_json}")

    wait
}

main "$@"
