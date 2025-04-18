#!/bin/bash
set -e

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# 配置参数
DEBUG=true
NODE_COUNT=10
UBUNTU_IMAGE="ubuntu:24.04"
PROJECT_NAME="1"
INSTALL_RETRIES=5  # 增加安装重试次数

check_env() {
    for i in $(seq 1 $NODE_COUNT); do
        token_var="VLAYER_API_TOKEN${i}"
        key_var="EXAMPLES_TEST_PRIVATE_KEY${i}"
        
        [ -z "${!token_var}" ] && echo -e "${RED}错误：请设置 ${token_var}${RESET}" && exit 1
        [ -z "${!key_var}" ] && echo -e "${RED}错误：请设置 ${key_var}${RESET}" && exit 1
    done

    for i in $(seq 1 $NODE_COUNT); do
        log_file="$HOME/prove-node${i}.log"
        [ -d "$log_file" ] && rm -rf "$log_file"
        touch "$log_file" && chmod 666 "$log_file"
    done
}

install_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}正在安装Docker...${RESET}"
        apt-get update -y
        apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update -y
        apt install -y docker-ce
        systemctl start docker
        systemctl enable docker
        echo -e "${GREEN}Docker已安装${RESET}"
    else
        echo -e "${GREEN}Docker已存在${RESET}"
    fi
}

setup_container() {
    if ! docker image inspect $UBUNTU_IMAGE &> /dev/null; then
        echo -e "${YELLOW}正在拉取 $UBUNTU_IMAGE 镜像...${RESET}"
        for retry in {1..5}; do
            docker pull $UBUNTU_IMAGE && break || {
                echo -e "${RED}拉取失败，10秒后重试 (${retry}/5)${RESET}"
                sleep 10
            }
        done || { echo -e "${RED}镜像拉取失败${RESET}"; exit 1; }
    fi
}

run_vlayer_node() {
    local node_num=$1
    local container_name="vlayer-node${node_num}"
    local log_file="$HOME/prove-node${node_num}.log"
    local token_var="VLAYER_API_TOKEN${node_num}"
    local key_var="EXAMPLES_TEST_PRIVATE_KEY${node_num}"

    # 清理残留容器
    docker rm -f "$container_name" 2>/dev/null || true
    docker volume ls | grep "vlayer-${node_num}" | awk '{print $2}' | xargs -r docker volume rm

    # 启动容器命令优化
    docker run -d \
        --name "$container_name" \
        -v "${log_file}:/root/prove.log" \
        -e "VLAYER_API_TOKEN=${!token_var}" \
        -e "EXAMPLES_TEST_PRIVATE_KEY=${!key_var}" \
        $UBUNTU_IMAGE sleep infinity

    # 带重试机制的安装过程
    docker exec "$container_name" /bin/bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive

        # 基础系统更新
        for i in {1..3}; do
            apt update -y && apt upgrade -y && break || {
                echo 'APT 更新失败，重试 \$i/3...'
                sleep 10
                [ \$i -eq 3 ] && exit 1
            }
        done

        # 安装基础工具
        apt install -y curl git unzip ca-certificates libssl-dev pkg-config

        # Rust 安装（带重试）
        for i in {1..$INSTALL_RETRIES}; do
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && break || {
                echo 'Rust 安装失败，重试 \$i/$INSTALL_RETRIES...'
                sleep \$((i * 10))
                [ \$i -eq $INSTALL_RETRIES ] && exit 1
            }
        done
        source \$HOME/.cargo/env

        # Foundry 安装（带重试）
        for i in {1..$INSTALL_RETRIES}; do
            curl -L https://foundry.paradigm.xyz | bash && foundryup && break || {
                echo 'Foundry 安装失败，重试 \$i/$INSTALL_RETRIES...'
                sleep \$((i * 10))
                [ \$i -eq $INSTALL_RETRIES ] && exit 1
            }
        done

        # Bun 安装（带重试）
        for i in {1..$INSTALL_RETRIES}; do
            curl -fsSL https://bun.sh/install | bash && break || {
                echo 'Bun 安装失败，重试 \$i/$INSTALL_RETRIES...'
                sleep \$((i * 10))
                [ \$i -eq $INSTALL_RETRIES ] && exit 1
            }
        done
        export PATH=\"\$HOME/.bun/bin:\$PATH\"

        # 关键点5：vlayer 安装优化
        for i in {1..$INSTALL_RETRIES}; do
            echo '正在尝试安装 vlayer (尝试 \$i/$INSTALL_RETRIES)...'
            rm -rf \$HOME/.vlayer 2>/dev/null
            curl -SL https://install.vlayer.xyz | bash -s -- --no-cache && break || {
                echo 'vlayer 安装失败，重试 \$i/$INSTALL_RETRIES...'
                sleep \$((i * 20))
                [ \$i -eq $INSTALL_RETRIES ] && exit 1
            }
        done
        \$HOME/.vlayer/bin/vlayerup

        # 项目初始化
        git config --global user.name 'node${node_num}'
        git config --global user.email 'node${node_num}@example.com'
        
        for i in {1..3}; do
            vlayer init \"$PROJECT_NAME\" --template simple-web-proof && break || {
                echo '项目初始化失败，重试 \$i/3...'
                sleep 10
                rm -rf \"$PROJECT_NAME\"
                [ \$i -eq 3 ] && exit 1
            }
        done

        cd \"$PROJECT_NAME\"
        forge build

        cd vlayer
        bun install --force  # 强制重新安装依赖

        # 环境配置
        cat > .env.testnet.local <<EOF
VLAYER_API_TOKEN=\$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=\$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=optimismSepolia
JSON_RPC_URL=https://sepolia.optimism.io
EOF

        # 任务脚本（增加错误处理）
        cat > /root/run_prove.sh <<'SCRIPT_EOF'
#!/bin/bash
while true; do
    cd "/root/$PROJECT_NAME/vlayer" || { echo "目录不存在"; exit 1; }
    echo \"[Node ${node_num}] 启动任务: \$(date)\" >> /root/prove.log
    if ! bun run prove:testnet >> /root/prove.log 2>&1; then
        echo \"[Node ${node_num}] 任务失败，尝试重新安装依赖...\" >> /root/prove.log
        bun install --force >> /root/prove.log 2>&1
    fi
    sleep \$((240 + RANDOM % 60))
done
SCRIPT_EOF

        chmod +x /root/run_prove.sh
        nohup /root/run_prove.sh >/dev/null 2>&1 &
    " || { echo -e "${RED}容器 ${container_name} 初始化失败${RESET}"; exit 1; }

    echo -e "${GREEN}节点 ${container_name} 已就绪${RESET}"
}

main() {
    check_env
    install_docker
    setup_container

    
    # 使用函数导出和并行控制
    export -f run_vlayer_node  # 导出函数到子shell
    # 控制并发数（使用xargs实现并行控制）
    seq 1 $NODE_COUNT | xargs -P 2 -I {} bash -c "run_vlayer_node {}"
    
    echo -e "\n${GREEN}所有节点已启动${RESET}"
    docker ps -a --filter "name=vlayer-node" --format "table {{.Names}}\t{{.Status}}"
}

main
