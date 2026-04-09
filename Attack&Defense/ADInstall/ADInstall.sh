#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s extglob

declare -A CONFIG=()

CONFIG_FILE="${1:-./adinstall.conf}"

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

strip_quotes() {
    local value
    value="$(trim "$1")"
    if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

config_key() {
    printf '%s.%s' "$1" "$2"
}

config_has() {
    local key
    key="$(config_key "$1" "$2")"
    [[ -v "CONFIG[$key]" ]]
}

config_get() {
    local key default_value
    key="$(config_key "$1" "$2")"
    default_value="${3:-}"
    if [[ -v "CONFIG[$key]" ]]; then
        printf '%s' "${CONFIG[$key]}"
    else
        printf '%s' "$default_value"
    fi
}

config_get_stripped() {
    strip_quotes "$(config_get "$1" "$2" "${3:-}")"
}

config_get_bool() {
    local raw
    raw="$(config_get_stripped "$1" "$2" "${3:-false}")"
    case "${raw,,}" in
        1|true|yes|on) return 0 ;;
        0|false|no|off|'') return 1 ;;
        *) die "Valore booleano non valido per [$1] $2: $raw" ;;
    esac
}

list_section_keys() {
    local section="$1"
    local key
    for key in "${!CONFIG[@]}"; do
        if [[ "$key" == "$section".* ]]; then
            printf '%s\n' "${key#"$section".}"
        fi
    done | sort
}

load_config() {
    local file="$1"
    local current_section="" line raw key value

    [[ -f "$file" ]] || die "File di configurazione non trovato: $file"

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line="$(trim "$raw")"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*[#\;] ]] && continue

        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        [[ -n "$current_section" ]] || die "Chiave fuori da una sezione nel file di configurazione: $raw"
        [[ "$line" == *"="* ]] || die "Riga non valida nel file di configurazione: $raw"

        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"
        CONFIG["$(config_key "$current_section" "$key")"]="$value"
    done < "$file"
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "Esegui lo script come root."
    fi
}

ensure_dir() {
    local dir="$1"
    [[ -n "$dir" ]] || return 0
    mkdir -p "$dir"
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if config_get_bool cleanup backup_configs true; then
        cp "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
    fi
}

replace_or_append_line() {
    local file="$1" regex="$2" newline="$3"
    if grep -Eq "$regex" "$file"; then
        sed -i -E "s|$regex.*|$newline|" "$file"
    else
        printf '\n%s\n' "$newline" >> "$file"
    fi
}

apply_python_overrides() {
    local section="$1" target_file="$2"
    local key value
    [[ -f "$target_file" ]] || die "File Python non trovato: $target_file"

    backup_file "$target_file"
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        value="$(config_get "$section" "$key")"
        if grep -Eq "^[[:space:]]*$key[[:space:]]*=" "$target_file"; then
            sed -i -E "s|^[[:space:]]*$key[[:space:]]*=.*|$key = $value|" "$target_file"
        else
            printf '\n%s = %s\n' "$key" "$value" >> "$target_file"
        fi
    done < <(list_section_keys "$section")
}

apply_env_overrides() {
    local section="$1" target_file="$2"
    local key value
    touch "$target_file"
    backup_file "$target_file"
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        value="$(strip_quotes "$(config_get "$section" "$key")")"
        replace_or_append_line "$target_file" "^[[:space:]]*${key}=" "${key}=${value}"
    done < <(list_section_keys "$section")
}

apt_install_packages() {
    local packages_raw packages=()
    packages_raw="$(config_get_stripped packages apt_packages "apparmor-utils apache2-utils curl git docker.io docker-compose-plugin tcpdump")"
    read -r -a packages <<< "$packages_raw"
    [[ "${#packages[@]}" -gt 0 ]] || return 0

    log "Aggiorno APT e installo i pacchetti richiesti"
    apt-get update
    apt-get install -y "${packages[@]}"
}

configure_tcpdump() {
    local enabled
    if ! config_get_bool traffic enabled true; then
        log "Cattura traffico disabilitata da configurazione"
        return 0
    fi

    local traffic_dir interface rotate_seconds rotate_size file_pattern bpf_filter
    traffic_dir="$(config_get_stripped traffic directory "/traffic")"
    interface="$(config_get_stripped traffic interface "game")"
    rotate_seconds="$(config_get_stripped traffic rotate_seconds "60")"
    rotate_size="$(config_get_stripped traffic rotate_size_mb "100")"
    file_pattern="$(config_get_stripped traffic file_pattern "dump-%m-%d-%H-%M-%S-%s.pcap")"
    bpf_filter="$(config_get_stripped traffic bpf_filter "port not 22")"

    ensure_dir "$traffic_dir"
    chown tcpdump:tcpdump "$traffic_dir" || true
    aa-complain tcpdump || true

    if pgrep -af "tcpdump.*${traffic_dir}" >/dev/null 2>&1; then
        warn "tcpdump sembra gia' attivo per ${traffic_dir}; salto l'avvio."
        return 0
    fi

    log "Avvio tcpdump su ${interface}, dump in ${traffic_dir}"
    (
        cd "$traffic_dir"
        nohup tcpdump -i "$interface" -G "$rotate_seconds" -C "$rotate_size" -w "$file_pattern" "$bpf_filter" >/var/log/adinstall-tcpdump.log 2>&1 &
    )
}

cleanup_installation() {
    if ! config_get_bool cleanup enabled false; then
        log "Pulizia iniziale disabilitata"
        return 0
    fi

    local workspace tulip_dir s4d_dir portainer_name portainer_volume traffic_dir
    workspace="$(config_get_stripped global workspace_dir "$(pwd)")"
    tulip_dir="${workspace}/$(config_get_stripped tulip repo_dir "tulip-auth")"
    s4d_dir="${workspace}/$(config_get_stripped s4dfarm repo_dir "S4DFarm")"
    portainer_name="$(config_get_stripped portainer container_name "portainer")"
    portainer_volume="$(config_get_stripped portainer volume_name "portainer_data")"
    traffic_dir="$(config_get_stripped traffic directory "/traffic")"

    if config_get_bool cleanup remove_repo_dirs true; then
        [[ -d "$tulip_dir" ]] && rm -rf -- "$tulip_dir"
        [[ -d "$s4d_dir" ]] && rm -rf -- "$s4d_dir"
    fi

    if config_get_bool cleanup remove_portainer_container false; then
        docker rm -f "$portainer_name" >/dev/null 2>&1 || true
    fi

    if config_get_bool cleanup remove_portainer_volume false; then
        docker volume rm "$portainer_volume" >/dev/null 2>&1 || true
    fi

    if config_get_bool cleanup wipe_traffic_dir false && [[ "$traffic_dir" != "/" ]]; then
        find "$traffic_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi

    if config_get_bool cleanup docker_prune false; then
        docker system prune -af || true
    fi
}

git_clone_or_update() {
    local repo_url="$1" target_dir="$2"
    if [[ -d "$target_dir/.git" ]]; then
        if config_get_bool git pull_existing true; then
            log "Aggiorno repository ${target_dir}"
            git -C "$target_dir" pull --ff-only
        else
            log "Repository gia' presente: ${target_dir}"
        fi
    else
        log "Clono ${repo_url} in ${target_dir}"
        git clone "$repo_url" "$target_dir"
    fi
}

setup_repositories() {
    local workspace tulip_repo s4d_repo tulip_dir s4d_dir
    workspace="$(config_get_stripped global workspace_dir "$(pwd)")"
    tulip_repo="$(config_get_stripped git tulip_repo_url "https://github.com/gcammisa/tulip-auth.git")"
    s4d_repo="$(config_get_stripped git s4dfarm_repo_url "https://github.com/gcammisa/S4DFarm.git")"
    tulip_dir="${workspace}/$(config_get_stripped tulip repo_dir "tulip-auth")"
    s4d_dir="${workspace}/$(config_get_stripped s4dfarm repo_dir "S4DFarm")"

    ensure_dir "$workspace"

    if config_get_bool tulip enabled true; then
        git_clone_or_update "$tulip_repo" "$tulip_dir"
    fi

    if config_get_bool s4dfarm enabled true; then
        git_clone_or_update "$s4d_repo" "$s4d_dir"
    fi
}

install_firegex() {
    if ! config_get_bool firegex enabled true; then
        log "Installazione Firegex disabilitata"
        return 0
    fi

    local install_url shell_path
    install_url="$(config_get_stripped firegex install_url "https://pwnzer0tt1.it/firegex.sh")"
    shell_path="$(command -v sh)"
    log "Installazione Firegex da ${install_url}"
    "$shell_path" <(curl -sLf "$install_url")
}

install_portainer() {
    if ! config_get_bool portainer enabled true; then
        log "Installazione Portainer disabilitata"
        return 0
    fi

    local container_name volume_name image restart_policy host_http host_https container_http container_https extra_args
    local -a extra_args_array=()
    container_name="$(config_get_stripped portainer container_name "portainer")"
    volume_name="$(config_get_stripped portainer volume_name "portainer_data")"
    image="$(config_get_stripped portainer image "portainer/portainer-ce:latest")"
    restart_policy="$(config_get_stripped portainer restart_policy "always")"
    host_http="$(config_get_stripped portainer host_http_port "8000")"
    host_https="$(config_get_stripped portainer host_https_port "9443")"
    container_http="$(config_get_stripped portainer container_http_port "8000")"
    container_https="$(config_get_stripped portainer container_https_port "9443")"
    extra_args="$(config_get_stripped portainer extra_args "")"
    if [[ -n "$extra_args" ]]; then
        read -r -a extra_args_array <<< "$extra_args"
    fi

    docker volume inspect "$volume_name" >/dev/null 2>&1 || docker volume create "$volume_name" >/dev/null

    if docker ps -a --format '{{.Names}}' | grep -Fxq "$container_name"; then
        log "Rimuovo container Portainer esistente"
        docker rm -f "$container_name" >/dev/null
    fi

    log "Avvio Portainer"
    docker run -d \
        -p "${host_http}:${container_http}" \
        -p "${host_https}:${container_https}" \
        --name "$container_name" \
        --restart="$restart_policy" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${volume_name}:/data" \
        "${extra_args_array[@]}" \
        "$image" >/dev/null
}

configure_tulip() {
    if ! config_get_bool tulip enabled true; then
        log "Configurazione Tulip disabilitata"
        return 0
    fi

    local workspace repo_dir tulip_dir py_file env_example env_file auth_user auth_pass compose_cmd
    workspace="$(config_get_stripped global workspace_dir "$(pwd)")"
    repo_dir="$(config_get_stripped tulip repo_dir "tulip-auth")"
    tulip_dir="${workspace}/${repo_dir}"
    py_file="${tulip_dir}/$(config_get_stripped tulip python_config_file "services/configurations.py")"
    env_example="${tulip_dir}/$(config_get_stripped tulip env_example_file ".env.example")"
    env_file="${tulip_dir}/$(config_get_stripped tulip env_file ".env")"

    [[ -d "$tulip_dir" ]] || die "Directory Tulip non trovata: $tulip_dir"
    [[ -f "$py_file" ]] || die "File config Tulip non trovato: $py_file"

    apply_python_overrides "tulip.python" "$py_file"

    if [[ ! -f "$env_file" && -f "$env_example" ]]; then
        cp "$env_example" "$env_file"
    fi
    apply_env_overrides "tulip.env" "$env_file"

    auth_user="$(config_get_stripped tulip.auth username "")"
    auth_pass="$(config_get_stripped tulip.auth password "")"
    if [[ -n "$auth_user" && -n "$auth_pass" ]]; then
        log "Genero .htpasswd per Tulip"
        htpasswd -bcB "${tulip_dir}/.htpasswd" "$auth_user" "$auth_pass" >/dev/null
    fi

    if config_get_bool tulip start_compose true && config_get_bool global start_services true; then
        compose_cmd="$(config_get_stripped tulip compose_command "docker compose up --build -d")"
        log "Avvio stack Tulip"
        (
            cd "$tulip_dir"
            eval "$compose_cmd"
        )
    fi
}

configure_s4dfarm() {
    if ! config_get_bool s4dfarm enabled true; then
        log "Configurazione S4DFarm disabilitata"
        return 0
    fi

    local workspace repo_dir s4d_dir py_file compose_cmd
    workspace="$(config_get_stripped global workspace_dir "$(pwd)")"
    repo_dir="$(config_get_stripped s4dfarm repo_dir "S4DFarm")"
    s4d_dir="${workspace}/${repo_dir}"
    py_file="${s4d_dir}/$(config_get_stripped s4dfarm python_config_file "server/app/config.py")"

    [[ -d "$s4d_dir" ]] || die "Directory S4DFarm non trovata: $s4d_dir"
    [[ -f "$py_file" ]] || die "File config S4DFarm non trovato: $py_file"

    apply_python_overrides "s4dfarm.python" "$py_file"

    if config_get_bool s4dfarm start_compose true && config_get_bool global start_services true; then
        compose_cmd="$(config_get_stripped s4dfarm compose_command "docker compose up --build -d")"
        log "Avvio stack S4DFarm"
        (
            cd "$s4d_dir"
            eval "$compose_cmd"
        )
    fi
}

print_summary() {
    local vm_ip tulip_port s4d_port portainer_port
    vm_ip="$(config_get_stripped tulip summary_vm_ip "")"
    tulip_port="$(config_get_stripped tulip summary_port "3001")"
    s4d_port="$(config_get_stripped s4dfarm summary_port "5137")"
    portainer_port="$(config_get_stripped portainer host_https_port "9443")"

    printf '\nConfigurazione completata.\n'
    [[ -n "$vm_ip" ]] && printf 'Tulip: http://%s:%s\n' "$vm_ip" "$tulip_port"
    [[ -n "$vm_ip" ]] && printf 'S4DFarm: http://%s:%s\n' "$vm_ip" "$s4d_port"
    [[ -n "$vm_ip" ]] && printf 'Portainer: https://%s:%s\n' "$vm_ip" "$portainer_port"
    printf 'Verifica i container con: docker ps -a\n'
}

print_banner() {
    echo -e "╔════════════════════════════════════════════════════════════════════╗"
    echo -e "║  ____       _      _       ____        _       _ _                 ║"
    echo -e "║ | __ ) _ __(_)_  _(_) __ _/ ___| _ __ | | ___ (_) |_ ___ _ __ ___  ║"
    echo -e "║ |  _ \| '__| \ \/ / |/ _\` \___ \| '_ \| |/ _ \| | __/ _ \ '__/ __|║"
    echo -e "║ | |_) | |  | |>  <| | (_| |___) | |_) | | (_) | | ||  __/ |  \__ \ ║"
    echo -e "║ |____/|_|  |_/_/\_\_|\__,_|____/| .__/|_|\___/|_|\__\___|_|  |___/ ║"
    echo -e "║                                 |_|                                ║"
    echo -e "║                                                                    ║"
    echo -e "║                         BrixiaSploiters                            ║"
    echo -e "╚════════════════════════════════════════════════════════════════════╝"
}

main() {
    print_banner
    require_root
    load_config "$CONFIG_FILE"

    log "Uso il file di configurazione: $CONFIG_FILE"
    cleanup_installation
    apt_install_packages
    configure_tcpdump
    setup_repositories
    install_firegex
    install_portainer
    configure_tulip
    configure_s4dfarm
    print_summary
}

main "$@"
