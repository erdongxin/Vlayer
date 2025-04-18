#!/bin/bash
set -e

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# 容器数量配置
NODE_COUNT=5
UBUNTU_IMAGE="ubuntu:24.04"
BASE_PROJECT_NAME="vlayer-project"  # 基础项目名称

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
    local project_name="${BASE_PROJECT_NAME}-${node_num}"  # 唯一项目名称
    local log_file="$HOME/prove-node${node_num}.log"
    
    local token_var="VLAYER_API_TOKEN${node_num}"
    local key_var="EXAMPLES_TEST_PRIVATE_KEY${node_num}"

    # 删除旧容器
    docker rm -f "$container_name" 2>/dev/null || true

    # 启动新容器
    echo -e "${GREEN}启动容器 ${container_name}...${RESET}"
    docker run -d \
        --name "$container_name" \
        --memory="4g" \          # 硬性内存限制
        --memory-swap="5g" \     # 允许使用1G交换空间
        -v "${log_file}:/root/prove.log" \
        -e "VLAYER_API_TOKEN=${!token_var}" \
        -e "EXAMPLES_TEST_PRIVATE_KEY=${!key_var}" \
        $UBUNTU_IMAGE sleep infinity

    # 容器内配置
    echo -e "${YELLOW}在 ${container_name} 中执行初始化...${RESET}"
    docker exec "$container_name" /bin/bash -c "
        set -e
        # 清理可能存在的旧项目
        rm -rf \"\$HOME/${BASE_PROJECT_NAME}-*\" 2>/dev/null || true
        
        apt update -y && apt upgrade -y
        apt install -y curl git unzip

        # 环境路径
        export PATH=\"\$HOME/.cargo/bin:\$HOME/.foundry/bin:\$HOME/.bun/bin:\$HOME/.vlayer/bin:\$PATH\"

        # 安装 Rust
        echo '安装 Rust...'
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || { echo '错误：Rust 安装失败'; exit 1; }
        source \$HOME/.cargo/env

        # 安装 Foundry
        echo '安装 Foundry...'
        curl -L https://foundry.paradigm.xyz | bash || { echo '错误：Foundry 安装失败'; exit 1; }
        \$HOME/.foundry/bin/foundryup

        # 安装 Bun
        echo '安装 Bun...'
        BUN_INSTALL_DIR=\"\$HOME/.bun\"
        curl -fsSL https://bun.sh/install | bash || { echo '错误：Bun 安装失败！'; exit 1; }
        export BUN_INSTALL=\"\$BUN_INSTALL_DIR\"
        export PATH=\"\$BUN_INSTALL/bin:\$PATH\"

        echo '验证 Bun 安装...'
        if ! command -v bun > /dev/null; then
            echo '错误：Bun 未正确安装！尝试使用绝对路径...'
            if [ -f \"\$BUN_INSTALL/bin/bun\" ]; then
                echo '检测到 Bun 的绝对路径，将手动添加到 PATH'
                export PATH=\"\$BUN_INSTALL/bin:\$PATH\"
            else
                echo '错误：Bun 未找到'; exit 1
            fi
        fi
        echo 'Bun 版本：' \$(bun --version)

        # 安装 Vlayer
        echo '安装 vlayer...'
        curl -SL https://install.vlayer.xyz | bash || { echo '错误：vlayer 安装失败'; exit 1; }
        \$HOME/.vlayer/bin/vlayerup

        # 配置 Git
        git config --global user.name 'node${node_num}'
        git config --global user.email 'node${node_num}@example.com'

        # 初始化项目
        mkdir -p \"\$HOME/projects\"
        cd \"\$HOME/projects\"
        vlayer init \"${project_name}\" --template simple-web-proof || { echo '错误：vlayer 初始化失败'; exit 1; }

        # 构建
        echo '构建项目...'
        cd \"${project_name}\"
        forge build || { echo '错误：forge build 失败'; exit 1; }

        # 安装bun项目依赖
        cd vlayer
        bun install

        # 生成环境文件
        echo '生成 .env.testnet.local...'
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
    cd \"/root/projects/${project_name}/vlayer\"  # 唯一项目路径
    echo \"[Node ${node_num}] 运行证明任务: \$(date)\" >> /root/prove.log
    bun run prove:testnet >> /root/prove.log 2>&1
    sleep \$((240 + RANDOM % 60)) # 随机4-5分钟运行一次
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

    # 串行启动，每个节点间隔10秒
    # for i in $(seq 1 $NODE_COUNT); do
    #     run_vlayer_node $i
    #     echo -e "${YELLOW}等待10秒启动下一个节点...${RESET}"
    #     sleep 10
    # done
    # wait # 等待所有后台任务完成

    # 并行启动所有节点
    for i in $(seq 1 $NODE_COUNT); do
        run_vlayer_node $i &
        echo -e "${YELLOW}等待10秒启动下一个节点...${RESET}"
        sleep 10
    done
    wait # 等待所有后台任务完成

    echo -e "\n${GREEN}所有节点已启动，日志文件：${RESET}"
    for i in $(seq 1 $NODE_COUNT); do
        echo -e "${YELLOW}tail -f $HOME/prove-node${i}.log${RESET}"
    done
}

main
