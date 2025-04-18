# 单机启动说明

## 1、手动配置环境变量
export VLAYER_API_TOKEN=ey..
export EXAMPLES_TEST_PRIVATE_KEY=0x..

## 2、运行一键脚本（自动清除旧容器）
curl -O https://raw.githubusercontent.com/erdongxin/Vlayer/refs/heads/main/vlayer.sh && chmod +x vlayer.sh && ./vlayer.sh

## 3、查看日志
tail -f /root/prove.log

# 多号启动说明（每个镜像大约需要6G空间），默认启动5个

## 1、手动配置环境变量，要启动多少个就配多少个
export VLAYER_API_TOKEN1="your_token_1"
export EXAMPLES_TEST_PRIVATE_KEY1="your_key_1"
...
export VLAYER_API_TOKEN10="your_token_5"
export EXAMPLES_TEST_PRIVATE_KEY10="your_key_5"

## 2、运行一键脚本（自动清除旧容器）
curl -O https://raw.githubusercontent.com/erdongxin/Vlayer/refs/heads/main/vlayer_duo.sh && chmod +x vlayer_duo.sh && ./vlayer_duo.sh

## 3、查看所有节点日志
tail -f ~/prove-node*.log

## 4、手动删除所有容器（空间不足时）
docker rm -f vlayer-node{1..10}
