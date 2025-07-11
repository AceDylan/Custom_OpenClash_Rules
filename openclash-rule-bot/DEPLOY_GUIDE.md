# OpenClash规则管理机器人部署指南

## 部署前准备

1. OpenWrt路由器已安装Docker支持
2. Telegram机器人Token
3. GitHub个人访问令牌

## 部署步骤

### 方法一：使用一键安装脚本（推荐）

1. 登录到OpenWrt shell
```bash
touch TELEGRAM_TOKEN.txt
touch GITHUB_TOKEN.txt
touch OPENCLASH_API_SECRET.txt
```
然后把token分别填入(电报、github、openclash密钥--监控面板可获取)

2. 下载setup.sh脚本：
```bash
cd /root
wget https://raw.githubusercontent.com/AceDylan/Custom_OpenClash_Rules/main/openclash-rule-bot/setup.sh
# 如果wget命令不可用，可使用curl：
# curl -o setup.sh https://raw.githubusercontent.com/YOUR_USERNAME/Custom_OpenClash_Rules/main/openclash-rule-bot/setup.sh
```

3. 赋予脚本执行权限：
```bash
chmod +x setup.sh
```

4. 运行安装脚本：
```bash
./setup.sh
```

## 使用方法

1. 在Telegram中搜索并添加你的机器人
2. 发送域名（如example.com）或IP地址（如8.8.8.8）
3. 点击机器人提供的按钮选择要添加到的规则文件
4. 机器人会自动添加规则并推送到GitHub仓库

## 常见问题

1. 如果容器无法启动，请检查Docker服务是否正常运行：
```bash
service docker status
```

2. 如果遇到网络问题，请检查OpenWrt的DNS设置和防火墙规则

3. 如需查看机器人日志，可使用以下命令：
```bash
docker logs openclash-rule-bot
```

4. 如果需要重启机器人，可使用以下命令：
```bash
cd /root/openclash-bot
docker-compose restart
```

5. 如果需要完全重建机器人，可使用以下命令：
```bash
cd /root/openclash-bot
docker-compose down
docker-compose up -d --build
``` 