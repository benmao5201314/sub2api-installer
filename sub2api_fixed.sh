#!/bin/bash

# Sub2API 交互式一键管理脚本 (修复版)
# 支持：安装、卸载、查看信息
# 适用系统：Ubuntu

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

# 全局变量
PG_USER="sub2api_user"
PG_DB="sub2api_db"
PG_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
SUB2API_PORT="5002"
INSTALL_DIR="/opt/sub2api"
CONFIG_DIR="/etc/etc/sub2api"
SERVICE_USER="sub2api"

# 打印 LOGO
show_logo() {
    clear
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${GREEN}       Sub2API 一键管理脚本 (修复版)      ${NC}"
    echo -e "${BLUE}==========================================${NC}"
}

# 打印信息
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 检查权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "请使用 sudo 运行此脚本！"
    fi
}

# 安装过程
do_install() {
    # 0. 选择端口
    echo -e "${YELLOW}请输入 Sub2API 运行端口 (默认 5002):${NC}"
    read -p "> " custom_port
    SUB2API_PORT=${custom_port:-5002}
    print_info "将使用端口: $SUB2API_PORT"

    print_info "开始安装 Sub2API 及其依赖..."
    
    # 1. 更新环境
    apt update && apt install -y curl tar postgresql postgresql-contrib redis-server libcap2-bin || print_error "依赖安装失败"
    
    # 2. 配置数据库
    systemctl start postgresql
    # 如果数据库已存在则先删除（确保密码一致性）
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$PG_USER'" | grep -q 1; then
        print_warning "检测到已存在的数据库用户，正在重新创建以匹配新密码..."
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS $PG_DB;"
        sudo -u postgres psql -c "DROP USER IF EXISTS $PG_USER;"
    fi
    
    sudo -u postgres psql -c "CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD';"
    sudo -u postgres psql -c "CREATE DATABASE $PG_DB OWNER $PG_USER;"
    
    # 3. 配置 Redis
    systemctl start redis-server
    
    # 4. 下载 Sub2API
    LATEST_VERSION=$(curl -s https://api.github.com/repos/Wei-Shaw/sub2api/releases/latest | grep 'tag_name' | cut -d: -f2 | tr -d ' ",v')
    ARCH=$(dpkg --print-architecture)
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
    
    DOWNLOAD_URL="https://github.com/Wei-Shaw/sub2api/releases/download/v${LATEST_VERSION}/sub2api_${LATEST_VERSION}_linux_${ARCH}.tar.gz"
    curl -L "$DOWNLOAD_URL" | tar -xz -C "$INSTALL_DIR"
    
    # 处理二进制文件名（有时解压出来就是 sub2api）
    if [ -f "$INSTALL_DIR/sub2api" ]; then
        mv "$INSTALL_DIR/sub2api" "$INSTALL_DIR/sub2api_bin"
    fi
    chmod +x "$INSTALL_DIR/sub2api_bin"
    
    # 特殊处理：如果是特权端口（如 80），赋予程序监听权限
    if [ "$SUB2API_PORT" -lt 1024 ]; then
        print_info "检测到特权端口 $SUB2API_PORT，正在配置权限..."
        setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/sub2api_bin"
    fi
    
    # 5. 写入配置
    cat > "$CONFIG_DIR"/sub2api.env << EOF
SERVER_PORT=$SUB2API_PORT
DATABASE_URL="postgres://$PG_USER:$PG_PASSWORD@localhost:5432/$PG_DB?sslmode=disable"
REDIS_URL="redis://localhost:6379"
EOF

    # 6. 创建服务
    id "$SERVICE_USER" &>/dev/null || useradd -r -s /bin/false "$SERVICE_USER"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR" "$CONFIG_DIR"
    
    cat > /etc/systemd/system/sub2api.service << EOF
[Unit]
Description=Sub2API Service
After=network.target postgresql.service redis-server.service

[Service]
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/sub2api_bin
EnvironmentFile=$CONFIG_DIR/sub2api.env
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sub2api
    systemctl start sub2api
    
    # 完成
    PUBLIC_IP=$(curl -s ifconfig.me)
    print_success "安装完成！"
    echo -e "------------------------------------------"
    echo -e "公网访问: http://$PUBLIC_IP:$SUB2API_PORT"
    echo -e "数据库名称: $PG_DB"
    echo -e "数据库用户: $PG_USER"
    echo -e "数据库密码: $PG_PASSWORD"
    echo -e "Redis 地址: localhost:6379 (无密码)"
    echo -e "------------------------------------------"
    read -p "按回车键返回菜单..."
}

# 卸载过程
do_uninstall() {
    read -p "确定要卸载吗？此操作将删除所有程序和数据库数据！(y/n): " confirm
    if [ "$confirm" == "y" ]; then
        print_info "正在停止服务..."
        systemctl stop sub2api
        systemctl disable sub2api
        
        print_info "正在清理数据库..."
        systemctl start postgresql
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS $PG_DB;"
        sudo -u postgres psql -c "DROP USER IF EXISTS $PG_USER;"
        
        print_info "正在删除文件..."
        rm -f /etc/systemd/system/sub2api.service
        rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
        
        print_success "Sub2API 已成功卸载，环境已清理干净。"
    fi
    read -p "按回车键返回菜单..."
}

# 主菜单
main_menu() {
    while true; do
        show_logo
        echo -e "  1. 安装 Sub2API"
        echo -e "  2. 卸载 Sub2API"
        echo -e "  3. 退出脚本"
        echo -e "${BLUE}==========================================${NC}"
        read -p "请输入数字选择: " choice
        
        case $choice in
            1) do_install ;;
            2) do_uninstall ;;
            3) exit 0 ;;
            *) echo -e "${RED}输入错误，请重新选择！${NC}"; sleep 1 ;;
        esac
    done
}

# 启动脚本
check_root
main_menu
