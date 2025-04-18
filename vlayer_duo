#!/bin/bash
set -e

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# 容器数量配置
NODE_COUNT=10
UBUNTU_IMAGE="ubuntu:24.04"
PROJECT_NAME="1"

check_env() {
    # 检查所有节点的环境变量
    for i in $(seq 1 $NODE_COUNT); do
        token_var="VLAYER_API_TOKEN${i}"
        key_var="EXAMPLES_TEST_PRIVATE_KEY${i}"
        
        if [ -z "${!token_var}" ]; then
            echo -e "${RED}错误：请设置 ${token_var} 环境变量${RESET}"
            exit 1
        fi

        if [ -z "${!key_var}" ]; then
            echo -e "${RED}错误：请设置 ${key_var} 环境变量${RESET}"
            exit 1
        fi
    done

    # 检查所有日志文件
    for i in $(seq 1 $NODE_COUNT); do
        log_file="$HOME/prove-node${i}.log"
        if [ -d "$log_file" ]; then
            echo -e "${YELLOW}警告：$log_file 是目录，正在删除...${RESET}"
            rm -rf "$log_file" || { echo -e "${RED}错误：无法删除 $log_file${RESET}"; exit 1; }
        fi
        if [ ! -f "$log_file" ]; then
            touch "$log_file" || { echo -e "${RED}错误：无法创建 $log_file${RESET}"; exit 1; }
            chmod 666 "$log_file" || { echo -e "${RED}错误：无法设置 $log_file 权限${RESET}"; exit 1; }
        fi
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

    # 删除旧容器
    docker rm -f "$container_name" 2>/dev/null || true

    # 启动新容器
    echo -e "${GREEN}启动容器 ${container_name}...${RESET}"
    docker run -d \
        --name "$container_name" \
        -v "${log_file}:/root/prove.log" \
        -e "VLAYER_API_TOKEN=${!token_var}" \
        -e "EXAMPLES_TEST_PRIVATE_KEY=${!key_var}" \
        $UBUNTU_IMAGE sleep infinity

    # 容器内配置
    echo -e "${YELLOW}在 ${container_name} 中执行初始化...${RESET}"
    docker exec "$container_name" /bin/bash -c "
        set -e
        apt update -y && apt upgrade -y
        apt install -y curl git unzip

        # 环境路径
        export PATH=\"\$HOME/.cargo/bin:\$HOME/.foundry/bin:\$HOME/.bun/bin:\$HOME/.vlayer/bin:\$PATH\"

        # 安装 Rust
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source \$HOME/.cargo/env

        # 安装 Foundry
        curl -L https://foundry.paradigm.xyz | bash
        \$HOME/.foundry/bin/foundryup

        # 安装 Bun
        curl -fsSL https://bun.sh/install | bash
        export PATH=\"\$HOME/.bun/bin:\$PATH\"

        # 安装 Vlayer
        curl -SL https://install.vlayer.xyz | bash
        \$HOME/.vlayer/bin/vlayerup

        # 配置 Git
        git config --global user.name 'node${node_num}'
        git config --global user.email 'node${node_num}@example.com'

        # 初始化项目
        vlayer init \"$PROJECT_NAME\" --template simple-web-proof
        cd \"$PROJECT_NAME\"
        forge build

        # 配置项目依赖
        cd vlayer
        bun install

        # 生成环境文件
        cat > .env.testnet.local <<EOF
VLAYER_API_TOKEN=\$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=\$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=optimismSepolia
JSON_RPC_URL=https://sepolia.optimism.io
EOF

        # 创建定时任务脚本
        cat > /root/run_prove.sh <<'SCRIPT_EOF'
#!/bin/bash
while true; do
    cd \"/root/$PROJECT_NAME/vlayer\"
    echo \"[Node ${node_num}] 运行证明任务: \$(date)\" >> /root/prove.log
    bun run prove:testnet >> /root/prove.log 2>&1
    sleep \$((360 + RANDOM % 30)) # 添加随机延迟避免同时运行
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

    # 并行启动所有节点
    for i in $(seq 1 $NODE_COUNT); do
        run_vlayer_node $i &
    done
    wait # 等待所有后台任务完成

    echo -e "\n${GREEN}所有节点已启动，日志文件：${RESET}"
    for i in $(seq 1 $NODE_COUNT); do
        echo -e "${YELLOW}tail -f $HOME/prove-node${i}.log${RESET}"
    done
}

main
