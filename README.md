# Shadowsocks-Auto

Shadowsocks Rust / ShadowTLS 自动安装与管理脚本，支持独立二进制和 Snap 两种 Shadowsocks 安装方式。

提供交互式菜单和命令行入口，可安装、查看状态、修改配置、启停服务、输出节点链接及卸载组件。

## 系统要求

- Linux，使用 root 或 sudo 执行。
- 系统必须运行 systemd。
- 独立二进制安装支持使用 apt-get、dnf 或 yum 的发行版，具体架构以可下载的上游发布资产为准。
- Snap 自动安装适用于使用 apt-get 的 Debian/Ubuntu，且系统能够运行 snapd。
- 服务器需能访问发行版软件源、GitHub；使用 Snap 时还需能访问 Snap Store。

## 快速开始

下载脚本并进入菜单：

```bash
curl -fL --retry 2 \
  https://raw.githubusercontent.com/yuju520/Shadowsocks-Auto/main/Shadowsocks-Auto.sh \
  -o Shadowsocks-Auto.sh

sudo bash Shadowsocks-Auto.sh
```

也可以使用 wget 下载：

```bash
wget -O Shadowsocks-Auto.sh \
  https://raw.githubusercontent.com/yuju520/Shadowsocks-Auto/main/Shadowsocks-Auto.sh

sudo bash Shadowsocks-Auto.sh
```

## 选择安装方式

```bash
# 自动选择，适合首次安装
sudo bash Shadowsocks-Auto.sh install auto

# 强制使用 Snap，适合已确认 Snap 可运行的服务器
sudo bash Shadowsocks-Auto.sh install snap

# 仅使用独立二进制
sudo bash Shadowsocks-Auto.sh install binary
```

| 模式 | 行为 |
| --- | --- |
| `auto` | 优先安装 musl 独立二进制；安装或启动失败后尝试 Snap。已检测到 Snap 安装时沿用 Snap。 |
| `binary` | 仅尝试当前架构的 musl 独立二进制。 |
| `snap` | 安装和初始化 snapd，安装 shadowsocks-rust，写入配置并启用服务。 |

安装过程需要交互输入端口、加密方法、密码和节点名称。例如，使用端口 `2355` 和 `rc4-md5` 时，输入端口 `2355`，加密方法选择 `17` 或直接输入 `rc4-md5`，再填写自己的密码。

默认加密方法为 `2022-blake3-aes-256-gcm`。新安装时密码留空会随机生成；修改已有配置且加密方法相同时，密码留空会保留原密码。SS2022 的自定义密钥会进行 Base64 和长度校验。

加密方法是否可用取决于安装包编译时包含的特性，脚本会通过实际启动检查结果判断安装是否成功。

### 旧系统兼容性

独立安装优先使用 musl 构建，并在部署前运行版本命令检查二进制是否可执行。默认关闭 `fast_open`，减少对内核功能的依赖。

旧系统故障也可能来自 glibc、架构或运行环境，不能只按内核版本判断。Snap 同样依赖宿主内核、挂载能力和 snapd；本脚本不保证兼容所有旧内核，也不会自动更换内核。

## 日常管理

```bash
sudo bash Shadowsocks-Auto.sh status       # 查看安装后端和服务状态
sudo bash Shadowsocks-Auto.sh config       # 查看配置及节点信息，包含密码
sudo bash Shadowsocks-Auto.sh modify       # 交互修改配置
sudo bash Shadowsocks-Auto.sh start        # 启动服务
sudo bash Shadowsocks-Auto.sh stop         # 停止服务
sudo bash Shadowsocks-Auto.sh restart      # 重启服务
sudo bash Shadowsocks-Auto.sh link         # 生成并保存 SS 直连链接
sudo bash Shadowsocks-Auto.sh uninstall    # 卸载当前选定后端
```

直接运行 `sudo bash Shadowsocks-Auto.sh` 可进入交互菜单。菜单还提供 ShadowTLS 管理和 Shadowsocks + ShadowTLS 一键安装。

## 配置与服务路径

| 项目 | 独立二进制 | Snap |
| --- | --- | --- |
| SS 配置 | `/etc/shadowsocks/config.json` | `/var/snap/shadowsocks-rust/common/etc/shadowsocks-rust/config.json` |
| SS 服务 | `shadowsocks.service` | `shadowsocks-rust.ssserver-daemon` |
| SS 程序 | `/usr/local/bin/ssserver` | 由 Snap 管理 |

共用的管理文件：

| 路径 | 用途 |
| --- | --- |
| `/etc/shadowsocks/backend` | 记录选定的安装后端 |
| `/etc/shadowsocks/info.txt` | 节点信息，包含密码和链接 |
| `/etc/shadowsocks/latest_link.txt` | 最近生成的 SS 直连链接 |
| `/etc/shadowsocks/backups/` | 安装或切换前的文件备份 |
| `/etc/shadowtls/info.txt` | ShadowTLS 参数 |

配置使用 jq 生成，支持密码中的引号和反斜杠；节点名称进行 URI 编码，IPv6 分享地址使用方括号。SS 配置和节点信息设为 root 可读写。

## 启动检查与恢复

- 安装前备份已有 SS 配置、独立二进制、systemd 服务文件和后端记录，并记录服务状态。
- 切换前停用已有后端，避免两个服务争用端口。
- 验证服务存活和端口的 TCP、UDP 监听后，才报告安装成功并输出节点链接。
- 安装失败时尝试恢复原配置及服务状态；修改配置后启动失败时尝试恢复旧配置。
- Ctrl+C 或 TERM 会触发安装恢复尝试；断电或 SIGKILL 无法触发自动恢复。恢复失败时按终端提示检查备份和服务。

卸载会保留 SS 节点信息和备份。Snap 卸载不使用 `--purge`；迁移后遗留的其他后端程序不会自动清理。“卸载组件”菜单保留本脚本。

## ShadowTLS

支持 ShadowTLS v3 安装与管理，并从当前 Shadowsocks 后端读取目标端口。Shadowsocks 安装成功后才会继续一键安装流程。

脚本分别提供标准 SS 直连链接和 ShadowTLS 参数。使用 ShadowTLS 时，请在支持它的客户端配置 ShadowTLS 的地址、监听端口、版本、密码及 TLS 域名，再配置后端 SS 的加密方法和密码。

修改 SS 监听端口后，还需在 ShadowTLS 菜单中同步修改目标端口。SS 的 UDP 监听检查不表示 UDP 已经过 ShadowTLS。

## 排查问题

独立二进制服务日志：

```bash
sudo journalctl -u shadowsocks.service -n 50 --no-pager
```

Snap 服务和 snapd 日志：

```bash
sudo snap services shadowsocks-rust.ssserver-daemon
sudo snap logs -n=50 shadowsocks-rust.ssserver-daemon
sudo journalctl -u snapd -n 50 --no-pager
```

检查监听端口，例如 `2355`：

```bash
sudo ss -lntup 'sport = :2355'
```

请在云安全组和主机防火墙中放行实际使用端口的 TCP/UDP，并使用外部客户端验证。脚本不自动修改防火墙或内核参数。

## 项目参考

- [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)
- [ShadowTLS](https://github.com/ihciah/shadow-tls)
