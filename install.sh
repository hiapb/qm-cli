#!/usr/bin/env bash

# ==========================================
# CLIProxyAPI 运维控制台
# 基于官方 docker-compose.yml 适配
# ==========================================

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_INSTALL_PATH="/opt/cliproxyapi"

COMPOSE_URL="https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/main/docker-compose.yml"
CONFIG_EXAMPLE_URL="https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/main/config.example.yaml"

ENV_FILE="/etc/cliproxyapi_env"
CRON_TAG_BEGIN="# CLIPROXYAPI_BACKUP_BEGIN"
CRON_TAG_END="# CLIPROXYAPI_BACKUP_END"
BACKUP_LOG="/var/log/cliproxyapi_backup.log"

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

# ---- 生成最小可用配置 ----
generate_config_yaml() {
    local config_path="$1"
    local server_port="$2"
    local api_key="$3"
    local management_key="$4"

    cat > "$config_path" <<EOF
server:
  port: ${server_port}

# 给客户端调用的 API Key
api-keys:
  - "${api_key}"

# 管理页面密钥
management-key: "${management_key}"

# 建议开启请求日志，排查问题方便些
request-log: true

# 下面留空，按需自行补充供应商配置
# 支持渠道可参考官方 config.example.yaml
# 例如：
#
# gemini-cli:
#   - path: "/root/.config/google-generative-ai"
#
# claude:
#   - email: "your-email@example.com"
#
# codex:
#   - email: "your-email@example.com"
EOF
}

# ---- 1. 一键部署系统 ----
deploy_cliproxyapi() {
    info "== 启动 CLIProxyAPI 自动化部署编排 =="
    require_cmd docker
    require_cmd curl
    require_cmd openssl

    local dc_cmd
    dc_cmd="$(docker_compose_cmd)"

    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path="${input_path:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$install_path" && -f "$install_path/docker-compose.yml" ]]; then
        err "该路径已存在部署实例，请先执行 [8] 卸载。"
        return
    fi

    mkdir -p "$install_path" || { err "创建安装目录失败。"; return; }
    echo "$install_path" > "$ENV_FILE"
    cd "$install_path" || return

    read -r -p "请输入对外 API 访问端口 [默认: 8317]: " input_port
    local host_port="${input_port:-8317}"

    info "正在拉取官方 docker-compose.yml ..."
    curl -sSL "$COMPOSE_URL" -o docker-compose.yml || { err "下载 docker-compose.yml 失败。"; return; }

    info "准备运行目录..."
    mkdir -p auths logs || { err "创建数据目录失败。"; return; }

    local api_key
    local management_key
    api_key="sk-$(random_string 12)"
    management_key="mgmt-$(random_string 12)"

    info "正在生成 .env ..."
    cat > .env <<EOF
DEPLOY=docker
CLI_PROXY_CONFIG_PATH=./config.yaml
CLI_PROXY_AUTH_PATH=./auths
CLI_PROXY_LOG_PATH=./logs
EOF

    info "正在生成最小可用 config.yaml ..."
    generate_config_yaml "./config.yaml" "8317" "$api_key" "$management_key"

    # 改写 docker-compose.yml 的端口映射，只改 8317 这一项
    if grep -q '"8317:8317"' docker-compose.yml; then
        sed -i "s/\"8317:8317\"/\"${host_port}:8317\"/g" docker-compose.yml
    else
        warn "未在 docker-compose.yml 中找到默认端口映射 8317:8317，可能上游结构已变化，请手动检查。"
    fi

    chmod -R 755 auths logs
    chmod 600 config.yaml .env

    info "正在拉起 CLIProxyAPI 容器..."
    $dc_cmd -f docker-compose.yml up -d || { err "容器启动失败，请检查 Docker 状态。"; return; }

    local server_ip
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

    warn "当前只是把 CLIProxyAPI 服务拉起来了。你还需要编辑 config.yaml，补充实际要用的渠道配置。"
}

# ---- 2. 升级服务 ----
upgrade_service() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的实例，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    info "正在拉取最新镜像并重建容器..."
    $(docker_compose_cmd) -f docker-compose.yml pull
    $(docker_compose_cmd) -f docker-compose.yml up -d
    info "升级服务完成！"
}

# ---- 3. 停止服务 ----
pause_service() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的实例，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.yml stop || true
    info "服务已停止。"
}

# ---- 4. 重启服务 ----
restart_service() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的实例，请先执行 [1] 一键部署。"
        return
    fi
    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.yml restart || true
    info "服务已重启。"
}

# ---- 5. 手动备份 ----
do_backup() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无法执行备份。"
        return
    fi

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    local backup_file="${backup_dir}/cliproxyapi_backup_${timestamp}.tar.gz"

    info "开始执行备份..."
    cd "$workdir" || return

    tar -czf "$backup_file" \
        docker-compose.yml \
        .env \
        config.yaml \
        auths \
        logs 2>/dev/null || {
        err "备份失败，请检查文件权限或目录是否完整。"
        return
    }

    cd "$backup_dir" || return
    ls -t cliproxyapi_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f

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
    local current_wd
    current_wd="$(get_workdir)"
    local search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"

    if [[ -d "$search_dir" ]]; then
        default_backup="$(ls -t "${search_dir}"/cliproxyapi_backup_*.tar.gz 2>/dev/null | head -n 1 || true)"
    fi

    local backup_path=""
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

    read -r -p "请输入恢复到的目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir="${input_path:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$target_dir" && -f "$target_dir/docker-compose.yml" ]]; then
        warn "目标目录已存在实例，恢复将覆盖现有数据。"
        read -r -p "是否强制覆盖继续？(y/N): " force_override
        if [[ ! "$force_override" =~ ^[Yy]$ ]]; then
            info "已终止恢复流程。"
            return
        fi
        cd "$target_dir" && $(docker_compose_cmd) -f docker-compose.yml down || true
    fi

    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir" || { err "解压失败，备份包可能损坏。"; return; }

    echo "$target_dir" > "$ENV_FILE"
    cd "$target_dir" || return

    chmod -R 755 auths logs || true
    chmod 600 config.yaml .env || true

    $(docker_compose_cmd) -f docker-compose.yml up -d || { err "恢复启动失败。"; return; }

    local server_ip
    server_ip="$(get_local_ip)"
    local host_port
    host_port="$(grep -oP '"\K[0-9]+(?=:8317")' docker-compose.yml | head -n 1)"
    [[ -z "$host_port" ]] && host_port="8317"

    local api_key
    api_key="$(grep -A2 '^api-keys:' config.yaml | grep -oP '"\K[^"]+' | head -n 1)"
    local management_key
    management_key="$(grep -oP '^management-key:\s*"\K[^"]+' config.yaml | head -n 1)"

    echo -e "\n=================================================="
    echo -e "\033[32m✅ CLIProxyAPI 恢复完成！\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "OpenAI 兼容接口: \033[36mhttp://${server_ip}:${host_port}/v1\033[0m"
    echo -e "管理页面: \033[36mhttp://${server_ip}:${host_port}/management.html\033[0m"
    echo -e "API Key: \033[33m${api_key:-请查看 config.yaml}\033[0m"
    echo -e "管理密钥: \033[33m${management_key:-请查看 config.yaml}\033[0m"
    echo -e "==================================================\n"
}

# ---- 7. 定时备份 ----
setup_auto_backup() {
    require_cmd crontab
    info "== 定时备份策略管控 =="

    local existing_cron=""
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

    local cron_spec=""

    if [[ "$cron_type" == "1" ]]; then
        read -r -p "请输入间隔分钟数 (例如 30): " min_interval
        if [[ ! "$min_interval" =~ ^[1-9][0-9]*$ ]]; then err "输入无效。"; return; fi
        cron_spec="*/${min_interval} * * * *"
        info "已设置：每 ${min_interval} 分钟执行一次。"
    elif [[ "$cron_type" == "2" ]]; then
        read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
        if [[ ! "$cron_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then err "时间格式不正确。"; return; fi
        local hour="${cron_time%:*}"
        local minute="${cron_time#*:}"
        hour="$(echo "$hour" | sed 's/^0*//')"; [[ -z "$hour" ]] && hour="0"
        minute="$(echo "$minute" | sed 's/^0*//')"; [[ -z "$minute" ]] && minute="0"
        cron_spec="${minute} ${hour} * * *"
        info "已设置：每天 ${cron_time} 执行一次。"
    elif [[ "$cron_type" == "3" ]]; then
        local tmp_cron
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

    local tmp_cron
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
    local workdir
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
    $(docker_compose_cmd) -f docker-compose.yml down -v || true

    cd /
    rm -rf "$workdir" || true
    rm -f "$ENV_FILE" || true

    local tmp_cron
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron" || true

    info "CLIProxyAPI 已彻底卸载。"
}

# ---- 9. 查看状态 ----
show_status() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署实例。"
        return
    fi
    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.yml ps
}

# ---- 交互式主菜单 ----
main_menu() {
    clear
    echo "==================================================="
    echo "               CLIProxyAPI 一键管理                "
    echo "==================================================="
    local wd
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
    echo "  0) 退出脚本"
    echo "==================================================="

    read -r -p "请输入操作序号 [0-9]: " choice
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
        0) info "欢迎下次使用，再见。"; exit 0 ;;
        *) warn "无效的指令，请重新输入。" ;;
    esac
}

# ---- 路由引擎 ----
if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then
        die "权限收敛：必须使用 Root 权限执行脚本。"
    fi
    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
