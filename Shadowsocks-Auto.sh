#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 配置文件路径
SS_CONFIG_PATH="/etc/shadowsocks/config.json"
STLS_CONFIG_PATH="/etc/systemd/system/shadow-tls.service"

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：${PLAIN}必须使用 root 用户运行此脚本！"
        exit 1
    fi
}

# Shadowsocks 双后端管理。Snap 与独立二进制共用节点信息。
SS_STATE_DIR="/etc/shadowsocks"
SS_BINARY_CONFIG="/etc/shadowsocks/config.json"
SS_SNAP_CONFIG="/var/snap/shadowsocks-rust/common/etc/shadowsocks-rust/config.json"
SS_UNIT="/etc/systemd/system/shadowsocks.service"
SS_BACKEND_FILE="/etc/shadowsocks/backend"
SS_SNAP_APP="shadowsocks-rust.ssserver-daemon"
SS_BACKEND=""
SS_REQUESTED_BACKEND="${SS_BACKEND_MODE:-auto}"

ss_error() { printf '%s\n' "错误：$*" >&2; }

check_system() {
    [[ "$(uname -s)" == Linux ]] || { ss_error "仅支持 Linux。"; return 1; }
    command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || {
        ss_error "需要正在运行的 systemd；不支持未启用 systemd 的容器。"; return 1;
    }
}

check_tool() {
    local tool pkg pm
    local pkgs=()
    if command -v apt-get >/dev/null; then pm=apt-get
    elif command -v dnf >/dev/null; then pm=dnf
    elif command -v yum >/dev/null; then pm=yum
    else ss_error "需要 apt-get、dnf 或 yum。"; return 1; fi
    for tool in curl jq openssl tar xz sha256sum ss timeout flock wget; do
        command -v "$tool" >/dev/null && continue
        pkg="$tool"
        case "$tool" in
            xz) [[ "$pm" == apt-get ]] && pkg=xz-utils ;;
            sha256sum) pkg=coreutils ;;
            timeout) pkg=coreutils ;;
            flock) pkg=util-linux ;;
            ss) [[ "$pm" == apt-get ]] && pkg=iproute2 || pkg=iproute ;;
        esac
        pkgs+=("$pkg")
    done
    if ((${#pkgs[@]})); then
        if [[ "$pm" == apt-get ]]; then
            apt-get update && apt-get install -y ca-certificates "${pkgs[@]}" || return 1
        else
            "$pm" install -y ca-certificates "${pkgs[@]}" || return 1
        fi
    fi
}

ss_snap_installed() {
    command -v snap >/dev/null && snap list shadowsocks-rust >/dev/null 2>&1
}

ss_detect_backend() {
    SS_BACKEND=""
    if [[ -f "$SS_BACKEND_FILE" ]]; then
        IFS= read -r SS_BACKEND < "$SS_BACKEND_FILE" || :
    fi
    case "$SS_BACKEND" in
        binary|snap) ;;
        *)
            if systemctl is-active --quiet "snap.${SS_SNAP_APP}.service"; then SS_BACKEND=snap
            elif [[ -f "$SS_UNIT" ]]; then SS_BACKEND=binary
            elif ss_snap_installed; then SS_BACKEND=snap
            else return 1; fi ;;
    esac
    ss_set_config_path
}

ss_set_config_path() {
    if [[ "$SS_BACKEND" == snap ]]; then SS_CONFIG_PATH="$SS_SNAP_CONFIG"
    else SS_CONFIG_PATH="$SS_BINARY_CONFIG"; fi
}

ss_service() {
    local action=$1
    if [[ "$SS_BACKEND" == snap ]]; then
        case "$action" in
            enable) snap start --enable "$SS_SNAP_APP" ;;
            disable) snap stop --disable "$SS_SNAP_APP" ;;
            active) systemctl is-active --quiet "snap.${SS_SNAP_APP}.service" ;;
            *) snap "$action" "$SS_SNAP_APP" ;;
        esac
    else
        case "$action" in
            enable) systemctl enable --now shadowsocks.service ;;
            disable) systemctl disable --now shadowsocks.service ;;
            active) systemctl is-active --quiet shadowsocks.service ;;
            *) systemctl "$action" shadowsocks.service ;;
        esac
    fi
}

ss_logs() {
    if [[ "$SS_BACKEND" == snap ]]; then snap logs -n=30 "$SS_SNAP_APP" >&2
    else journalctl -u shadowsocks.service -n 30 --no-pager >&2; fi
}

# 不仅检查 systemctl 返回值，还观察 TCP、UDP 是否都已监听。
ss_wait_ready() {
    local port=$1 i
    for ((i=0; i<10; i++)); do
        if ss_service active &&
           ss -H -lnt "sport = :$port" | grep -q . &&
           ss -H -lnu "sport = :$port" | grep -q .; then
            sleep 1
            ss_service active && return 0
        fi
        sleep 1
    done
    ss_logs
    return 1
}

ss_fetch() {
    curl --fail --location --silent --show-error --connect-timeout 15 \
        --max-time 180 --retry 2 "$1" -o "$2"
}

ss_install_binary() {
    local temp=$1 suffix api asset url digest bin
    case "$(uname -m)" in
        x86_64) suffix=x86_64-unknown-linux-musl ;;
        i386|i486|i586|i686) suffix=i686-unknown-linux-musl ;;
        aarch64|arm64) suffix=aarch64-unknown-linux-musl ;;
        armv7l) suffix=armv7-unknown-linux-musleabihf ;;
        armv6l) suffix=arm-unknown-linux-musleabihf ;;
        *) ss_error "没有适配此架构的独立包，auto 模式将尝试 Snap。"; return 1 ;;
    esac
    api="$temp/release.json"
    ss_fetch https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest "$api" || return 1
    asset=$(jq -c --arg suffix ".$suffix.tar.xz" \
        '[.assets[] | select(.name | endswith($suffix))] | if length == 1 then .[0] else empty end' "$api") || return 1
    [[ -n "$asset" ]] || { ss_error "此版本没有 $suffix 包。"; return 1; }
    url=$(jq -r '.browser_download_url' <<< "$asset")
    [[ "$url" == https://github.com/shadowsocks/shadowsocks-rust/releases/download/* ]] || return 1
    printf '下载 %s\n' "$(jq -r '.name' <<< "$asset")"
    ss_fetch "$url" "$temp/server.tar.xz" || return 1
    digest=$(jq -r '.digest // empty' <<< "$asset")
    if [[ "$digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]]; then
        [[ "$(sha256sum "$temp/server.tar.xz" | awk '{print $1}')" == "${digest#sha256:}" ]] || {
            ss_error "下载文件 SHA256 不匹配。"; return 1;
        }
    else
        printf '上游未提供 SHA256 digest，使用 HTTPS 下载资产。\n' >&2
    fi
    mkdir -p "$temp/unpack" || return 1
    # 只提取 ssserver，拒绝绝对路径、父路径以及链接。
    bin=$(tar -tJf "$temp/server.tar.xz" | awk '$0=="ssserver" || $0=="./ssserver" {print; exit}')
    [[ -n "$bin" ]] || { ss_error "归档中没有 ssserver。"; return 1; }
    tar -xJf "$temp/server.tar.xz" -C "$temp/unpack" --no-same-owner "$bin" || return 1
    [[ -f "$temp/unpack/ssserver" && ! -L "$temp/unpack/ssserver" ]] || return 1
    chmod 755 "$temp/unpack/ssserver" || return 1
    if ! timeout 15 "$temp/unpack/ssserver" --version >"$temp/binary.log" 2>&1; then
        cat "$temp/binary.log" >&2
        ss_error "二进制运行失败（可能是架构、内核或运行库兼容性）。"
        return 1
    fi
    install -m 755 "$temp/unpack/ssserver" /usr/local/bin/ssserver || return 1
    cat > "$SS_UNIT" <<'UNIT'
[Unit]
Description=Shadowsocks Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

ss_install_snap() {
    command -v apt-get >/dev/null || {
        ss_error "本脚本的 Snap 自动部署仅支持 Debian/Ubuntu（apt-get）。"; return 1;
    }
    if ! command -v snap >/dev/null; then
        apt-get update && apt-get install -y snapd || return 1
    fi
    systemctl enable --now snapd.socket || return 1
    timeout 180 snap wait system seed.loaded || {
        ss_error "snapd 初始化失败或超时；检查 journalctl -u snapd。"; return 1;
    }
    if ! ss_snap_installed; then
        snap install shadowsocks-rust || {
            ss_error "Snap 安装失败；请检查 snapd、SquashFS、挂载权限及商店连接。"; return 1;
        }
    fi
    timeout 30 snap run shadowsocks-rust.ssserver --version || return 1
    mkdir -p "$(dirname "$SS_SNAP_CONFIG")"
}

ss_choose_config() {
    local choice custom old_method="" old_password="" value
    ss_port="" method="" ss_password="" node_name=""
    if [[ -f "$SS_CONFIG_PATH" ]]; then
        ss_port=$(jq -r '.server_port // empty' "$SS_CONFIG_PATH") || return 1
        old_method=$(jq -r '.method // empty' "$SS_CONFIG_PATH")
        old_password=$(jq -r '.password // empty' "$SS_CONFIG_PATH")
    fi
    while true; do
        read -r -p "监听端口（1024-65535，回车使用 ${ss_port:-随机端口}）: " value || return 1
        value=${value:-${ss_port:-$((RANDOM + 20000))}}
        if [[ "$value" =~ ^[0-9]{1,5}$ ]] && ((10#$value >= 1024 && 10#$value <= 65535)); then
            ss_port=$((10#$value)); break
        fi
        printf '端口无效，请重新输入。\n'
    done
    local methods=(
        2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305
        aes-256-gcm aes-128-gcm chacha20-ietf-poly1305 none
        aes-128-cfb aes-192-cfb aes-256-cfb aes-128-ctr aes-192-ctr aes-256-ctr
        camellia-128-cfb camellia-192-cfb camellia-256-cfb rc4-md5 chacha20-ietf
    )
    for ((choice=0; choice<${#methods[@]}; choice++)); do
        printf '%2s) %s\n' "$((choice+1))" "${methods[choice]}"
    done
    read -r -p "加密方法：输入编号或名称（回车 ${old_method:-2022-blake3-aes-256-gcm}）: " choice || return 1
    choice=${choice:-${old_method:-2022-blake3-aes-256-gcm}}
    if [[ "$choice" =~ ^[0-9]{1,2}$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#methods[@]})); then
        method=${methods[$((10#$choice-1))]}
    else
        for value in "${methods[@]}"; do [[ "$value" == "$choice" ]] && method=$value; done
    fi
    [[ -n "$method" ]] || { ss_error "无效加密方法。"; return 1; }
    read -r -s -p "密码（回车：同方法保留旧密码，否则随机生成）: " custom || return 1
    printf '\n'
    if [[ -n "$custom" ]]; then ss_password=$custom
    elif [[ "$method" == "$old_method" && -n "$old_password" ]]; then ss_password=$old_password
    else
        case "$method" in
            2022-blake3-aes-128-gcm) ss_password=$(openssl rand -base64 16) || return 1 ;;
            *) ss_password=$(openssl rand -base64 32) || return 1 ;;
        esac
    fi
    case "$method" in
        2022-*)
            local expected=32 bytes
            [[ "$method" == 2022-blake3-aes-128-gcm ]] && expected=16
            bytes=$(printf '%s' "$ss_password" | openssl base64 -d -A | wc -c | tr -d ' ')
            [[ "$bytes" == "$expected" ]] &&
                [[ "$(printf '%s' "$ss_password" | openssl base64 -d -A | openssl base64 -A)" == "$ss_password" ]] || {
                ss_error "$method 需要 Base64 编码的 $expected 字节密钥。"; return 1;
            } ;;
    esac
    value=""
    [[ -f "$SS_STATE_DIR/node_name" ]] && IFS= read -r value < "$SS_STATE_DIR/node_name"
    if [[ -z "$value" && -f "$SS_STATE_DIR/info.txt" ]]; then
        value=$(sed -n 's/^节点名称: //p' "$SS_STATE_DIR/info.txt" | head -n 1)
    fi
    read -r -p "节点名称（回车 ${value:-Shadowsocks-$method}）: " node_name || return 1
    node_name=${node_name:-${value:-Shadowsocks-$method}}
    # fast_open 关闭可减少对旧内核功能的依赖。
    jq -n --argjson port "$ss_port" --arg password "$ss_password" --arg method "$method" \
        '{server:"0.0.0.0",server_port:$port,mode:"tcp_and_udp",fast_open:false,password:$password,method:$method}' >&3
}

ss_write_config() {
    local source=$1 temp
    mkdir -p "$(dirname "$SS_CONFIG_PATH")" || return 1
    temp=$(mktemp "${SS_CONFIG_PATH}.XXXXXX") || return 1
    if install -m 600 "$source" "$temp" && mv -f "$temp" "$SS_CONFIG_PATH"; then return 0; fi
    rm -f "$temp"
    return 1
}

get_public_ip() {
    public_ip=""
    local endpoint
    for endpoint in https://api.ipify.org https://api.ip.sb/ip https://icanhazip.com; do
        public_ip=$(curl -fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null) || public_ip=""
        # 只接受地址字符，阻止 HTML/错误页成为分享链接主机名。
        [[ "$public_ip" =~ ^[0-9.]+$ || "$public_ip" =~ ^[0-9a-fA-F:]+$ ]] && break
        public_ip=""
    done
    if [[ -z "$public_ip" ]]; then
        public_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        printf '未取得公网 IP，请把链接地址替换为服务器公网 IP。\n' >&2
    fi
    public_ip=${public_ip:-YOUR_SERVER_IP}
}

ss_save_info() {
    local host userinfo fragment
    get_public_ip
    host=$public_ip
    [[ "$host" == *:* ]] && host="[$host]"
    fragment=$(jq -rn --arg name "$node_name" '$name|@uri') || return 1
    case "$method" in
        2022-*)
            userinfo="$(jq -rn --arg s "$method" '$s|@uri'):$(jq -rn --arg s "$ss_password" '$s|@uri')" ;;
        *) userinfo=$(printf '%s' "$method:$ss_password" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=') ;;
    esac
    final_url="ss://${userinfo}@${host}:${ss_port}#${fragment}"
    printf '%s\n' "$node_name" > "$SS_STATE_DIR/node_name" || return 1
    {
        printf '后端: %s\n端口: %s\n密码: %s\n加密方法: %s\n节点名称: %s\n链接: %s\n' \
            "$SS_BACKEND" "$ss_port" "$ss_password" "$method" "$node_name" "$final_url"
    } > "$SS_STATE_DIR/info.txt" || return 1
    printf '%s\n' "$final_url" > "$SS_STATE_DIR/latest_link.txt" || return 1
    chmod 600 "$SS_STATE_DIR/"{info.txt,node_name,latest_link.txt} || return 1
    printf '节点链接：%s\n' "$final_url"
}

ss_backup() {
    local file
    SS_BACKUP=$(mktemp -d "$SS_STATE_DIR/backups/$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
    for file in "$SS_BINARY_CONFIG" "$SS_SNAP_CONFIG" "$SS_UNIT" /usr/local/bin/ssserver "$SS_BACKEND_FILE"; do
        if [[ -e "$file" ]]; then
            mkdir -p "$SS_BACKUP$(dirname "$file")" &&
                cp -p "$file" "$SS_BACKUP$file" || return 1
        fi
    done
    systemctl is-active --quiet shadowsocks.service && touch "$SS_BACKUP/binary.active"
    systemctl is-active --quiet "snap.${SS_SNAP_APP}.service" && touch "$SS_BACKUP/snap.active"
    systemctl is-enabled --quiet shadowsocks.service && touch "$SS_BACKUP/binary.enabled"
    systemctl is-enabled --quiet "snap.${SS_SNAP_APP}.service" && touch "$SS_BACKUP/snap.enabled"
    return 0
}

ss_restore_files() {
    local file failed=0
    for file in "$SS_BINARY_CONFIG" "$SS_SNAP_CONFIG" "$SS_UNIT" /usr/local/bin/ssserver "$SS_BACKEND_FILE"; do
        if [[ -e "$SS_BACKUP$file" ]]; then
            mkdir -p "$(dirname "$file")" && cp -p "$SS_BACKUP$file" "$file" || failed=1
        elif [[ -e "$file" ]]; then
            rm -f "$file" || failed=1
        fi
    done
    systemctl daemon-reload || failed=1
    return "$failed"
}

ss_rollback() {
    local failed=0
    ss_restore_files || failed=1
    if [[ -f "$SS_BACKUP/binary.enabled" ]]; then systemctl enable shadowsocks.service || failed=1; fi
    if [[ -f "$SS_BACKUP/snap.enabled" ]]; then snap start --enable "$SS_SNAP_APP" || failed=1; fi
    if [[ -f "$SS_BACKUP/binary.active" ]]; then systemctl start shadowsocks.service || failed=1; fi
    if [[ -f "$SS_BACKUP/snap.active" ]]; then snap start "$SS_SNAP_APP" || failed=1
    elif [[ -f "$SS_BACKUP/snap.enabled" ]]; then snap stop "$SS_SNAP_APP" || failed=1; fi
    if ((failed)); then ss_error "自动恢复未完全成功，请检查服务及备份：$SS_BACKUP"; return 1; fi
    printf '已恢复原配置和原服务状态；备份：%s\n' "$SS_BACKUP" >&2
}

install_shadowsocks() (
    check_root
    check_system && check_tool || return 1
    mkdir -p "$SS_STATE_DIR/backups" || return 1
    chmod 700 "$SS_STATE_DIR" "$SS_STATE_DIR/backups" || return 1
    exec 9>"$SS_STATE_DIR/.lock"
    flock -n 9 || { ss_error "另一个管理操作正在执行。"; return 1; }
    local previous="" temp requested choice candidate
    if ss_detect_backend; then previous=$SS_BACKEND; else SS_CONFIG_PATH=$SS_BINARY_CONFIG; fi
    requested=$SS_REQUESTED_BACKEND
    if [[ "$requested" == auto && -t 0 ]]; then
        read -r -p "安装方式 auto / binary / snap（回车 auto；已安装时沿用原后端）: " choice || return 1
        requested=${choice:-auto}
    fi
    case "$requested" in auto|binary|snap) ;; *) ss_error "无效后端：$requested"; return 1 ;; esac
    # 在子 shell 内部使用 EXIT 清理，不改变主菜单的 trap。
    temp=$(mktemp -d) || return 1
    trap 'rm -rf "$temp"' EXIT
    # JSON 单独写入 fd 3，菜单和提示仍显示在终端。
    ss_choose_config 3>"$temp/config.json" || return 1
    ss_backup || return 1
    trap 'ss_service disable >/dev/null 2>&1 || :; ss_rollback; exit 130' INT
    trap 'ss_service disable >/dev/null 2>&1 || :; ss_rollback; exit 143' TERM
    local candidates=()
    case "$requested" in
        auto)
            if [[ "$previous" == snap ]]; then candidates=(snap)
            else candidates=(binary snap); fi ;;
        *) candidates=("$requested") ;;
    esac
    # 切换前停用两个后端，避免端口冲突；失败后恢复原配置与状态。
    if [[ -f "$SS_UNIT" ]]; then
        systemctl disable --now shadowsocks.service || { ss_rollback; return 1; }
    fi
    if ss_snap_installed; then
        snap stop --disable "$SS_SNAP_APP" || { ss_rollback; return 1; }
    fi
    for candidate in "${candidates[@]}"; do
        SS_BACKEND=$candidate
        ss_set_config_path
        printf '尝试安装后端：%s\n' "$candidate"
        if "ss_install_$candidate" "$temp" &&
            ss_write_config "$temp/config.json" &&
            ss_service enable &&
            ss_service restart &&
            ss_wait_ready "$ss_port"; then
            printf '%s\n' "$SS_BACKEND" > "$SS_BACKEND_FILE" || { ss_service disable; ss_rollback; return 1; }
            trap - INT TERM
            ss_save_info || { ss_error "服务已运行，但节点信息保存失败。"; return 1; }
            printf '安装成功：%s；配置：%s；备份：%s\n' "$SS_BACKEND" "$SS_CONFIG_PATH" "$SS_BACKUP"
            printf '请确保主机防火墙及云安全组允许 %s/TCP 和 %s/UDP。\n' "$ss_port" "$ss_port"
            return 0
        fi
        printf '后端 %s 未成功启动。\n' "$candidate" >&2
        local stopped=0
        if { [[ "$candidate" == binary && -f "$SS_UNIT" ]]; } ||
           { [[ "$candidate" == snap ]] && ss_snap_installed; }; then
            ss_service disable || stopped=1
        fi
        if ((stopped)); then
            ss_error "无法停止失败后端，为避免端口冲突，终止自动切换。"
            ss_rollback
            return 1
        fi
        ss_restore_files || { ss_error "恢复文件失败；备份：$SS_BACKUP"; return 1; }
    done
    ss_rollback
    ss_error "所有候选后端均失败，未生成成功节点。"
    return 1
)

check_shadowsocks_status() {
    ss_detect_backend || { ss_error "未检测到安装。"; return 1; }
    printf '后端：%s\n配置：%s\n' "$SS_BACKEND" "$SS_CONFIG_PATH"
    if [[ "$SS_BACKEND" == snap ]]; then
        snap list shadowsocks-rust
        snap services "$SS_SNAP_APP"
    else
        /usr/local/bin/ssserver --version
        systemctl --no-pager -l status shadowsocks.service
    fi
}

check_shadowsocks_config() {
    ss_detect_backend || return 1
    printf '配置文件：%s\n' "$SS_CONFIG_PATH"
    [[ -f "$SS_CONFIG_PATH" ]] && cat "$SS_CONFIG_PATH"
    [[ -f "$SS_STATE_DIR/info.txt" ]] && cat "$SS_STATE_DIR/info.txt"
}

modify_shadowsocks_config() (
    check_system && check_tool && ss_detect_backend || return 1
    exec 9>"$SS_STATE_DIR/.lock"
    flock -n 9 || { ss_error "另一个管理操作正在执行。"; return 1; }
    local temp
    temp=$(mktemp -d) || return 1
    trap 'rm -rf "$temp"' EXIT
    [[ -f "$SS_CONFIG_PATH" ]] || { ss_error "配置文件不存在。"; return 1; }
    ss_choose_config 3>"$temp/config.json" || return 1
    cp -p "$SS_CONFIG_PATH" "$temp/old.json" || return 1
    if ss_write_config "$temp/config.json" && ss_service restart && ss_wait_ready "$ss_port"; then
        ss_save_info
    else
        ss_write_config "$temp/old.json" && ss_service restart || ss_error "恢复失败。"
        ss_error "新配置启动失败，已尝试恢复旧配置。"
        return 1
    fi
)

start_shadowsocks() { ss_detect_backend && ss_service start; }
stop_shadowsocks() { ss_detect_backend && ss_service stop; }
restart_shadowsocks() { ss_detect_backend && ss_service restart; }

uninstall_shadowsocks() (
    ss_detect_backend || { ss_error "未检测到安装。"; return 1; }
    local confirm
    read -r -p "卸载 $SS_BACKEND 后端？备份和节点信息将保留 (y/N): " confirm || return 1
    [[ "$confirm" == y || "$confirm" == Y ]] || return 1
    exec 9>"$SS_STATE_DIR/.lock"
    flock -n 9 || return 1
    ss_service disable || return 1
    if [[ "$SS_BACKEND" == snap ]]; then
        # 不使用 --purge，保留 Snap 自动快照。
        snap remove shadowsocks-rust || return 1
    else
        rm -f "$SS_UNIT" /usr/local/bin/ssserver "$SS_BINARY_CONFIG" || return 1
        systemctl daemon-reload || return 1
    fi
    rm -f "$SS_BACKEND_FILE"
    printf '已卸载选定后端，/etc/shadowsocks 中的信息和备份已保留。\n'
)

ss_links() {
    ss_detect_backend || return 1
    [[ -f "$SS_CONFIG_PATH" ]] || return 1
    ss_port=$(jq -er '.server_port' "$SS_CONFIG_PATH") || return 1
    method=$(jq -er '.method' "$SS_CONFIG_PATH") || return 1
    ss_password=$(jq -er '.password' "$SS_CONFIG_PATH") || return 1
    node_name="Shadowsocks-$method"
    [[ -f "$SS_STATE_DIR/node_name" ]] && IFS= read -r node_name < "$SS_STATE_DIR/node_name"
    ss_save_info
    if systemctl is-active --quiet shadow-tls; then
        printf 'ShadowTLS 已运行；以上为 SS 直连链接，ShadowTLS 客户端参数见 /etc/shadowtls/info.txt。\n'
    fi
}

# ===== ShadowTLS 功能 =====

# 安装ShadowTLS服务
install_shadowtls() {
    check_system && check_tool || return 1
    ss_detect_backend || { ss_error "请先安装 Shadowsocks。"; return 1; }
    echo -e "${BLUE}开始安装 ShadowTLS 服务...${PLAIN}"

    # 检查是否已安装
    if [ -f "/usr/bin/shadow-tls" ] || systemctl is-active shadow-tls &>/dev/null; then
        echo -e "${YELLOW}ShadowTLS 已安装，如需重新安装请先卸载${PLAIN}"
        return 1
    fi

    # 获取系统架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)   ARCH_SUFFIX="x86_64-unknown-linux-musl" ;;
        aarch64)  ARCH_SUFFIX="aarch64-unknown-linux-musl" ;;
        armv7l)   ARCH_SUFFIX="armv7-unknown-linux-musleabihf" ;;
        *)        echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return 1 ;;
    esac

    # 获取最新版本
    LATEST_VERSION=$(wget -qO- https://api.github.com/repos/ihciah/shadow-tls/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}获取 ShadowTLS 版本失败${PLAIN}"
        return 1
    fi

    # 下载二进制文件
    echo -e "${YELLOW}正在下载 ShadowTLS ${LATEST_VERSION}...${PLAIN}"
    wget -q "https://github.com/ihciah/shadow-tls/releases/download/${LATEST_VERSION}/shadow-tls-${ARCH_SUFFIX}" -O /usr/bin/shadow-tls
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络${PLAIN}"
        return 1
    fi
    chmod +x /usr/bin/shadow-tls

    # 获取 Shadowsocks 端口（如果已安装）
    local ss_port="9000"
    if [ -f "$SS_CONFIG_PATH" ]; then
        ss_port=$(grep '"server_port":' "$SS_CONFIG_PATH" | awk '{print $2}' | tr -d ',')
        echo -e "${GREEN}检测到 Shadowsocks 端口: $ss_port${PLAIN}"
    else
        read -p "请输入Shadowsocks服务端口（默认9000）: " ss_port
        ss_port=${ss_port:-9000}
    fi

    # 生成随机密码
    local stls_password=$(openssl rand -base64 16 | tr -d '=+/')

    # 交互式配置
    read -p "输入ShadowTLS监听端口（默认9527）: " listen_port
    local listen_port=${listen_port:-9527}

    read -p "输入TLS混淆域名（默认www.bing.com）: " tls_domain
    local tls_domain=${tls_domain:-www.bing.com}

    ss_validate_shadowtls || return 1
    # 创建服务文件
    cat > /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Server Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/shadow-tls --v3 server --listen 0.0.0.0:${listen_port} --password ${stls_password} --server 127.0.0.1:${ss_port} --tls ${tls_domain}:443
Environment=MONOIO_FORCE_LEGACY_DRIVER=1

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable shadow-tls --now && sleep 2 && systemctl is-active --quiet shadow-tls

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}ShadowTLS 启动成功！${PLAIN}"

        # 保存配置信息
        mkdir -p /etc/shadowtls
        cat <<EOF >/etc/shadowtls/info.txt
监听端口: $listen_port
密码: $stls_password
目标服务: 127.0.0.1:$ss_port
TLS域名: $tls_domain
EOF
        echo -e "${GREEN}配置信息已保存至 /etc/shadowtls/info.txt${PLAIN}"

        printf 'ShadowTLS 参数：地址=服务器公网IP，端口=%s，版本=3，密码=%s，TLS域名=%s\n' \
            "$listen_port" "$stls_password" "$tls_domain"
        printf '客户端须分别配置 ShadowTLS 和其后的 Shadowsocks；直接 SS 链接可由主菜单生成。\n'
        chmod 700 /etc/shadowtls
        chmod 600 /etc/shadowtls/info.txt
    else
        echo -e "${RED}ShadowTLS 启动失败！${PLAIN}"
        return 1
    fi
}

# 查看ShadowTLS服务状态
check_shadowtls_status() {
    if [ ! -f "/usr/bin/shadow-tls" ]; then
        echo -e "${RED}ShadowTLS 未安装${PLAIN}"
        return 1
    fi

    echo -e "${BLUE}ShadowTLS 版本: ${PLAIN}$(/usr/bin/shadow-tls --version | awk '{print $2}')"
    echo -e "${BLUE}服务状态: ${PLAIN}$(systemctl is-active shadow-tls)"
}

# 查看ShadowTLS配置文件
check_shadowtls_config() {
    if [ -f "/etc/shadowtls/info.txt" ]; then
        echo -e "${BLUE}配置信息: ${PLAIN}"
        cat /etc/shadowtls/info.txt
    else
        echo -e "${BLUE}未检测到配置信息 ${PLAIN}"
	fi
}

# 修改ShadowTLS配置
modify_shadowtls_config() {
    check_system && check_tool || return 1
    ss_detect_backend || return 1
    if [ ! -f "/usr/bin/shadow-tls" ]; then
        echo -e "${RED}ShadowTLS 未安装${PLAIN}"
        return 1
    fi
    
    # 获取当前配置
    echo -e "${YELLOW}当前配置信息："
    cat /etc/shadowtls/info.txt
    echo -e "${PLAIN}"
    
    # 从服务文件中正确提取当前值
    service_content=$(cat /etc/systemd/system/shadow-tls.service)
    current_listen_port=$(echo "$service_content" | grep -oP 'listen 0.0.0.0:\K[0-9]+')
    current_stls_password=$(echo "$service_content" | grep -oP 'password \K[^ ]+')
    current_ss_port=$(echo "$service_content" | grep -oP 'server 127.0.0.1:\K[0-9]+')
    current_tls_domain=$(echo "$service_content" | grep -oP 'tls \K[^:]+(?=:443)')
    
    # 如果无法从服务文件读取，尝试从info.txt读取
    if [ -z "$current_listen_port" ] || [ -z "$current_stls_password" ] || [ -z "$current_ss_port" ] || [ -z "$current_tls_domain" ]; then
        if [ -f "/etc/shadowtls/info.txt" ]; then
            info_content=$(cat /etc/shadowtls/info.txt)
            [ -z "$current_listen_port" ] && current_listen_port=$(echo "$info_content" | grep -oP '监听端口: \K.+')
            [ -z "$current_stls_password" ] && current_stls_password=$(echo "$info_content" | grep -oP '密码: \K.+')
            [ -z "$current_ss_port" ] && current_ss_port=$(echo "$info_content" | grep -oP '目标服务端口: \K.+')
            [ -z "$current_tls_domain" ] && current_tls_domain=$(echo "$info_content" | grep -oP 'TLS域名: \K.+')
        fi
    fi
    
    # 依次询问是否修改各项
    echo -e "是否修改监听端口? 当前值: ${current_listen_port} (留空则不修改)"
    read -p "新监听端口: " new_listen_port
    listen_port=${new_listen_port:-$current_listen_port}
    
    echo -e "是否修改密码? 当前值: ${current_stls_password} (留空则不修改，输入 'random' 则随机生成)"
    read -p "新密码: " new_stls_password
    if [ "$new_stls_password" = "random" ]; then
        stls_password=$(openssl rand -base64 16 | tr -d '=+/')
    elif [ -n "$new_stls_password" ]; then
        stls_password=$new_stls_password
    else
        stls_password=$current_stls_password
    fi
    
    echo -e "是否修改目标服务端口? 当前值: ${current_ss_port} (留空则不修改)"
    read -p "新目标服务端口: " new_ss_port
    ss_port=${new_ss_port:-$current_ss_port}
    
    echo -e "是否修改TLS域名? 当前值: ${current_tls_domain} (留空则不修改)"
    read -p "新TLS域名: " new_tls_domain
    tls_domain=${new_tls_domain:-$current_tls_domain}
    
    ss_validate_shadowtls || return 1
    # 更新服务文件
    cat > /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Server Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/shadow-tls --v3 server --listen 0.0.0.0:${listen_port} --password ${stls_password} --server 127.0.0.1:${ss_port} --tls ${tls_domain}:443
Environment=MONOIO_FORCE_LEGACY_DRIVER=1

[Install]
WantedBy=multi-user.target
EOF

    # 更新配置信息文件
    cat > /etc/shadowtls/info.txt <<EOF
监听端口: ${listen_port}
密码: ${stls_password}
目标服务端口: ${ss_port}
TLS域名: ${tls_domain}
EOF

    systemctl daemon-reload
    systemctl restart shadow-tls && sleep 2 && systemctl is-active --quiet shadow-tls || return 1
    
    echo -e "${GREEN}ShadowTLS 配置已更新并重启服务${PLAIN}"
}

# ShadowTLS服务控制
shadowtls_control() {
    local action=$1
    case $action in
        start)
            systemctl start shadow-tls
            [ $? -eq 0 ] && echo -e "${GREEN}ShadowTLS 已启动${PLAIN}" || echo -e "${RED}启动失败${PLAIN}" ;;
        stop)
            systemctl stop shadow-tls
            [ $? -eq 0 ] && echo -e "${GREEN}ShadowTLS 已停止${PLAIN}" || echo -e "${RED}停止失败${PLAIN}" ;;
        restart)
            systemctl restart shadow-tls
            [ $? -eq 0 ] && echo -e "${GREEN}ShadowTLS 已重启${PLAIN}" || echo -e "${RED}重启失败${PLAIN}" ;;
    esac
}

# 卸载ShadowTLS
uninstall_shadowtls() {
    check_system && check_tool || return 1
    ss_detect_backend || { ss_error "请先安装 Shadowsocks。"; return 1; }
    echo -e "${YELLOW}此操作将完全卸载 ShadowTLS${PLAIN}"
    read -p "确认卸载？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    systemctl stop shadow-tls
    systemctl disable shadow-tls
    rm -f /usr/bin/shadow-tls
    rm -f /etc/systemd/system/shadow-tls.service
    systemctl daemon-reload
    rm -rf /etc/shadowtls
    echo -e "${GREEN}ShadowTLS 已卸载${PLAIN}"
}



ss_validate_shadowtls() {
    local value
    for value in "$listen_port" "$ss_port"; do
        [[ "$value" =~ ^[0-9]{1,5}$ ]] && ((10#$value >= 1 && 10#$value <= 65535)) || {
            ss_error "ShadowTLS 端口无效。"; return 1;
        }
    done
    ((10#$listen_port != 10#$ss_port)) || {
        ss_error "ShadowTLS 监听端口不能与 SS 目标端口相同。"; return 1;
    }
    [[ "$tls_domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] &&
        [[ "$stls_password" =~ ^[a-zA-Z0-9._~+=/@:-]+$ ]] || {
        ss_error "TLS 域名或密码包含服务文件不支持的字符；密码请使用字母、数字及 ._~+=/@:-。"; return 1;
    }
}

install_all() {
    install_shadowsocks && install_shadowtls
}

uninstall_all() {
    uninstall_shadowsocks || return 1
    uninstall_shadowtls
}

usage() {
    cat <<'HELP'
用法：
  sudo bash Shadowsocks-Auto.sh                  交互菜单
  sudo bash Shadowsocks-Auto.sh install [auto|binary|snap]
  sudo bash Shadowsocks-Auto.sh status
  sudo bash Shadowsocks-Auto.sh config
  sudo bash Shadowsocks-Auto.sh modify
  sudo bash Shadowsocks-Auto.sh start|stop|restart|link|uninstall

auto：优先 musl 二进制，失败后尝试 Snap；已安装 Snap 则沿用 Snap。
snap：Debian/Ubuntu 上通过 snapd 安装，配置写入 Snap 的 common 目录。
SS_BACKEND_MODE=snap 也可指定菜单默认安装方式。
安装或修改时输入端口、加密方法、密码和节点名称；密码留空会随机生成。
HELP
}

main() {
    case "${1:-menu}" in help|-h|--help) usage; return ;; esac
    check_root
    check_system || return 1
    umask 077
    ss_detect_backend || :
    case "${1:-menu}" in
        menu) main_menu ;;
        install) SS_REQUESTED_BACKEND=${2:-$SS_REQUESTED_BACKEND}; install_shadowsocks ;;
        status) check_shadowsocks_status ;;
        config) check_shadowsocks_config ;;
        modify) modify_shadowsocks_config ;;
        start) start_shadowsocks ;;
        stop) stop_shadowsocks ;;
        restart) restart_shadowsocks ;;
        link) check_tool && ss_links ;;
        uninstall) uninstall_shadowsocks ;;
        *) usage; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -o pipefail
    main "$@"
fi

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}================================${PLAIN}"
        echo -e "          Shadowsocks/ShadowTLS 管理脚本"
        echo -e "${BLUE}================================${PLAIN}"
        echo -e "  1) Shadowsocks 服务管理"
        echo -e "  2) ShadowTLS 服务管理"
        echo -e "  3) 一键安装 Shadowsocks+ShadowTLS"
        echo -e "  4) 输出当前节点链接"
        echo -e "  9) 卸载组件（保留本脚本及 SS 备份）"
        echo -e "  0) 退出脚本"
        echo -e "${BLUE}================================${PLAIN}"
        
        read -r -p "请输入选项: " main_choice || return
        case $main_choice in
            1) ss_submenu ;;
            2) stls_submenu ;;
            3) install_all ;;
            4) ss_links ;;
            9) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
    done
}

# Shadowsocks子菜单
ss_submenu() {
    while true; do
        clear
        echo -e "${BLUE}=== Shadowsocks 服务管理 ===${PLAIN}"
        echo -e "  1) 安装Shadowsocks服务"
        echo -e "  2) 查看Shadowsocks服务状态"
        echo -e "  3) 查看Shadowsocks配置文件"
        echo -e "  4) 修改Shadowsocks配置文件"
        echo -e "  5) 启动Shadowsocks服务"
        echo -e "  6) 停止Shadowsocks服务"
        echo -e "  7) 重启Shadowsocks服务"
        echo -e "  9) 卸载Shadowsocks服务"
        echo -e "  0) 返回主菜单"
        
        read -r -p "请输入选项: " choice || return
        case $choice in
            1) install_shadowsocks ;;
            2) check_shadowsocks_status ;;
            3) check_shadowsocks_config ;;
            4) modify_shadowsocks_config ;;
            5) start_shadowsocks ;;
            6) stop_shadowsocks ;;
            7) restart_shadowsocks ;;
            9) uninstall_shadowsocks ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        if [[ "$choice" != "0" ]]; then
            read -n 1 -s -r -p "按任意键继续..."
        fi
    done
}

# ShadowTLS子菜单
stls_submenu() {
    while true; do
        clear
        echo -e "${BLUE}=== ShadowTLS 服务管理 ===${PLAIN}"
        echo -e "  1) 安装ShadowTLS服务"
        echo -e "  2) 查看ShadowTLS服务状态"
        echo -e "  3) 查看ShadowTLS配置文件"
        echo -e "  4) 修改ShadowTLS配置文件"
        echo -e "  5) 启动ShadowTLS服务"
        echo -e "  6) 停止ShadowTLS服务"
        echo -e "  7) 重启ShadowTLS服务"
        echo -e "  9) 卸载ShadowTLS服务"
        echo -e "  0) 返回主菜单"
        
        read -r -p "请输入选项: " choice || return
        case $choice in
            1) install_shadowtls ;;
            2) check_shadowtls_status ;;
            3) check_shadowtls_config ;;
            4) modify_shadowtls_config ;;
            5) shadowtls_control start ;;
            6) shadowtls_control stop ;;
            7) shadowtls_control restart ;;
            9) uninstall_shadowtls ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        if [[ "$choice" != "0" ]]; then
            read -n 1 -s -r -p "按任意键继续..."
        fi
    done
}
