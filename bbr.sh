#!/bin/bash

set -euo pipefail

# --- UI 提示函数 ---
function print_red { echo -e -n "\e[1;31m$1\e[0m"; }
function print_green { echo -e -n "\e[1;32m$1\e[0m"; }
function print_info { echo -e -n "\e[1;36m$1\e[0m"; }
function print_warn { echo -e -n "\e[1;33m$1\e[0m"; }

# --- 权限检查 ---
if [ "$(id -u)" != "0" ]; then
    print_red "[!] 致命错误: 请使用 sudo 或 root 身份运行本脚本！\n"
    exit 1
fi

function opt_bbr() {
    print_info "正在执行 TCP 底层网络与并发调优...\n"
    
    # ==========================================
    # 1. 拦截 LXC 容器环境
    # ==========================================
    if [ -f /proc/1/environ ] && grep -a -q "container=lxc" /proc/1/environ 2>/dev/null; then
        print_warn "\n[-] 状态探测：检测到当前为 LXC 容器环境！\n"
        print_info "  -> LXC 共享宿主机内核，无法独立挂载 Swap 或修改 BBR 拥塞控制算法。\n"
        print_info "  -> 请在 PVE 宿主机上开启 BBR，容器将自动继承。此步骤已安全跳过。\n"        
        return 0
    fi

    # ==========================================
    # 2. 高兼容物理内存探测与 Swap 创建
    # ==========================================
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local total_swap=$(free -m | awk '/^Swap:/{print $2}')
    
    if [ "$total_mem" -le 1200 ] && [ "$total_swap" -eq 0 ]; then
        print_info "检测到低内存，正在使用传统 dd 模式挂载 1GB Swap (最高兼容性)...\n"
        # 强制使用 dd 确保物理块连续，完美兼容 Btrfs/XFS/Ext4 等现代文件系统
        dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile >/dev/null 2>&1
        grep -q "/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        print_green "  -> Swap 挂载成功！\n"
    else
        print_green "  -> 内存充足或 Swap 已存在，跳过 Swap 创建。\n"
    fi

    # ==========================================
    # 3. 动态计算与 TCP 核心调优
    # ==========================================
    local SYSCTL_CONF="/etc/sysctl.d/99-bbr.conf"
    
    if [ ! -f "${SYSCTL_CONF}" ]; then
        print_info "正在动态计算缓冲区并注入纯 TCP 拥塞与并发优化...\n"
        
        # 动态计算 TCP 缓冲区尺寸
        local tcp_max
        if [ "$total_mem" -le 800 ]; then tcp_max=8388608
        elif [ "$total_mem" -le 1500 ]; then tcp_max=16777216
        else tcp_max=33554432; fi

        # 尝试预加载 bbr 模块
        modprobe tcp_bbr >/dev/null 2>&1 || true

        cat <<EOF > ${SYSCTL_CONF}
# ==========================================
# 极限TCP网络底层压榨 (大并发与防断流调优)
# ==========================================

# 1. 文件描述符上限解锁 
fs.file-max = 1048576
fs.nr_open = 1048576

# 2. BBR 与 吞吐量队列策略
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# 开启 MTU 探测，防止复杂国际路由中的 ICMP 黑洞
net.ipv4.tcp_mtu_probing = 1
# 开启显式拥塞通知 (主动抗丢包)
net.ipv4.tcp_ecn = 2

# 3. 动态 TCP 缓冲区分配
net.core.rmem_max = ${tcp_max}
net.core.wmem_max = ${tcp_max}
net.ipv4.tcp_rmem = 4096 87380 ${tcp_max}
net.ipv4.tcp_wmem = 4096 16384 ${tcp_max}
net.ipv4.tcp_adv_win_scale = -2

# 4. 高并发连接池扩容 
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# 5. 内存极速回收与端口复用机制 (专为反代/API/短连接优化)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.ip_local_port_range = 10000 65535

# 6. Web/代理 极速响应优化
# 禁用空闲后的慢启动，让持久连接保持满速
net.ipv4.tcp_slow_start_after_idle = 0
# 限制 TCP 发送队列的未发送字节数，大幅降低延迟抖动
net.ipv4.tcp_notsent_lowat = 131072
EOF

        sysctl --system >/dev/null 2>&1
        print_green "TCP调优完成，配置文件已写入 ${SYSCTL_CONF}！\n"
    else
        print_warn "检测到 ${SYSCTL_CONF} 已存在，跳过网络配置写入。\n"
    fi
}

# 执行主函数
opt_bbr
