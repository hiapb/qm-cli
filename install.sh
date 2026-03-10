#!/usr/bin/env bash

# ==========================================
# CLIProxyAPI 运维控制台
# 适配当前官方 docker-compose.yml / config.example.yaml
# ==========================================

set -u

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_INSTALL_PATH="/opt/cliproxyapi"

COMPOSE_URL="https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/main/docker-compose.yml"
CONFIG_EXAMPLE_URL="https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/main/config.example.yaml"

ENV_FILE="/etc/cliproxyapi_env"
CRON_TAG_BEGIN="# CLIPROXYAPI_BACKUP_BEGIN"
CRON_TAG_END="# CLIPROXYAPI_BACKUP_END"
BACKUP_LOG="/var/log/cliproxyapi_backup.log"

DEFAULT_CONTAINER_PORT="8317"
DEFAULT_HOST_PORT="8317"
DEFAULT_PANEL_REPO="https://github.com/router-for-me/Cli-Proxy-API-Management-Center"

# ---- 基础工具函数 ----
info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1，请安装后重试。"
}

get_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

get_workdir() {
    if [[ -f "$ENV_FILE" ]]; then
        local dir
        dir="$(cat "$ENV_FILE" 2>/dev/null)"
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi
    echo ""
}

random_string() {
    openssl rand -hex "${1:-16}"
}

run_dc() {
    local dc_cmd
    dc_cmd="$(docker_compose_cmd)"
    $dc_cmd -f docker-compose.yml "$@"
}

ensure_runtime_dirs() {
    mkdir -p auths logs backups || return 1
    chmod 755 auths logs backups || true
    return 0
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q ":${port} "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -q "[.:]${port}[[:space:]]"
    else
        return 1
    fi
}

get_host_port_from_compose() {
    if [[ -f docker-compose.yml ]]; then
        grep -oP '"\K[0-9]+(?=:8317")' docker-compose.yml 2>/dev/null | head -n 1
    fi
}

get_api_key_from_config() {
    if [[ -f config.yaml ]]; then
        awk '
            /^api-keys:/ { in_keys=1; next }
            in_keys && /^[^[:space:]-]/ { exit }
            in_keys && /^[[:space:]]*-[[:space:]]*"/ {
                gsub(/^[[:space:]]*-[[:space:]]*"/, "", $0)
                gsub(/".*$/, "", $0)
                print $0
                exit
            }
        ' config.yaml
    fi
}

get_management_key_from_config() {
    if [[ -f config.yaml ]]; then
        grep -oP '^[[:space:]]*secret-key:\s*"\K[^"]+' config.yaml 2>/dev/null | head -n 1
    fi
}

health_check_service() {
    local host_port="$1"
    local api_key="$2"

    if ! command -v curl >/dev/null 2>&1; then
        warn "系统未安装 curl，跳过健康检查。"
        return 0
    fi

    local code_models=""
    local code_panel=""

    code_models="$(curl -sS -o /tmp/cliproxyapi_models.out -w "%{http_code}" \
        -H "Authorization: Bearer ${api_key}" \
        "http://127.0.0.1:${host_port}/v1/models" || true)"

    code_panel="$(curl -sS -o /tmp/cliproxyapi_panel.out -w "%{http_code}" \
        "http://127.0.0.1:${host_port}/management.html" || true)"

    if [[ "$code_models" =~ ^(200|401|403|500)$ ]]; then
        info "API 健康检查已执行，/v1/models 返回 HTTP ${code_models}。"
    else
        warn "API 健康检查异常，/v1/models 返回 HTTP ${code_models:-unknown}。"
    fi

    if [[ "$code_panel" == "200" ]]; then
        info "管理页面检查通过，/management.html 可访问。"
    elif [[ "$code_panel" == "404" ]]; then
        warn "管理页面返回 404。通常表示控制面板资源未下载成功，或已被配置禁用。"
    else
        warn "管理页面检查结果：HTTP ${code_panel:-unknown}。"
    fi

    rm -f /tmp/cliproxyapi_models.out /tmp/cliproxyapi_panel.out 2>/dev/null || true
}

wait_for_container_ready() {
    local timeout="${1:-30}"
    local elapsed=0

    while (( elapsed < timeout )); do
        local status
        status="$(run_dc ps --format json 2>/dev/null | grep -o '"State":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)"

        if [[ "$status" == "running" ]]; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

download_official_files() {
    info "正在拉取官方 docker-compose.yml ..."
    curl -fsSL "$COMPOSE_URL" -o docker-compose.yml || return 1

    # 仅作留档参考，失败不阻断部署
    curl -fsSL "$CONFIG_EXAMPLE_URL" -o config.example.yaml >/dev/null 2>&1 || true
    return 0
}

patch_compose_ports() {
    local host_port="$1"

    if grep -q '"8317:8317"' docker-compose.yml; then
        sed -i "s/\"8317:8317\"/\"${host_port}:8317\"/g" docker-compose.yml
    else
        warn "未在 docker-compose.yml 中找到默认端口映射 8317:8317，请手动检查。"
    fi
}

write_env_file() {
    cat > .env <<EOF
DEPLOY=docker
CLI_PROXY_CONFIG_PATH=./config.yaml
CLI_PROXY_AUTH_PATH=./auths
CLI_PROXY_LOG_PATH=./logs
EOF
}

generate_config_yaml() {
    local config_path="$1"
    local server_port="$2"
    local api_key="$3"
    local management_key="$4"

    cat > "$config_path" <<EOF
host: ""
port: ${server_port}

tls:
  enable: false
  cert: ""
  key: ""

remote-management:
  allow-remote: true
  secret-key: "${management_key}"
  disable-control-panel: false
  panel-github-repository: "${DEFAULT_PANEL_REPO}"

auth-dir: "/root/.cli-proxy-api"

api-keys:
  - "${api_key}"

debug: true
logging-to-file: false
logs-max-total-size-mb: 0
error-logs-max-files: 10
usage-statistics-enabled: false
proxy-url: ""
force-model-prefix: false
passthrough-headers: false
request-retry: 3
max-retry-credentials: 0
max-retry-interval: 30

quota-exceeded:
  switch-project: true
  switch-preview-model: true

routing:
  strategy: "round-robin"

ws-auth: false
nonstream-keepalive-interval: 0

# 下面按需自行补充实际渠道配置
# 例如：
#
# gemini-api-key:
#   - api-key: "AIzaSy..."
#
# codex-api-key:
#   - api-key: "sk-..."
#
# claude-api-key:
#   - api-key: "sk-..."
#
# openai-compatibility:
#   - name: "openrouter"
#     base-url: "https://openrouter.ai/api/v1"
#     api-key-entries:
#       - api-key: "sk-or-..."
#     models:
#       - name: "moonshotai/kimi-k2:free"
#         alias: "kimi-k2"
EOF
}

verify_backup_file() {
    local backup_file="$1"
    if [[ ! -f "$backup_file" ]]; then
        return 1
    fi
    gzip -t "$backup_file" >/dev/null 2>&1
}

backup_checksum() {
    local backup_file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$(basename "$backup_file")" > "$(basename "$backup_file").sha256"
    fi
}

# ---- 1. 一键部署系统 ----
deploy_cliproxyapi() {
    info "== 启动 CLIProxyAPI 自动化部署编排 =="
    require_cmd docker
    require_cmd curl
    require_cmd openssl

    local install_path=""
    local input_path=""
    local input_port=""
    local host_port=""
    local dc_cmd=""
    local api_key=""
    local management_key=""
    local server_ip=""

    dc_cmd="$(docker_compose_cmd)"

    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    install_path="${input_path:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$install_path" && -f "$install_path/docker-compose.yml" ]]; then
        err "该路径已存在部署实例，请先执行 [8] 卸载，或换一个路径。"
        return
    fi

    mkdir -p "$install_path" || { err "创建安装目录失败。"; return; }
    echo "$install_path" > "$ENV_FILE"
    cd "$install_path" || return

    read -r -p "请输入对外 API 访问端口 [默认: $DEFAULT_HOST_PORT]: " input_port
    host_port="${input_port:-$DEFAULT_HOST_PORT}"

    if [[ ! "$host_port" =~ ^[1-9][0-9]{0,4}$ ]] || (( host_port > 65535 )); then
        err "端口输入无效。"
        return
    fi

    if port_in_use "$host_port"; then
        err "端口 ${host_port} 已被占用，请换一个端口。"
        return
    fi

    download_official_files || { err "下载官方文件失败。"; return; }

    info "准备运行目录..."
    ensure_runtime_dirs || { err "创建数据目录失败。"; return; }

    api_key="sk-$(random_string 12)"
    management_key="mgmt-$(random_string 12)"

    info "正在生成 .env ..."
    write_env_file

    info "正在生成最小可用 config.yaml ..."
    generate_config_yaml "./config.yaml" "$DEFAULT_CONTAINER_PORT" "$api_key" "$management_key"

    info "正在调整 docker-compose 端口映射 ..."
    patch_compose_ports "$host_port"

    chmod 600 config.yaml .env
    chmod 644 docker-compose.yml config.example.yaml 2>/dev/null || true

    info "正在拉起 CLIProxyAPI 容器..."
    $dc_cmd -f docker-compose.yml up -d || { err "容器启动失败，请检查 Docker 状态。"; return; }

    if wait_for_container_ready 30; then
        info "容器已进入运行状态。"
    else
        warn "容器未在预期时间内进入 running，建议立刻查看日志。"
    fi

    server_ip="$(get_local_ip)"

    echo -e "\n=================================================="
    echo -e "\033[32mCLIProxyAPI 部署完成！\033[0m"
    echo -e "请在服务器防火墙/安全组中放行 \033[31m${host_port}\033[0m 端口"
    echo -e "API 基地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "OpenAI 兼容接口: \033[36mhttp://${server_ip}:${host_port}/v1\033[0m"
    echo -e "管理页面: \033[36mhttp://${server_ip}:${host_port}/management.html\033[0m"
    echo -e "API Key: \033[33m${api_key}\033[0m"
    echo -e "管理密钥: \033[33m${management_key}\033[0m"
    echo -e "配置文件: \033[36m${install_path}/config.yaml\033[0m"
    echo -e "认证目录: \033[36m${install_path}/auths\033[0m"
    echo -e "日志目录: \033[36m${install_path}/logs\033[0m"
    echo -e "==================================================\n"

    health_check_service "$host_port" "$api_key"

    warn "服务已部署。你仍需按业务需要编辑 config.yaml，补充实际要用的渠道配置。"
}

# ---- 2. 升级服务 ----
upgrade_service() {
    local workdir=""
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的实例，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    info "正在拉取最新镜像并重建容器..."
    run_dc pull
    run_dc up -d
    info "升级服务完成。"

    local host_port=""
    local api_key=""
    host_port="$(get_host_port_from_compose)"
    [[ -z "$host_port" ]] && host_port="$DEFAULT_HOST_PORT"
    api_key="$(get_api_key_from_config)"
    [[ -n "$api_key" ]] && health_check_service "$host_port" "$api_key"
}

# ---- 3. 停止服务 ----
pause_service() {
    local workdir=""
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的实例，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    run_dc stop || true
    info "服务已停止。"
}

# ---- 4. 重启服务 ----
restart_service() {
    local workdir=""
    local host_port=""
    local api_key=""

    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的实例，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    run_dc restart || true
    info "服务已重启。"

    host_port="$(get_host_port_from_compose)"
    [[ -z "$host_port" ]] && host_port="$DEFAULT_HOST_PORT"
    api_key="$(get_api_key_from_config)"
    [[ -n "$api_key" ]] && health_check_service "$host_port" "$api_key"
}

# ---- 5. 手动备份 ----
do_backup() {
    local workdir=""
    local backup_dir=""
    local timestamp=""
    local backup_file=""

    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无法执行备份。"
        return
    fi

    cd "$workdir" || return

    if [[ ! -f docker-compose.yml || ! -f .env || ! -f config.yaml || ! -d auths || ! -d logs ]]; then
        err "备份前检查失败：缺少必要文件或目录。"
        return
    fi

    backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    backup_file="${backup_dir}/cliproxyapi_backup_${timestamp}.tar.gz"

    info "开始执行备份..."
    tar -czf "$backup_file" \
        docker-compose.yml \
        .env \
        config.yaml \
        auths \
        logs \
        config.example.yaml 2>/dev/null || {
        err "备份失败，请检查文件权限或目录是否完整。"
        return
    }

    if ! verify_backup_file "$backup_file"; then
        err "备份包校验失败，gzip 测试未通过。"
        rm -f "$backup_file"
        return
    fi

    cd "$backup_dir" || return
    backup_checksum "$backup_file"
    ls -t cliproxyapi_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f
    ls -t cliproxyapi_backup_*.tar.gz.sha256 2>/dev/null | awk 'NR>3' | xargs -r rm -f

    info "备份执行完毕。当前可用备份如下："
    for f in $(ls -t cliproxyapi_backup_*.tar.gz 2>/dev/null); do
        local abs_path="${backup_dir}/${f}"
        local fsize
        fsize="$(du -h "$f" | cut -f1)"
        echo -e "  📦 \033[36m${abs_path}\033[0m (大小: ${fsize})"
    done
}

# ---- 6. 恢复备份 ----
restore_backup() {
    info "== 灾备恢复 / 数据迁入引擎 =="

    local default_backup=""
    local current_wd=""
    local search_dir=""
    local backup_path=""
    local input_backup=""
    local input_path=""
    local target_dir=""
    local force_override=""
    local server_ip=""
    local host_port=""
    local api_key=""
    local management_key=""

    current_wd="$(get_workdir)"
    search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"

    if [[ -d "$search_dir" ]]; then
        default_backup="$(ls -t "${search_dir}"/cliproxyapi_backup_*.tar.gz 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -n "$default_backup" ]]; then
        echo -e "已检测到最新备份快照: \033[33m${default_backup}\033[0m"
        read -r -p "请输入备份文件路径 [直接回车使用默认]: " input_backup
        backup_path="${input_backup:-$default_backup}"
    else
        read -r -p "请输入备份文件(.tar.gz)路径: " backup_path
    fi

    if [[ ! -f "$backup_path" ]]; then
        err "目标路径下未找到有效备份文件，请检查。"
        return
    fi

    if ! verify_backup_file "$backup_path"; then
        err "备份文件校验失败，gzip 测试未通过。"
        return
    fi

    read -r -p "请输入恢复到的目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    target_dir="${input_path:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$target_dir" && -f "$target_dir/docker-compose.yml" ]]; then
        warn "目标目录已存在实例，恢复将覆盖现有数据。"
        read -r -p "是否强制覆盖继续？(y/N): " force_override
        if [[ ! "$force_override" =~ ^[Yy]$ ]]; then
            info "已终止恢复流程。"
            return
        fi
        cd "$target_dir" || return
        run_dc down || true
    fi

    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir" || { err "解压失败，备份包可能损坏。"; return; }

    echo "$target_dir" > "$ENV_FILE"
    cd "$target_dir" || return

    mkdir -p auths logs backups
    chmod -R 755 auths logs backups || true
    chmod 600 config.yaml .env 2>/dev/null || true

    run_dc up -d || { err "恢复启动失败。"; return; }

    if wait_for_container_ready 30; then
        info "容器已进入运行状态。"
    else
        warn "容器未在预期时间内进入 running，建议查看日志。"
    fi

    server_ip="$(get_local_ip)"
    host_port="$(get_host_port_from_compose)"
    [[ -z "$host_port" ]] && host_port="$DEFAULT_HOST_PORT"

    api_key="$(get_api_key_from_config)"
    management_key="$(get_management_key_from_config)"

    echo -e "\n=================================================="
    echo -e "\033[32m✅ CLIProxyAPI 恢复完成！\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "OpenAI 兼容接口: \033[36mhttp://${server_ip}:${host_port}/v1\033[0m"
    echo -e "管理页面: \033[36mhttp://${server_ip}:${host_port}/management.html\033[0m"
    echo -e "API Key: \033[33m${api_key:-请查看 config.yaml}\033[0m"
    echo -e "管理密钥: \033[33m${management_key:-请查看 config.yaml}\033[0m"
    echo -e "==================================================\n"

    [[ -n "$api_key" ]] && health_check_service "$host_port" "$api_key"
}

# ---- 7. 定时备份 ----
setup_auto_backup() {
    require_cmd crontab
    info "== 定时备份策略管控 =="

    local existing_cron=""
    local cron_type=""
    local cron_spec=""
    local min_interval=""
    local cron_time=""
    local hour=""
    local minute=""
    local tmp_cron=""

    existing_cron="$(crontab -l 2>/dev/null | sed -n "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/p" | grep -v "^#" || true)"

    if [[ -n "$existing_cron" ]]; then
        echo -e "\033[36m>>> 发现当前正在运行的定时备份任务:\033[0m"
        echo -e "\033[33m${existing_cron}\033[0m"
        echo -e "---------------------------------------------------"
        read -r -p "是否需要重新设置或覆盖该任务？(y/N): " reset_cron
        if [[ ! "$reset_cron" =~ ^[Yy]$ ]]; then
            info "已保留当前配置，操作取消。"
            return
        fi
    else
        echo -e "当前未检测到定时备份任务。"
    fi

    echo " 1) 按分钟间隔循环备份 (例如：每 30 分钟)"
    echo " 2) 按每日固定时间点备份 (例如：每天 04:30)"
    echo " 3) 删除当前的定时备份任务"
    read -r -p "请选择策略 [1/2/3]: " cron_type

    if [[ "$cron_type" == "1" ]]; then
        read -r -p "请输入间隔分钟数 (例如 30): " min_interval
        if [[ ! "$min_interval" =~ ^[1-9][0-9]*$ ]]; then
            err "输入无效。"
            return
        fi
        cron_spec="*/${min_interval} * * * *"
        info "已设置：每 ${min_interval} 分钟执行一次。"
    elif [[ "$cron_type" == "2" ]]; then
        read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
        if [[ ! "$cron_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            err "时间格式不正确。"
            return
        fi
        hour="${cron_time%:*}"
        minute="${cron_time#*:}"
        hour="$(echo "$hour" | sed 's/^0*//')"; [[ -z "$hour" ]] && hour="0"
        minute="$(echo "$minute" | sed 's/^0*//')"; [[ -z "$minute" ]] && minute="0"
        cron_spec="${minute} ${hour} * * *"
        info "已设置：每天 ${cron_time} 执行一次。"
    elif [[ "$cron_type" == "3" ]]; then
        tmp_cron="$(mktemp)"
        crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
        crontab "$tmp_cron" 2>/dev/null || true
        rm -f "$tmp_cron"
        info "定时备份任务已清理。"
        return
    else
        err "无效的选择。"
        return
    fi

    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    cat >> "$tmp_cron" <<EOF
${CRON_TAG_BEGIN}
${cron_spec} bash ${SCRIPT_PATH} run-backup >> ${BACKUP_LOG} 2>&1
${CRON_TAG_END}
EOF
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron"

    info "新的定时任务已成功写入 crontab。"
}

# ---- 8. 彻底卸载 ----
uninstall_service() {
    local workdir=""
    local confirm=""
    local tmp_cron=""

    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无需卸载。"
        return
    fi

    echo -e "\033[31m⚠️ 警告：这将彻底删除 CLIProxyAPI 容器及业务数据！\033[0m"
    read -r -p "确认完全卸载？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "操作已取消。"
        return
    fi

    cd "$workdir" || return
    run_dc down -v || true

    cd /
    rm -rf "$workdir" || true
    rm -f "$ENV_FILE" || true

    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron" || true

    info "CLIProxyAPI 已彻底卸载。"
}

# ---- 9. 查看状态 ----
show_status() {
    local workdir=""
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署实例。"
        return
    fi
    cd "$workdir" || return
    run_dc ps
}

# ---- 10. 查看日志 ----
show_logs() {
    local workdir=""
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署实例。"
        return
    fi
    cd "$workdir" || return
    docker logs --tail 200 cli-proxy-api
}

# ---- 11. 修复当前实例配置 ----
repair_current_install() {
    local workdir=""
    local host_port=""
    local api_key=""
    local management_key=""

    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署实例。"
        return
    fi

    cd "$workdir" || return

    if [[ ! -f docker-compose.yml ]]; then
        err "未找到 docker-compose.yml。"
        return
    fi

    mkdir -p auths logs backups
    chmod -R 755 auths logs backups || true

    host_port="$(get_host_port_from_compose)"
    [[ -z "$host_port" ]] && host_port="$DEFAULT_HOST_PORT"

    api_key="$(get_api_key_from_config)"
    [[ -z "$api_key" ]] && api_key="sk-$(random_string 12)"

    management_key="$(get_management_key_from_config)"
    [[ -z "$management_key" ]] && management_key="mgmt-$(random_string 12)"

    cp -f config.yaml "config.yaml.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    generate_config_yaml "./config.yaml" "$DEFAULT_CONTAINER_PORT" "$api_key" "$management_key"
    chmod 600 config.yaml

    info "配置已重写为兼容当前官方结构的版本。"
    run_dc down || true
    run_dc up -d || true

    if wait_for_container_ready 30; then
        info "容器已重新运行。"
    else
        warn "容器仍未进入 running，请查看 [10] 查看日志。"
    fi

    echo -e "\n=================================================="
    echo -e "API Key: \033[33m${api_key}\033[0m"
    echo -e "管理密钥: \033[33m${management_key}\033[0m"
    echo -e "==================================================\n"

    health_check_service "$host_port" "$api_key"
}

# ---- 交互式主菜单 ----
main_menu() {
    clear
    echo "==================================================="
    echo "               CLIProxyAPI 一键管理                "
    echo "==================================================="
    local wd=""
    wd="$(get_workdir)"
    echo -e " 实例运行路径: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) 查看状态"
    echo " 10) 查看日志"
    echo " 11) 修复当前实例配置"
    echo "  0) 退出脚本"
    echo "==================================================="

    local choice=""
    read -r -p "请输入操作序号 [0-11]: " choice
    case "$choice" in
        1) deploy_cliproxyapi ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) show_status ;;
        10) show_logs ;;
        11) repair_current_install ;;
        0) info "欢迎下次使用，再见。" ; exit 0 ;;
        *) warn "无效的指令，请重新输入。" ;;
    esac
}

# ---- 路由引擎 ----
if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then
        die "必须使用 Root 权限执行脚本。"
    fi
    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
