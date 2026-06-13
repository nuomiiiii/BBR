#!/bin/bash
# ==============================================================================
#           TCP 底层网络与并发调优 V3.0
#                                                          20260614
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
# 用法: read_int "提示语" 最小值 最大值 → 结果存入 $READ_RESULT
# ==============================================================================
READ_RESULT=0
function read_int() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local val
    while true; do
        read -rp "$prompt" val
        # 去除空白
        val="${val// /}"
        # 必须是纯数字
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
print_info "╔══════════════════════════════════════════╗"
print_info "║   TCP 调优参数配置  —  请输入服务器信息  ║"
print_info "╚══════════════════════════════════════════╝"
echo ""

print_line

# --- 平均延迟 ---
echo ""
print_info "  [1/3] 平均网络延迟 (RTT)"
echo "        通常可在本机 ping 目标客户端获得，例如从国内连美西约 150ms"
read_int "        请输入延迟 (ms) [10 ~ 500]: " 10 500
RTT_MS=$READ_RESULT
echo ""

print_line

# --- 内存 ---
echo ""
print_info "  [2/3] 服务器物理内存"
echo "        请输入总内存大小，单位 MB。例: 1024 = 1GB，2048 = 2GB"

# 自动探测当前值供参考
AUTO_MEM=$(free -m | awk '/^Mem:/{print $2}')
echo "        (当前系统检测到: ${AUTO_MEM} MB，可直接回车使用探测值)"
read -rp "        请输入内存大小 (MB) [256 ~ 4096，直接回车使用 ${AUTO_MEM}MB]: " MEM_INPUT
MEM_INPUT="${MEM_INPUT// /}"
if [ -z "$MEM_INPUT" ]; then
    # 回车使用探测值，但仍需钳制在允许范围
    TOTAL_MEM=$AUTO_MEM
    [ "$TOTAL_MEM" -lt 256  ] && TOTAL_MEM=256
    [ "$TOTAL_MEM" -gt 4096 ] && TOTAL_MEM=4096
    print_info "        → 使用系统探测值: ${TOTAL_MEM} MB"
else
    # 手动输入：校验范围
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
echo "        请输入套餐标称带宽，单位 Mbps。例: 1000 = 1Gbps，2000 = 2Gbps"
read_int "        请输入带宽 (Mbps) [200 ~ 5000]: " 200 5000
BW_MBPS=$READ_RESULT
echo ""

print_line

# ==============================================================================
# 参数展示确认
# ==============================================================================
echo ""
print_info "  ┌─────────────────────────────────────┐"
print_info "  │         输入参数确认                 │"
print_info "  ├─────────────────────────────────────┤"
printf "  │  %-12s %s %-20s │\n" "平均延迟:" "${RTT_MS}" "ms"
printf "  │  %-12s %s %-20s │\n" "内存大小:" "${TOTAL_MEM}" "MB"
printf "  │  %-12s %s %-20s │\n" "上行带宽:" "${BW_MBPS}" "Mbps"
print_info "  └─────────────────────────────────────┘"
echo ""
read -rp "  确认以上参数并开始调优？[Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_warn "  已取消。"
    exit 0
fi
echo ""

# ==============================================================================
# 核心计算
#
# BDP (字节) = 带宽(bps) × RTT(s) / 8
#            = BW_MBPS × 1,000,000 × (RTT_MS/1000) / 8
#            = BW_MBPS × RTT_MS × 125
#
# Bash 不支持浮点，全部用整数运算
# ==============================================================================
print_info "[*] 正在计算最优参数..."

BDP_BYTES=$(( BW_MBPS * RTT_MS * 125 ))

# BDP 向上取整到最近的 2^n MB，最小 8MB，最大 128MB
if   [ "$BDP_BYTES" -le 8388608   ]; then BDP_BUF=8388608    # 8MB
elif [ "$BDP_BYTES" -le 16777216  ]; then BDP_BUF=16777216   # 16MB
elif [ "$BDP_BYTES" -le 33554432  ]; then BDP_BUF=33554432   # 32MB
elif [ "$BDP_BYTES" -le 67108864  ]; then BDP_BUF=67108864   # 64MB
else                                      BDP_BUF=134217728  # 128MB
fi

# 内存安全上限：不超过物理内存的 3%（避免高并发 OOM）
MEM_BYTES=$(( TOTAL_MEM * 1024 * 1024 ))
MEM_3PCT=$(( MEM_BYTES * 3 / 100 ))

# 内存档位：向下取最近的 2^n MB（安全边界）
if   [ "$MEM_3PCT" -ge 134217728 ]; then MEM_BUF=134217728  # 128MB
elif [ "$MEM_3PCT" -ge 67108864  ]; then MEM_BUF=67108864   # 64MB
elif [ "$MEM_3PCT" -ge 33554432  ]; then MEM_BUF=33554432   # 32MB
elif [ "$MEM_3PCT" -ge 16777216  ]; then MEM_BUF=16777216   # 16MB
else                                     MEM_BUF=8388608    # 8MB
fi

# 取较小值：既满足 BDP 需求，又不超过内存安全上限
if [ "$BDP_BUF" -le "$MEM_BUF" ]; then
    TCP_MAX=$BDP_BUF
    LIMIT_REASON="BDP 主导"
else
    TCP_MAX=$MEM_BUF
    LIMIT_REASON="内存安全上限主导"
fi

TCP_MAX_MB=$(( TCP_MAX / 1024 / 1024 ))
BDP_MB=$(( BDP_BYTES / 1024 / 1024 ))

# tcp_mem 压力三档（单位：内存页，每页 4KB）
PAGE=4096
TM_LOW=$(( TCP_MAX * 4 / PAGE ))
TM_MID=$(( TCP_MAX * 6 / PAGE ))
TM_HIGH=$(( TCP_MAX * 8 / PAGE ))

# somaxconn / backlog：内存不足 512MB 时保守处理
BACKLOG=32768
[ "$TOTAL_MEM" -lt 512 ] && BACKLOG=8192

# 打印计算过程
BDP_CALC_MB=$(( BDP_BYTES / 1024 / 1024 ))
MEM_BUF_MB=$(( MEM_BUF / 1024 / 1024 ))
echo ""
print_info "  ┌─────────────────────────────────────────────────────┐"
print_info "  │                   计算结果                          │"
print_info "  ├─────────────────────────────────────────────────────┤"
printf "  │  %-22s %sMB  (= %sMbps × %sms × 125 / 1M)  \n" \
    "BDP 理论需求:" "$BDP_CALC_MB" "$BW_MBPS" "$RTT_MS"
printf "  │  %-22s %sMB  (物理内存 %sMB × 3%%)\n" \
    "内存安全上限:" "$MEM_BUF_MB" "$TOTAL_MEM"
printf "  │  %-22s %sMB  ← %s\n" \
    "最终缓冲区上限:" "$TCP_MAX_MB" "$LIMIT_REASON"
print_info "  └─────────────────────────────────────────────────────┘"
echo ""

# ==============================================================================
# Swap 策略
# 规则（基于手动输入的内存大小）：
#   < 512MB  → 创建 512MB Swap（内存极小，必须有保险）
#   < 1024MB → 创建 512MB Swap
#   < 2048MB → 创建 1024MB Swap
#   ≥ 2048MB → 不创建（内存充足）
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
    # 检查磁盘剩余空间是否足够
    DISK_FREE_MB=$(df -m / | awk 'NR==2{print $4}')
    if [ "$DISK_FREE_MB" -lt $(( SWAP_SIZE + 200 )) ]; then
        print_warn "[!] 磁盘剩余空间不足 (${DISK_FREE_MB}MB)，跳过 Swap 创建。"
    else
        dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE}" status=progress
        chmod 600 /swapfile
        mkswap /swapfile  >/dev/null 2>&1
        swapon /swapfile  >/dev/null 2>&1
        grep -q "/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        sysctl -w vm.swappiness=10 >/dev/null 2>&1
        print_green "[+] Swap ${SWAP_SIZE}MB 挂载成功，swappiness=10"
    fi
elif [ "$TOTAL_SWAP" -gt 0 ]; then
    print_green "[+] 已存在 Swap ${TOTAL_SWAP}MB，跳过创建。"
else
    print_green "[+] 内存 ${TOTAL_MEM}MB ≥ 2048MB，无需 Swap。"
fi

# ==============================================================================
# 备份并清空 /etc/sysctl.conf
# ==============================================================================
SYSCTL_MAIN="/etc/sysctl.conf"
SYSCTL_MAIN_BAK="/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
if [ -f "${SYSCTL_MAIN}" ]; then
    cp -a "${SYSCTL_MAIN}" "${SYSCTL_MAIN_BAK}"
    : > "${SYSCTL_MAIN}"
    print_warn "[-] /etc/sysctl.conf 已备份至 ${SYSCTL_MAIN_BAK} 并清空"
else
    touch "${SYSCTL_MAIN}"
fi

# ==============================================================================
# 写入 sysctl 配置
# ==============================================================================
SYSCTL_CONF="/etc/sysctl.d/zz-tcp-bbr.conf"
[ -f "${SYSCTL_CONF}" ] && rm -f "${SYSCTL_CONF}"

print_info "[+] 正在写入 ${SYSCTL_CONF} ..."

cat <<EOF > "${SYSCTL_CONF}"
# ==============================================================================
# TCP 调优配置 —— 自动生成，请勿手动修改
# 生成时间 : $(date '+%Y-%m-%d %H:%M:%S')
# 输入参数 : 延迟=${RTT_MS}ms  内存=${TOTAL_MEM}MB  带宽=${BW_MBPS}Mbps
# 缓冲区   : BDP=${BDP_CALC_MB}MB  内存上限=${MEM_BUF_MB}MB  最终取值=${TCP_MAX_MB}MB (${LIMIT_REASON})
# ==============================================================================

# ── 文件描述符解锁 ──────────────────────────────────────────────────────────
fs.file-max = 1048576
fs.nr_open  = 1048576

# ── BBR + FQ ────────────────────────────────────────────────────────────────
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
# 开启 MTU 探测，防止国际路由 ICMP 黑洞
net.ipv4.tcp_mtu_probing        = 1
net.ipv4.tcp_ecn                = 0

# ── TCP 缓冲区（根据 BDP 与内存双维度计算）───────────────────────────────────
net.core.rmem_max               = ${TCP_MAX}
net.core.wmem_max               = ${TCP_MAX}
net.ipv4.tcp_rmem               = 4096 262144 ${TCP_MAX}
net.ipv4.tcp_wmem               = 4096 262144 ${TCP_MAX}
# 高延迟场景：scale=1 让更多缓冲空间留给 TCP 窗口而非应用层
net.ipv4.tcp_adv_win_scale      = 1
# TCP 全局内存压力三段阈值（单位：4KB 页）
net.ipv4.tcp_mem                = ${TM_LOW} ${TM_MID} ${TM_HIGH}

# ── 高并发连接池 ─────────────────────────────────────────────────────────────
net.core.somaxconn              = ${BACKLOG}
net.core.netdev_max_backlog     = ${BACKLOG}
net.ipv4.tcp_max_syn_backlog    = ${BACKLOG}

# ── 连接复用与保活 ───────────────────────────────────────────────────────────
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_fin_timeout        = 20
net.ipv4.tcp_keepalive_time     = 300
net.ipv4.tcp_keepalive_probes   = 5
net.ipv4.tcp_keepalive_intvl    = 15
net.ipv4.tcp_max_tw_buckets     = 262144
net.ipv4.ip_local_port_range    = 10000 65535

# ── 高延迟不降速 ─────────────────────────────────────────────────────────────
# 禁止连接空闲后重新进入慢启动，保持持久连接满速
net.ipv4.tcp_slow_start_after_idle = 0

EOF

# ==============================================================================
# 加载 BBR 模块并热生效
# ==============================================================================
modprobe tcp_bbr >/dev/null 2>&1 || true
sysctl --system >/dev/null 2>&1

# ==============================================================================
# 输出
# ==============================================================================
echo ""
print_green "  ══════════════════════════════════════════\n"
print_green "            调优完成，当前生效参数          \n"
print_green "  ══════════════════════════════════════════\n"
printf "  %-20s %s\n" "拥塞控制:"  "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
printf "  %-20s %s\n" "队列策略:"  "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
printf "  %-20s %s bytes (%sMB)\n" "缓冲区上限:" "$(sysctl -n net.core.rmem_max 2>/dev/null)" "${TCP_MAX_MB}"
printf "  %-20s %s\n" "tcp_rmem:"  "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
printf "  %-20s %s\n" "tcp_wmem:"  "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
printf "  %-20s %s\n" "tcp_mem:"   "$(sysctl -n net.ipv4.tcp_mem 2>/dev/null)"
printf "  %-20s %s\n" "somaxconn:" "$(sysctl -n net.core.somaxconn 2>/dev/null)"
printf "  %-20s %s\n" "adv_win_scale:" "$(sysctl -n net.ipv4.tcp_adv_win_scale 2>/dev/null)"
printf "  %-20s %s\n" "notsent_lowat:" "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)"
echo ""
print_green "  配置文件: ${SYSCTL_CONF}"
[ -f "${SYSCTL_MAIN_BAK:-}" ] && print_warn "  原 sysctl.conf 备份: ${SYSCTL_MAIN_BAK}"
echo ""
