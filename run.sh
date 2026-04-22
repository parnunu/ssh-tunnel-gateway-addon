#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/lib/bashio/bashio.sh

readonly OPTIONS_FILE="/data/options.json"
readonly PUBLIC_CONFIG_DIR="/config"
readonly PUBLIC_SSH_DIR="${PUBLIC_CONFIG_DIR}/ssh"
readonly PUBLIC_KEYS_DIR="${PUBLIC_SSH_DIR}/keys"
readonly RUNTIME_SSH_DIR="/data/ssh"
readonly RUNTIME_KEYS_DIR="${RUNTIME_SSH_DIR}/keys"
readonly LEGACY_PRIVATE_KEY_SOURCE="${PUBLIC_SSH_DIR}/id_ed25519"
readonly KNOWN_HOSTS_TARGET="${RUNTIME_SSH_DIR}/known_hosts"
readonly RECONNECT_DELAY_SECONDS=5
readonly DEFAULT_PRIVATE_KEY_FILENAME="id_ed25519"

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
              ssh_private_key: (.ssh_private_key // "'"${DEFAULT_PRIVATE_KEY_FILENAME}"'" | tostring),
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

validate_key_name() {
    local label=${1}
    local value=${2}

    [[ -n "${value}" ]] || fail "${label} must not be empty."
    [[ "${value}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "${label} must be a file name stored under ${PUBLIC_KEYS_DIR}."
}

resolve_key_source_path() {
    local key_name=${1}
    local candidate="${PUBLIC_KEYS_DIR}/${key_name}"

    validate_key_name "ssh_private_key" "${key_name}"

    if [[ -s "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
    fi

    if [[ "${key_name}" == "${DEFAULT_PRIVATE_KEY_FILENAME}" ]] && [[ -s "${LEGACY_PRIVATE_KEY_SOURCE}" ]]; then
        printf '%s\n' "${LEGACY_PRIVATE_KEY_SOURCE}"
        return 0
    fi

    fail "Missing SSH private key file '${key_name}'. Put it in ${PUBLIC_KEYS_DIR}/ and restart."
}

known_host_lookup() {
    local ssh_host=${1}
    local ssh_port=${2}

    if [[ "${ssh_port}" == "22" ]]; then
        printf '%s\n' "${ssh_host}"
    else
        printf '[%s]:%s\n' "${ssh_host}" "${ssh_port}"
    fi
}

ensure_known_host_entry() {
    local ssh_host=${1}
    local ssh_port=${2}
    local required=${3}
    local lookup
    local scan_output

    lookup=$(known_host_lookup "${ssh_host}" "${ssh_port}")

    if ssh-keygen -F "${lookup}" -f "${KNOWN_HOSTS_TARGET}" >/dev/null 2>&1; then
        return 0
    fi

    bashio::log.info "Learning SSH host key for ${lookup}."

    scan_output=$(ssh-keyscan -T 10 -p "${ssh_port}" "${ssh_host}" 2>/dev/null || true)

    if [[ -z "${scan_output}" ]]; then
        if [[ "${required}" == "true" ]]; then
            fail "Unable to fetch SSH host key for ${lookup}. Confirm the SSH server is reachable."
        fi

        bashio::log.warning "Unable to prefetch SSH host key for ${lookup}. The SSH client will try to learn it during connect."
        return 0
    fi

    printf '%s\n' "${scan_output}" >> "${KNOWN_HOSTS_TARGET}"
    chmod 600 "${KNOWN_HOSTS_TARGET}"
}

prepare_ssh_material() {
    local tunnels_json=${1}
    declare -A prepared_keys=()

    mkdir -p "${PUBLIC_SSH_DIR}" "${PUBLIC_KEYS_DIR}" "${RUNTIME_SSH_DIR}" "${RUNTIME_KEYS_DIR}"
    touch "${KNOWN_HOSTS_TARGET}"
    chmod 600 "${KNOWN_HOSTS_TARGET}"

    while IFS= read -r tunnel; do
        local ssh_host
        local ssh_port
        local ssh_private_key
        local strict_host_key_checking
        local source_key_path
        local runtime_key_path

        ssh_host=$(json_value '.ssh_host' "${tunnel}")
        ssh_port=$(json_value '.ssh_port' "${tunnel}")
        ssh_private_key=$(json_value '.ssh_private_key' "${tunnel}")
        strict_host_key_checking=$(json_value '.strict_host_key_checking' "${tunnel}")

        if [[ -z "${prepared_keys[${ssh_private_key}]:-}" ]]; then
            source_key_path=$(resolve_key_source_path "${ssh_private_key}")
            runtime_key_path="${RUNTIME_KEYS_DIR}/${ssh_private_key}"
            install -m 600 "${source_key_path}" "${runtime_key_path}"
            prepared_keys["${ssh_private_key}"]=1
        fi

        if [[ "${strict_host_key_checking}" == "true" ]]; then
            ensure_known_host_entry "${ssh_host}" "${ssh_port}" "true"
        else
            ensure_known_host_entry "${ssh_host}" "${ssh_port}" "false"
        fi
    done < <(jq -c '.[]' <<<"${tunnels_json}")
}

validate_tunnels() {
    local tunnels_json=${1}
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
        local ssh_private_key
        local local_port
        local remote_host
        local remote_port
        local server_alive_interval
        local server_alive_count_max

        name=$(json_value '.name' "${tunnel}")
        ssh_host=$(json_value '.ssh_host' "${tunnel}")
        ssh_port=$(json_value '.ssh_port' "${tunnel}")
        ssh_user=$(json_value '.ssh_user' "${tunnel}")
        ssh_private_key=$(json_value '.ssh_private_key' "${tunnel}")
        local_port=$(json_value '.local_port' "${tunnel}")
        remote_host=$(json_value '.remote_host' "${tunnel}")
        remote_port=$(json_value '.remote_port' "${tunnel}")
        server_alive_interval=$(json_value '.server_alive_interval' "${tunnel}")
        server_alive_count_max=$(json_value '.server_alive_count_max' "${tunnel}")

        [[ -n "${name}" ]] || fail "Tunnel #$((index + 1)) is missing name."
        [[ -n "${ssh_host}" ]] || fail "Tunnel '${name}' is missing ssh_host."
        [[ -n "${ssh_user}" ]] || fail "Tunnel '${name}' is missing ssh_user."
        [[ -n "${remote_host}" ]] || fail "Tunnel '${name}' is missing remote_host."
        validate_key_name "Tunnel '${name}' ssh_private_key" "${ssh_private_key}"

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

        index=$((index + 1))
    done < <(jq -c '.[]' <<<"${tunnels_json}")
}

start_tunnel_manager() {
    local tunnel=${1}
    local name
    local ssh_host
    local ssh_port
    local ssh_user
    local ssh_private_key
    local local_port
    local remote_host
    local remote_port
    local server_alive_interval
    local server_alive_count_max
    local strict_host_key_checking
    local destination
    local bind_target
    local private_key_target
    local strict_host_key_mode

    name=$(json_value '.name' "${tunnel}")
    ssh_host=$(json_value '.ssh_host' "${tunnel}")
    ssh_port=$(json_value '.ssh_port' "${tunnel}")
    ssh_user=$(json_value '.ssh_user' "${tunnel}")
    ssh_private_key=$(json_value '.ssh_private_key' "${tunnel}")
    local_port=$(json_value '.local_port' "${tunnel}")
    remote_host=$(json_value '.remote_host' "${tunnel}")
    remote_port=$(json_value '.remote_port' "${tunnel}")
    server_alive_interval=$(json_value '.server_alive_interval' "${tunnel}")
    server_alive_count_max=$(json_value '.server_alive_count_max' "${tunnel}")
    strict_host_key_checking=$(json_value '.strict_host_key_checking' "${tunnel}")

    destination="${ssh_user}@${ssh_host}"
    bind_target="0.0.0.0:${local_port}:${remote_host}:${remote_port}"
    private_key_target="${RUNTIME_KEYS_DIR}/${ssh_private_key}"

    if [[ "${strict_host_key_checking}" == "true" ]]; then
        strict_host_key_mode="yes"
    else
        strict_host_key_mode="accept-new"
    fi

    trap 'exit 0' TERM INT

    while true; do
        local -a ssh_args=(
            -N
            -T
            -g
            -p "${ssh_port}"
            -i "${private_key_target}"
            -L "${bind_target}"
            -o BatchMode=yes
            -o ConnectTimeout=10
            -o ExitOnForwardFailure=yes
            -o IdentitiesOnly=yes
            -o LogLevel=ERROR
            -o ServerAliveInterval="${server_alive_interval}"
            -o ServerAliveCountMax="${server_alive_count_max}"
            -o TCPKeepAlive=yes
            -o StrictHostKeyChecking="${strict_host_key_mode}"
            -o UserKnownHostsFile="${KNOWN_HOSTS_TARGET}"
        )

        bashio::log.info "[${name}] Starting tunnel on ${local_port} -> ${remote_host}:${remote_port} via ${destination}:${ssh_port} using key ${ssh_private_key}"

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

    tunnels_json=$(normalize_tunnels)
    validate_tunnels "${tunnels_json}"
    prepare_ssh_material "${tunnels_json}"

    tunnel_count=$(jq 'length' <<<"${tunnels_json}")

    bashio::log.info "SSH Tunnel Gateway validated ${tunnel_count} tunnel(s)."
    bashio::log.info "Place SSH private keys in ${PUBLIC_KEYS_DIR}/ and refer to the file name with ssh_private_key."
    bashio::log.info "SSH host keys are managed automatically in ${KNOWN_HOSTS_TARGET}."

    trap shutdown TERM INT

    while IFS= read -r tunnel; do
        start_tunnel_manager "${tunnel}" &
    done < <(jq -c '.[]' <<<"${tunnels_json}")

    wait
}

main "$@"
