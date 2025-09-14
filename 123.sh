#!/bin/bash
# Author: That dream
# Desc: 一键创建 V2Ray 节点脚本，支持 xray-core 和 sing-box，自动下载、安装、配置、systemctl 管理，并生成 vmess 链接

# ANSI 颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 框绘制字符
TOP_LEFT="┌"
TOP_RIGHT="┐"
BOTTOM_LEFT="└"
BOTTOM_RIGHT="┘"
HORIZONTAL="─"
VERTICAL="│"

# 全局变量
BASE_DIR="/usr/local/v2ray"
CONFIG_DIR="$BASE_DIR/configs"
CONFIG_FILE="$BASE_DIR/config.json"
SERVICE_NAME="v2ray"
EXEC=""
CORE="xray-core"
TRANSPORT="ws" # 默认传输协议为 ws

# ----------------- 工具函数 -----------------
random_uuid() {
    cat /proc/sys/kernel/random/uuid
}

random_port() {
    echo $(( (RANDOM % 10000) + 10000 ))
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
        i386|i686) ARCH="386" ;;
        *) echo -e "${RED}❌ 不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac
    echo "$ARCH"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ 请以 root 权限运行此脚本${NC}"
        exit 1
    fi
}

check_dependencies() {
    for cmd in curl wget unzip tar systemctl jq; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${YELLOW}⬇️ 安装依赖: $cmd${NC}"
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y $cmd
            elif command -v yum &> /dev/null; then
                yum install -y $cmd
            else
                echo -e "${RED}❌ 无法安装 $cmd，请手动安装${NC}"
                exit 1
            fi
        fi
    done
}

# ----------------- 获取下载链接 -----------------
get_download_url() {
    local repo=$1
    local core_name=$2
    local arch=$3
    local version
    local asset_pattern
    local download_url

    version=$(curl -s "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name')
    if [ -z "$version" ]; then
        echo -e "${RED}❌ 无法获取 $core_name 最新版本${NC}"
        exit 1
    fi

    if [ "$core_name" == "xray-core" ]; then
        case "$arch" in
            amd64) asset_pattern="Xray-linux-64.zip" ;;
            arm64) asset_pattern="Xray-linux-arm64-v8a.zip" ;;
            arm) asset_pattern="Xray-linux-arm32-v7a.zip" ;;
            386) asset_pattern="Xray-linux-32.zip" ;;
        esac
    else
        case "$arch" in
            amd64) asset_pattern="sing-box-$version-sing-box-linux-amd64.tar.gz" ;;
            arm64) asset_pattern="sing-box-$version-sing-box-linux-arm64.tar.gz" ;;
            arm) asset_pattern="sing-box-$version-sing-box-linux-armv7.tar.gz" ;;
            386) asset_pattern="sing-box-$version-sing-box-linux-386.tar.gz" ;;
        esac
    fi

    download_url=$(curl -s "https://api.github.com/repos/$repo/releases/latest" \
  | jq -r ".assets[] | select(.name | test(\"$asset_pattern\")) | select(.name | endswith(\".dgst\") | not) | .browser_download_url")
    if [ -z "$download_url" ]; then
        echo -e "${RED}❌ 未找到 $core_name 的 $arch 架构下载链接${NC}"
        exit 1
    fi
    echo "$download_url"
}

# ----------------- 核心安装 -----------------
install_core() {
    mkdir -p $BASE_DIR
    cd $BASE_DIR || exit

    ARCH=$(detect_arch)

    if [ "$CORE" == "xray-core" ]; then
        if [ ! -f "$BASE_DIR/xray" ]; then
            echo -e "${YELLOW}⬇️ 下载 xray-core ($ARCH)...${NC}"
            DOWNLOAD_URL=$(get_download_url "XTLS/Xray-core" "xray-core" "$ARCH")
            wget -O xray.zip "$DOWNLOAD_URL" || {
                echo -e "${RED}❌ 下载 xray-core 失败${NC}"
                exit 1
            }
            unzip -o xray.zip && rm -f xray.zip
            chmod +x xray
        fi
        EXEC="$BASE_DIR/xray"
    else
        if [ ! -f "$BASE_DIR/sing-box" ]; then
            echo -e "${YELLOW}⬇️ 下载 sing-box ($ARCH)...${NC}"
            DOWNLOAD_URL=$(get_download_url "SagerNet/sing-box" "sing-box" "$ARCH")
            wget -O sing-box.tar.gz "$DOWNLOAD_URL" || {
                echo -e "${RED}❌ 下载 sing-box 失败${NC}"
                exit 1
            }
            tar -xzf sing-box.tar.gz --strip-components=1 && rm -f sing-box.tar.gz
            chmod +x sing-box
        fi
        EXEC="$BASE_DIR/sing-box"
    fi
}

# ----------------- 配置生成 -----------------
create_config() {
    UUID=$(random_uuid)

    # 输入端口
    read -rp "请输入端口 (回车随机生成): " PORT
    if [ -z "$PORT" ]; then
        PORT=$(random_port)
    fi

    # 为 xray-core 生成 API 端口
    if [ "$CORE" == "xray-core" ]; then
        API_PORT=$(random_port)
        while [ "$API_PORT" == "$PORT" ]; do
            API_PORT=$(random_port)
        done
    fi

    # 输入别名
    read -rp "请输入节点别名 (回车默认为 Thatdream): " NODENAME
    if [ -z "$NODENAME" ]; then
        NODENAME="Thatdream"
    fi

    # 选择传输协议
    echo -e "${BLUE}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL} 选择传输协议 ${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
    echo -e "${BLUE}${VERTICAL} [1] ws (默认)  [2] tcp: ${NC}"
    read -rp "${BLUE}${VERTICAL} 请输入选项 (回车默认 ws): ${NC}" TRANSPORT_CHOICE
    case "$TRANSPORT_CHOICE" in
        2) TRANSPORT="tcp" ;;
        *) TRANSPORT="ws" ;;
    esac

    # 输入伪装域名
    read -rp "请输入伪装域名 (回车使用默认 tjtn.pan.wo.cn): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        DOMAIN="tjtn.pan.wo.cn"
    fi

    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    CONFIG_FILE="$CONFIG_DIR/$NODENAME.json"

    if [ "$CORE" == "sing-box" ]; then
        if [ "$TRANSPORT" == "ws" ]; then
            cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in-$NODENAME",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "ws_settings": {
          "path": "/",
          "headers": {
            "Host": "$DOMAIN"
          }
        }
      },
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["vmess-in-$NODENAME"],
        "outbound": "direct"
      }
    ]
  }
}
EOF
        else
            cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in-$NODENAME",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "tcp",
        "tcp_settings": {
          "header": {
            "type": "http",
            "host": "$DOMAIN"
          }
        }
      },
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["vmess-in-$NODENAME"],
        "outbound": "direct"
      }
    ]
  }
}
EOF
        fi
    else
        if [ "$TRANSPORT" == "ws" ]; then
            cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "access": "",
    "error": "",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/",
          "headers": {
            "Host": "$DOMAIN"
          }
        }
      }
    },
    {
      "port": $API_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": $API_PORT,
        "network": "tcp"
      },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ],
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "StatsService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  }
}
EOF
        else
            cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "access": "",
    "error": "",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {
          "header": {
            "type": "http",
            "host": "$DOMAIN"
          }
        }
      }
    },
    {
      "port": $API_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": $API_PORT,
        "network": "tcp"
      },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ],
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "StatsService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  }
}
EOF
        fi
    fi

    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}❌ 无法获取服务器 IP${NC}"
        exit 1
    fi

    # 存储 API 端口映射
    if [ "$CORE" == "xray-core" ]; then
        echo "$NODENAME:$API_PORT" >> "$BASE_DIR/api_ports.txt"
    fi

    show_node_info "$CONFIG_FILE" "$NODENAME"
}

# ----------------- 显示节点信息 -----------------
show_node_info() {
    local config_file=$1
    local nodename=$2

    if [ -f "$config_file" ]; then
        if [ "$CORE" == "sing-box" ]; then
            UUID=$(grep -Po '"uuid": "\K[^"]+' "$config_file")
            PORT=$(grep -Po '"listen_port": \K\d+' "$config_file")
            DOMAIN=$(grep -Po '"Host": "\K[^"]+' "$config_file" || grep -Po '"host": "\K[^"]+' "$config_file" || echo "tjtn.pan.wo.cn")
            TRANSPORT=$(grep -Po '"type": "\K[^"]+' "$config_file" | head -1)
        else
            UUID=$(grep -Po '"id": "\K[^"]+' "$config_file")
            PORT=$(grep -Po '"port": \K\d+' "$config_file" | head -1)
            DOMAIN=$(grep -Po '"Host": "\K[^"]+' "$config_file" || grep -Po '"host": "\K[^"]+' "$config_file" || echo "tjtn.pan.wo.cn")
            TRANSPORT=$(grep -Po '"network": "\K[^"]+' "$config_file" | head -1)
            API_PORT=$(grep -Po '"port": \K\d+' "$config_file" | tail -1)
        fi
        SERVER_IP=$(curl -s ipv4.icanhazip.com)

        echo -e "\n${GREEN}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL} 节点信息 ($nodename) ${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
        echo -e "${GREEN}${VERTICAL} 核心: $CORE${NC}"
        echo -e "${GREEN}${VERTICAL} 协议: vmess${NC}"
        echo -e "${GREEN}${VERTICAL} 地址: $SERVER_IP${NC}"
        echo -e "${GREEN}${VERTICAL} 端口: $PORT${NC}"
        [ "$CORE" == "xray-core" ] && echo -e "${GREEN}${VERTICAL} API 端口: $API_PORT${NC}"
        echo -e "${GREEN}${VERTICAL} UUID: $UUID${NC}"
        echo -e "${GREEN}${VERTICAL} 传输: $TRANSPORT${NC}"
        [ "$TRANSPORT" == "tcp" ] && echo -e "${GREEN}${VERTICAL} 伪装类型: http${NC}"
        echo -e "${GREEN}${VERTICAL} 伪装域名: $DOMAIN${NC}"
        echo -e "${GREEN}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"

        # 生成 vmess 链接
        VMESS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "$nodename",
  "add": "$SERVER_IP",
  "port": "$PORT",
  "id": "$UUID",
  "aid": "0",
  "net": "$TRANSPORT",
  "type": "$([ "$TRANSPORT" == "tcp" ] && echo "http" || echo "none")",
  "host": "$DOMAIN",
  "path": "/",
  "tls": ""
}
EOF
)
        VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

        echo -e "\n${YELLOW}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL} V2RayN/V2RayNG 导入链接 ${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
        echo -e "${YELLOW}${VERTICAL} $VMESS_LINK${NC}"
        echo -e "${YELLOW}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
    else
        echo -e "${RED}❌ 未找到配置文件: $config_file${NC}"
    fi
}

# ----------------- 显示所有节点信息 -----------------
show_all_nodes() {
    if [ -d "$CONFIG_DIR" ] && [ -n "$(ls -A $CONFIG_DIR)" ]; then
        echo -e "${BLUE}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL} 所有节点信息 ${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
        for config_file in "$CONFIG_DIR"/*.json; do
            nodename=$(basename "$config_file" .json)
            show_node_info "$config_file" "$nodename"
        done
        echo -e "${BLUE}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
    else
        echo -e "${RED}❌ 未找到任何节点配置${NC}"
    fi
}

# ----------------- 流量统计 -----------------
show_traffic_stats() {
    if [ "$CORE" == "xray-core" ]; then
        if ! systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${RED}❌ 服务未运行，无法获取流量统计${NC}"
            return
        fi

        if [ -d "$CONFIG_DIR" ] && [ -n "$(ls -A $CONFIG_DIR)" ]; then
            echo -e "${BLUE}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL} 流量统计 ${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
            for config_file in "$CONFIG_DIR"/*.json; do
                nodename=$(basename "$config_file" .json)
                API_PORT=$(grep "$nodename:" "$BASE_DIR/api_ports.txt" | cut -d':' -f2)
                if [ -z "$API_PORT" ]; then
                    echo -e "${YELLOW}${VERTICAL} 节点 $nodename: 未找到 API 端口${NC}"
                    continue
                fi

                # 使用 xray 的 API 获取流量统计
                stats=$(curl -s "http://127.0.0.1:$API_PORT/stats" -H "Content-Type: application/json" -d '{"reset": false}' 2>/dev/null)
                if [ -z "$stats" ]; then
                    echo -e "${RED}${VERTICAL} 节点 $nodename: 无法连接到 API 端口 $API_PORT${NC}"
                    continue
                fi

                echo -e "${BLUE}${VERTICAL} 节点: $nodename${NC}"
                uplink=$(echo "$stats" | jq -r '.stat[] | select(.name | contains("user>>>") and contains("uplink")) | .value')
                downlink=$(echo "$stats" | jq -r '.stat[] | select(.name | contains("user>>>") and contains("downlink")) | .value')
                if [ -n "$uplink" ] && [ -n "$downlink" ]; then
                    echo -e "${BLUE}${VERTICAL} 上行流量: $((uplink / 1024 / 1024)) MB${NC}"
                    echo -e "${BLUE}${VERTICAL} 下行流量: $((downlink / 1024 / 1024)) MB${NC}"
                else
                    echo -e "${YELLOW}${VERTICAL} 无流量数据${NC}"
                fi
                echo -e "${BLUE}${VERTICAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${VERTICAL}${NC}"
            done
            echo -e "${BLUE}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
        else
            echo -e "${RED}❌ 未找到任何节点配置${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️ sing-box 暂不支持流量统计${NC}"
    fi
}

# ----------------- systemd 服务 -----------------
create_service() {
    local exec_cmd
    if [ "$CORE" == "sing-box" ]; then
        exec_cmd="$EXEC run -c $CONFIG_FILE"
    else
        exec_cmd="$EXEC -config $CONFIG_FILE"
    fi

    cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=V2Ray Node ($CORE)
After=network.target

[Service]
ExecStart=$exec_cmd
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        systemctl daemon-reload
        echo -e "${GREEN}✅ systemd 服务文件已生成${NC}"
    else
        echo -e "${RED}❌ 生成 systemd 服务文件失败${NC}"
        exit 1
    fi
}

start_service() {
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${GREEN}✅ 服务已启动${NC}"
    else
        echo -e "${RED}❌ 服务启动失败，请检查日志: journalctl -u $SERVICE_NAME${NC}"
        exit 1
    fi
}

stop_service() {
    systemctl stop $SERVICE_NAME
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${RED}❌ 服务停止失败${NC}"
    else
        echo -e "${RED}🛑 服务已停止${NC}"
    fi
}

restart_service() {
    systemctl restart $SERVICE_NAME
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${YELLOW}🔄 服务已重启${NC}"
    else
        echo -e "${RED}❌ 服务重启失败，请检查日志: journalctl -u $SERVICE_NAME${NC}"
    fi
}

delete_service() {
    systemctl stop $SERVICE_NAME 2>/dev/null
    systemctl disable $SERVICE_NAME 2>/dev/null
    rm -f /etc/systemd/system/$SERVICE_NAME.service
    rm -rf $BASE_DIR
    systemctl daemon-reload
    echo -e "${RED}🗑️ 服务和配置已删除${NC}"
}

show_version() {
    echo -e "${BLUE}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL} 版本信息 ${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
    echo -e "${BLUE}${VERTICAL} 系统架构: $(uname -m)${NC}"
    if [ -f "$BASE_DIR/xray" ]; then
        echo -e "${GREEN}${VERTICAL} ✅ xray-core 版本: $($BASE_DIR/xray version 2>/dev/null | head -n 1)${NC}"
    fi
    if [ -f "$BASE_DIR/sing-box" ]; then
        echo -e "${GREEN}${VERTICAL} ✅ sing-box 版本: $($BASE_DIR/sing-box version 2>/dev/null | head -n 1)${NC}"
    fi
    echo -e "${BLUE}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
}

# ----------------- 主菜单 -----------------
main_menu() {
    echo -e "${BLUE}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL} 选择核心 ${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
    echo -e "${BLUE}${VERTICAL} [1] xray-core  [2] sing-box (默认 xray-core): ${NC}"
    read -rp "${BLUE}${VERTICAL} 请输入选项: ${NC}" CORE_CHOICE
    case "$CORE_CHOICE" in
        2) CORE="sing-box" ;;
        *) CORE="xray-core" ;;
    esac

    while true; do
        echo -e "${BLUE}${TOP_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${TOP_RIGHT}${NC}"
        echo -e "${BLUE}${VERTICAL}         节点管理脚本         ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 1) 安装并生成节点         ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 2) 启动服务               ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 3) 停止服务               ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 4) 重启服务               ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 5) 删除服务和节点         ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 6) 显示版本信息           ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 7) 查看当前节点信息       ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 8) 查看所有节点信息       ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 9) 查看流量统计           ${VERTICAL}${NC}"
        echo -e "${BLUE}${VERTICAL} 0) 退出                   ${VERTICAL}${NC}"
        echo -e "${BLUE}${BOTTOM_LEFT}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${BOTTOM_RIGHT}${NC}"
        read -rp "${YELLOW}请输入选项: ${NC}" ACTION

        case "$ACTION" in
            1)
                check_root
                check_dependencies
                install_core
                create_config
                create_service
                start_service
                ;;
            2) start_service ;;
            3) stop_service ;;
            4) restart_service ;;
            5) delete_service ;;
            6) show_version ;;
            7) show_node_info "$CONFIG_FILE" "Thatdream" ;;
            8) show_all_nodes ;;
            9) show_traffic_stats ;;
            0) echo -e "${YELLOW}👋 退出脚本${NC}"; exit 0 ;;
            *) echo -e "${RED}❌ 无效选项${NC}" ;;
        esac
    done
}

main_menu
