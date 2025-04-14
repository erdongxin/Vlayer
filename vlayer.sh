#!/bin/bash
set -e

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# 环境配置
CONTAINER_NAME="vlayer-node"
UBUNTU_IMAGE="ubuntu:24.04"
PROJECT_NAME="1"

check_env() {
    # 检查 VLAYER_API_TOKEN 环境变量
    if [ -z "$VLAYER_API_TOKEN" ]; then
        echo "错误：请设置 VLAYER_API_TOKEN 环境变量，例如：export VLAYER_API_TOKEN='your-api-token'"
        exit 1
    fi

    # 检查 EXAMPLES_TEST_PRIVATE_KEY 环境变量
    if [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ]; then
        echo "错误：请设置 EXAMPLES_TEST_PRIVATE_KEY 环境变量，例如：export EXAMPLES_TEST_PRIVATE_KEY='your-private-key'"
        exit 1
    fi
    # 检查宿主机的 /root/prove.log，确保是文件
    if [ -d "$HOME/prove.log" ]; then
        echo "错误：$HOME/prove.log 是一个目录，正在删除..."
        rm -rf $HOME/prove.log || { echo "错误：无法删除 $HOME/prove.log"; exit 1; }
    fi
    if [ ! -f "$HOME/prove.log" ]; then
        echo "创建 $HOME/prove.log 文件..."
        touch $HOME/prove.log || { echo "错误：无法创建 $HOME/prove.log"; exit 1; }
        chmod 666 $HOME/prove.log || { echo "错误：无法设置 $HOME/prove.log 权限"; exit 1; }
    fi
}

# 安装docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        log_message "${RED}未找到Docker。正在安装Docker...${RESET}"
        apt-get update -y
        apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update -y
        apt install -y docker-ce
        systemctl start docker
        systemctl enable docker
        echo -e "${GREEN}Docker已安装并启动。${RESET}"
    else
        echo -e "${GREEN}Docker已安装。${RESET}"
    fi

}

# 拉取镜像
setup_container() {
    if ! docker image inspect $UBUNTU_IMAGE &> /dev/null; then
        echo -e "${YELLOW}正在拉取 $UBUNTU_IMAGE 镜像...${RESET}"
        for i in {1..5}; do
            if docker pull $UBUNTU_IMAGE; then
                break
            else
                echo -e "${RED}第 $i 次尝试失败，10秒后重试...${RESET}"
                sleep 10
            fi
        done || { echo -e "${RED}❌ 镜像拉取失败，请检查网络连接${RESET}"; exit 1; }
    fi
}

# 初始化并运行
run_vlayer() {

    # 删除旧容器
    docker rm -f $CONTAINER_NAME 2>/dev/null

    # 确保容器正在运行
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        sudo docker run -d --name $CONTAINER_NAME -v /root/prove.log:/root/prove.log $UBUNTU_IMAGE sleep infinity || { echo "错误：启动容器失败！"; exit 1; }
    fi

    # 在容器内执行完整流程
    echo "执行容器内配置..."
    sudo docker exec $CONTAINER_NAME /bin/bash -c "
        set -e
        echo '更新 apt 包索引...'
        apt update && apt upgrade -y || { echo '错误：apt 更新失败'; exit 1; }
        echo '安装 curl、git、unzip...'
        apt install -y curl git unzip || { echo '错误：apt 安装失败'; exit 1; }

        export PATH=\"\$HOME/.cargo/bin:\$HOME/.foundry/bin:\$HOME/.bun/bin:\$HOME/.vlayer/bin:\$PATH\"

        echo '安装 Rust...'
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || { echo '错误：Rust 安装失败'; exit 1; }
        source \$HOME/.cargo/env

        echo '安装 Foundry...'
        curl -L https://foundry.paradigm.xyz | bash || { echo '错误：Foundry 安装失败'; exit 1; }
        \$HOME/.foundry/bin/foundryup

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

        echo '安装 vlayer...'
        curl -SL https://install.vlayer.xyz | bash || { echo '错误：vlayer 安装失败'; exit 1; }
        \$HOME/.vlayer/bin/vlayerup

        echo '配置 git...'
        git config --global user.name '1'
        git config --global user.email '1'

        echo '初始化 vlayer 项目...'
        vlayer init \"$PROJECT_NAME\" --template simple-web-proof || { echo '错误：vlayer 初始化失败'; exit 1; }

        echo '构建项目...'
        cd \"$PROJECT_NAME\"
        forge build || { echo '错误：forge build 失败'; exit 1; }

        echo '安装 Bun 依赖...'
        cd vlayer
        bun install || { echo '错误：bun install 失败！'; exit 1; }

        echo '生成 .env.testnet.local...'
        cat > .env.testnet.local <<ENVVARS
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=optimismSepolia
JSON_RPC_URL=https://sepolia.optimism.io
ENVVARS

        echo '生成 /root/run_prove.sh...'
        cat > /root/run_prove.sh <<'INNER_EOF'
#!/bin/bash
cd "/root/$PROJECT_NAME/vlayer"
source ~/.bashrc

TIME_FILE=/root/last_prove_time.txt
INTERVAL=3600 # 每小时执行一次

while true; do
    CURRENT_TIME=\$(date +%s)
    if [ -f \"\$TIME_FILE\" ]; then
        LAST_TIME=\$(cat \"\$TIME_FILE\")
    else
        LAST_TIME=0
    fi

    TIME_DIFF=\$((CURRENT_TIME - LAST_TIME))
    if [ \$TIME_DIFF -ge \$INTERVAL ] || [ \$LAST_TIME -eq 0 ]; then
        echo \"运行 bun run prove:testnet，时间: \$(date)\" >> /root/prove.log
        if bun run prove:testnet >> /root/prove.log 2>&1; then
            echo \"成功执行 bun run prove:testnet，时间: \$(date)\" >> /root/prove.log
        else
            echo \"bun run prove:testnet 执行失败，时间: \$(date)\" >> /root/prove.log
        fi
        echo \$CURRENT_TIME > \"\$TIME_FILE\"
    fi

    sleep 600
done
INNER_EOF

    echo '设置 /root/run_prove.sh 可执行权限...'
    chmod +x /root/run_prove.sh || { echo '错误：chmod /root/run_prove.sh 失败'; exit 1; }
    echo '启动 run_prove.sh 后台进程...'
    nohup /root/run_prove.sh >> /root/prove.log 2>&1 &
    echo '容器内配置完成！'
    "
}

main() {
    check_env
    install_docker
    setup_container
    run_vlayer
}

main
