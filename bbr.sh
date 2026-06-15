#!/bin/bash
# ==============================================================================
#          TCP & UDP/QUIC & Emby流媒体 全场景全兼容调优 V3.9.3
#                                                              2026.6.15
# ==============================================================================

set -euo pipefail

function print_red   { echo -e "\e[1;31m$1\e[0m"; }
function print_green { echo -e "\e[1;32m$1\e[0m"; }
function print_info  { echo -e "\e[1;36m$1\e[0m"; }
function print_warn  { echo -e "\e[1;33m$1\e[0m"; }
function print_line  { echo -e "\e[1;90m──────────────────────────────────────────\e[0m"; }

# ==============================================================================
# 权限检查
# ==============================================================================
if [ "$(id -u)" != "0" ]; then
    print_red "[!] 请使用 sudo 或 root 身份运行本脚本！"
    exit 1
fi

# ==============================================================================
# LXC 容器检测
# ==============================================================================
if [ -f /proc/1/environ ] && grep -a -q "container=lxc" /proc/1/environ 2>/dev/null; then
    print_warn "[!] 检测到 LXC 容器环境"
    print_info "    LXC 共享宿主机内核，请在 PVE 宿主机上执行本脚本，容器将自动继承。"
    print_info "    当前已安全退出。"
    exit 0
fi

# ==============================================================================
# 工具函数：读取整数输入并校验范围
# ==============================================================================
READ_RESULT=0
function read_int() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local val
    while true; do
        read -rp "$prompt" val
        val="${val// /}"
        if ! [[ "$val" =~ ^[0-9]+$ ]]; then
            print_red "    [!] 请输入纯数字，范围 ${min} ~ ${max}"
            continue
        fi
        if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ]; then
            print_red "    [!] 超出范围，请输入 ${min} ~ ${max} 之间的整数"
            continue
        fi
        READ_RESULT=$val
        return 0
    done
}

# ==============================================================================
# 交互式参数收集
# ==============================================================================
echo ""
print_info "  ┌─────────────────────────────────────────────────────┐"
print_info "  │             TCP/UDP/Emby 调优                       │"
print_info "  └─────────────────────────────────────────────────────┘"
echo ""

print_line

# --- 平均延迟 ---
echo ""
print_info "  [1/3] 平均网络延迟 (RTT)"
echo "        通常可在本机 ping 目标客户端获得。中转机互联可能极低（如 1ms）"
read_int "        请输入延迟 (ms) [1 ~ 500]: " 1 500
RTT_MS=$READ_RESULT
echo ""

print_line

# --- 内存 ---
echo ""
print_info "  [2/3] 服务器物理内存"
echo "        请输入总内存大小，单位 MB。例: 1024 = 1GB，2048 = 2GB"

AUTO_MEM=$(free -m | awk '/^Mem:/{print $2}')
echo "        (当前系统检测到: ${AUTO_MEM} MB，可直接回车使用探测值)"
read -rp "        请输入内存大小 (MB) [256 ~ 4096，直接回车使用 ${AUTO_MEM}MB]: " MEM_INPUT
MEM_INPUT="${MEM_INPUT// /}"
if [ -z "$MEM_INPUT" ]; then
    TOTAL_MEM=$AUTO_MEM
    [ "$TOTAL_MEM" -lt 256  ] && TOTAL_MEM=256
    [ "$TOTAL_MEM" -gt 4096 ] && TOTAL_MEM=4096
    print_info "        → 使用系统探测值: ${TOTAL_MEM} MB"
else
    if ! [[ "$MEM_INPUT" =~ ^[0-9]+$ ]] || [ "$MEM_INPUT" -lt 256 ] || [ "$MEM_INPUT" -gt 4096 ]; then
        print_red "    [!] 超出范围，内存请输入 256 ~ 4096 之间的整数"
        exit 1
    fi
    TOTAL_MEM=$MEM_INPUT
fi
echo ""

print_line

# --- 带宽 ---
echo ""
print_info "  [3/3] 服务器网卡带宽 (上行)"
echo "        请输入套餐标称带宽，单位 Mbps。例: 40 = 40Mbps, 2000 = 2Gbps"
read_int "        请输入带宽 (Mbps) [20 ~ 5000]: " 20 5000
BW_MBPS=$READ_RESULT
echo ""

print_line

# ==============================================================================
# 参数展示确认
# ==============================================================================
echo ""
print_info "  ┌─────────────────────────────────────────────────────┐"
print_info "  │                     输入参数确认                    │"
print_info "  ├─────────────────────────────────────────────────────┤"
printf     "  │  平均延迟:         %-6s ms                            │\n" "${RTT_MS}"
printf     "  │  内存大小:         %-6s MB                            │\n" "${TOTAL_MEM}"
printf     "  │  上行带宽:         %-6s Mbps                          │\n" "${BW_MBPS}"
print_info "  └─────────────────────────────────────────────────────┘"
echo ""
read -rp "  确认以上参数并开始调优？[Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_warn "  已取消。\n"
    exit 0
fi
echo ""

# ==============================================================================
# 核心计算逻辑
# ==============================================================================
print_info "[*] 正在计算最优参数..."

# 1. 精准计算 BDP 字节数（采用 1.8 倍黄金缓冲区余量，兼顾流媒体抗丢包与多线程高平滑度）
BDP_BYTES=$(( BW_MBPS * 1000000 / 8 * RTT_MS / 1000 ))
BDP_WITH_RESERVE=$(( BDP_BYTES * 18 / 10 ))

# 2. 计算内存安全上限（限制单条连接发送端最大不能超过物理内存的 4%）
MEM_BYTES=$(( TOTAL_MEM * 1024 * 1024 ))
SINGLE_CONN_MEM_LIMIT=$(( MEM_BYTES * 4 / 100 ))

# 3. 动态计算 TCP_MAX（取 BDP 需求和内存单流限制的最小值）
if [ "$BDP_WITH_RESERVE" -le "$SINGLE_CONN_MEM_LIMIT" ]; then
    TCP_MAX=$BDP_WITH_RESERVE
    LIMIT_REASON="BDP 需求 + 80% 余量主导"
else
    TCP_MAX=$SINGLE_CONN_MEM_LIMIT
    LIMIT_REASON="单连接系统内存安全线限制"
fi

# 确保最低不低于 16MB，天花板放宽到 256MB 
[ "$TCP_MAX" -lt 16777216 ] && TCP_MAX=16777216
[ "$TCP_MAX" -gt 268435456 ] && TCP_MAX=268435456

TCP_MAX_MB=$(( TCP_MAX / 1024 / 1024 ))
BDP_CALC_MB=$(( BDP_BYTES / 1024 / 1024 ))
MEM_BUF_MB=$(( SINGLE_CONN_MEM_LIMIT / 1024 / 1024 ))

# 4. 全局 TCP 总内存 pool 计算
PAGE=4096
TM_HIGH=$(( MEM_BYTES * 25 / 100 / PAGE ))
TM_MID=$(( MEM_BYTES * 18 / 100 / PAGE ))
TM_LOW=$(( MEM_BYTES * 12 / 100 / PAGE ))

# 5. 根据内存动态调节并发队列深度与孤儿套接字限制
if [ "$TOTAL_MEM" -le 1024 ]; then
    BACKLOG=16384
    MAX_ORPHANS=16384
else
    BACKLOG=32768
    MAX_ORPHANS=32768
fi

# ==============================================================================
# 打印计算过程
# ==============================================================================
echo ""
print_info "  ┌──────────────────────────────────────────────────────────┐"
print_info "  │                          计算结果                        │"
print_info "  ├──────────────────────────────────────────────────────────┤"
printf     "  │  BDP 理论需求:    %-3s MB  (= %-4s Mbps × %-3s ms / 8)    │\n" "$BDP_CALC_MB" "$BW_MBPS" "$RTT_MS"
printf     "  │  单流内存安全线:  %-3s MB  (物理内存 %-4s MB × 4%%)        │\n" "$MEM_BUF_MB" "$TOTAL_MEM"
printf     "  │  最终缓冲区上限:  %-3s MB  ← %-26s │\n" "$TCP_MAX_MB" "$LIMIT_REASON"
print_info "  └──────────────────────────────────────────────────────────┘"
echo ""

# ==============================================================================
# Swap 保险策略
# ==============================================================================
TOTAL_SWAP=$(free -m | awk '/^Swap:/{print $2}')
SWAP_NEEDED=0
SWAP_SIZE=0

if   [ "$TOTAL_MEM" -lt 512  ]; then SWAP_NEEDED=1; SWAP_SIZE=512
elif [ "$TOTAL_MEM" -lt 1024 ]; then SWAP_NEEDED=1; SWAP_SIZE=512
elif [ "$TOTAL_MEM" -lt 2048 ]; then SWAP_NEEDED=1; SWAP_SIZE=1024
else                                  SWAP_NEEDED=0
fi

if [ "$SWAP_NEEDED" -eq 1 ] && [ "$TOTAL_SWAP" -eq 0 ]; then
    print_info "[*] 内存 ${TOTAL_MEM}MB，正在创建 ${SWAP_SIZE}MB Swap..."
    DISK_FREE_MB=$(df -m / | awk 'NR==2{print $4}')
    if [ "$DISK_FREE_MB" -lt $(( SWAP_SIZE + 200 )) ]; then
        print_warn "[!] 磁盘剩余空间不足 (${DISK_FREE_MB}MB)，跳过 Swap 创建。\n"
    else
        dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE}" status=progress
        chmod 600 /swapfile
        mkswap /swapfile  >/dev/null 2>&1
        swapon /swapfile  >/dev/null 2>&1
        grep -q "/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        sysctl -w vm.swappiness=10 >/dev/null 2>&1
        print_green "[+] Swap ${SWAP_SIZE}MB 挂载成功，swappiness=10\n"
    fi
elif [ "$TOTAL_SWAP" -gt 0 ]; then
    print_green "[+] 已存在 Swap ${TOTAL_SWAP}MB，跳过创建。\n"
else
    print_green "[+] 内存 ${TOTAL_MEM}MB ≥ 2048MB，无需 Swap。\n"
fi

# ==============================================================================
# 备份并清空旧的 sysctl 配置
# ==============================================================================
SYSCTL_MAIN="/etc/sysctl.conf"
SYSCTL_MAIN_BAK="/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
if [ -f "${SYSCTL_MAIN}" ]; then
    cp -a "${SYSCTL_MAIN}" "${SYSCTL_MAIN_BAK}"
    : > "${SYSCTL_MAIN}"
    print_warn "[-] /etc/sysctl.conf 已备份至 ${SYSCTL_MAIN_BAK} 并清空\n"
else
    touch "${SYSCTL_MAIN}"
fi

# ==============================================================================
# 真正写入 sysctl 优化配置
# ==============================================================================
SYSCTL_CONF="/etc/sysctl.d/zz-tcp-bbr.conf"
[ -f "${SYSCTL_CONF}" ] && rm -f "${SYSCTL_CONF}"

print_info "[+] 正在写入 ${SYSCTL_CONF} ...\n"

cat <<EOF > "${SYSCTL_CONF}"
# ==============================================================================
# TCP & UDP 调优配置 —— 自动生成，请勿手动修改
# 生成时间 : $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================

fs.file-max = 1048576
fs.nr_open  = 1048576
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn                = 0

# ── 规避 Emby 客户端 MTU 震荡死锁 ──
net.ipv4.tcp_mtu_probing        = 0

# ── 读写分离优化：服务器作为发送方（吐视频/提供下载），wmem全力冲刺，rmem精简省内存 ──
# 恢复 wmem 第二个值为原生最稳健的 16KB，防止 BBR 对 Emby 小包高频切片流盲目踩刹车
net.core.rmem_max               = $(( TCP_MAX / 2 ))
net.core.wmem_max               = ${TCP_MAX}
net.ipv4.tcp_rmem               = 4096 131072 $(( TCP_MAX / 2 ))
net.ipv4.tcp_wmem               = 4096 16384 ${TCP_MAX}
net.ipv4.tcp_adv_win_scale      = 1
net.ipv4.tcp_mem                = ${TM_LOW} ${TM_MID} ${TM_HIGH}

# ── 队列与并发能力 ──
net.core.somaxconn              = ${BACKLOG}
net.core.netdev_max_backlog     = ${BACKLOG}
net.ipv4.tcp_max_syn_backlog    = ${BACKLOG}

# ── 现代高码率 UDP/QUIC (落地机拉取HTTP3源视频) 优化支持 ──
# 调高 udp_*_min 基准线至 16KB，彻底消除高带宽万兆网卡在代理内核转发时的粘包和假死
net.core.rmem_default           = 1048576
net.core.wmem_default           = 524288
net.ipv4.udp_rmem_min           = 16384
net.ipv4.udp_wmem_min           = 16384

# ── 连接复用与孤儿套接字动态防爆 ──
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_max_orphans        = ${MAX_ORPHANS}
net.ipv4.tcp_fin_timeout        = 20
net.ipv4.tcp_keepalive_time      = 300
net.ipv4.tcp_keepalive_probes   = 5
net.ipv4.tcp_keepalive_intvl    = 15
net.ipv4.tcp_max_tw_buckets     = 262144
net.ipv4.ip_local_port_range    = 10000 65535

# ── 高延迟不降速 ──
net.ipv4.tcp_slow_start_after_idle = 0

EOF

# ==============================================================================
# 加载 BBR 并热生效
# ==============================================================================
modprobe tcp_bbr >/dev/null 2>&1 || true
sysctl --system >/dev/null 2>&1

# ==============================================================================
# 输出结果展示
# ==============================================================================
echo ""
print_green "  ┌─────────────────────────────────────────────────────┐"
print_green "  │                    调优完成，当前生效参数           │"
print_green "  └─────────────────────────────────────────────────────┘"
printf "  %-20s %s\n" "拥塞控制:"  $(sysctl -n net.ipv4.tcp_congestion_control)
printf "  %-20s %s\n" "队列策略:"  $(sysctl -n net.core.default_qdisc)
printf "  %-20s %s bytes\n" "内核接收上限:" $(sysctl -n net.core.rmem_max)
printf "  %-20s %s bytes (%sMB)\n" "内核发送上限:" $(sysctl -n net.core.wmem_max) "${TCP_MAX_MB}"
printf "  %-20s %s\n" "tcp_rmem:"  "$(sysctl -n net.ipv4.tcp_rmem)"
printf "  %-20s %s\n" "tcp_wmem:"  "$(sysctl -n net.ipv4.tcp_wmem)"
printf "  %-20s %s\n" "tcp_mem:"   "$(sysctl -n net.ipv4.tcp_mem)"
printf "  %-20s %s\n" "somaxconn:" $(sysctl -n net.core.somaxconn)
echo ""
print_green "  配置文件: ${SYSCTL_CONF}"
[ -f "${SYSCTL_MAIN_BAK:-}" ] && print_warn "  原 sysctl.conf 备份: ${SYSCTL_MAIN_BAK}"
echo ""
