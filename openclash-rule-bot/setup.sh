#!/bin/sh

# 安装必要的软件包
opkg update
opkg install git-http docker docker-compose coreutils-nohup

# 创建工作目录
mkdir -p /root/openclash-bot
cd /root/openclash-bot

# 读取令牌值
TELEGRAM_TOKEN=$(cat /root/TELEGRAM_TOKEN.txt)
GITHUB_TOKEN=$(cat /root/GITHUB_TOKEN.txt)

# 下载配置文件
cat > bot.py << EOF
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import re
import logging
import asyncio
import traceback
import nest_asyncio
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, CallbackQueryHandler, ContextTypes, filters
import git

nest_asyncio.apply()

# 配置日志
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# 配置信息
TELEGRAM_TOKEN = "${TELEGRAM_TOKEN}"
GITHUB_TOKEN = "${GITHUB_TOKEN}"
REPO_URL = f"https://x-access-token:{GITHUB_TOKEN}@github.com/AceDylan/Custom_OpenClash_Rules.git"
REPO_PATH = "/app/repo"

# 规则文件列表
RULE_FILES = {
    "ai": "rule/Custom_Proxy_AI.list",
    "direct": "rule/Custom_Direct_my.list",
    "emby": "rule/Custom_Proxy_Emby.list",
    "media": "rule/Custom_Proxy_Media.list",
    "google": "rule/Custom_Proxy_Google.list"
}

# 用户状态存储
user_states = {}

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/start命令"""
    user_name = update.effective_user.first_name
    await update.message.reply_text(
        f"🚀 *欢迎 {user_name} 使用 OpenClash 规则管理机器人！*\n\n"
        "✨ *功能简介：*\n"
        "此机器人可以帮您轻松添加域名或IP到不同的规则文件中。\n\n"
        "📝 *使用方法：*\n"
        "1️⃣ 直接发送域名或IP地址\n"
        "2️⃣ 选择要添加到哪个规则文件\n"
        "3️⃣ 机器人将自动完成添加和提交\n\n"
        "📋 *示例格式：*\n"
        "• 域名: example.com\n"
        "• IP地址: 8.8.8.8\n\n"
        "❓ 需要帮助请输入 /help 命令\n"
        "🔄 开始添加规则请直接发送域名或IP",
        parse_mode='Markdown'
    )

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/help命令"""
    await update.message.reply_text(
        "📖 *使用指南*\n\n"
        "📌 *基本操作：*\n"
        "1️⃣ 直接发送域名或IP地址\n"
        "2️⃣ 选择要添加到哪个规则文件\n"
        "3️⃣ 机器人将自动添加规则并推送到GitHub仓库\n\n"
        "📋 *支持的规则文件：*\n"
        "• 🤖 AI代理规则 (Custom_Proxy_AI.list)\n"
        "• 🏠 直连规则 (Custom_Direct_my.list)\n"
        "• 🎬 Emby代理规则 (Custom_Proxy_Emby.list)\n"
        "• 📺 媒体代理规则 (Custom_Proxy_Media.list)\n"
        "• 🔍 Google代理规则 (Custom_Proxy_Google.list)",
        parse_mode='Markdown'
    )

def is_valid_domain(domain):
    """验证是否是有效的域名"""
    pattern = r'^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    return re.match(pattern, domain) is not None

def is_valid_ip(ip):
    """验证是否是有效的IP地址"""
    pattern = r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$'
    match = re.match(pattern, ip)
    if not match:
        return False
    for i in range(1, 5):
        if int(match.group(i)) > 255:
            return False
    return True

async def handle_input(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理用户输入的域名或IP地址"""
    user_input = update.message.text.strip()
    user_id = update.effective_user.id
    
    # 验证输入是域名还是IP
    if is_valid_domain(user_input):
        input_type = "domain"
    elif is_valid_ip(user_input):
        input_type = "ip"
    else:
        await update.message.reply_text("❌ 输入格式不正确，请输入有效的域名或IP地址。")
        return
    
    # 保存用户输入和类型
    user_states[user_id] = {
        "input": user_input,
        "type": input_type
    }
    
    # 创建文件选择菜单
    keyboard = [
        [InlineKeyboardButton("🤖 AI代理规则", callback_data="file:ai")],
        [InlineKeyboardButton("🏠 直连规则", callback_data="file:direct")],
        [InlineKeyboardButton("🎬 Emby代理规则", callback_data="file:emby")],
        [InlineKeyboardButton("📺 媒体代理规则", callback_data="file:media")],
        [InlineKeyboardButton("🔍 Google代理规则", callback_data="file:google")]
    ]
    
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await update.message.reply_text("🔽 请选择要添加到哪个规则文件:", reply_markup=reply_markup)

async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理按钮回调"""
    query = update.callback_query
    await query.answer()
    
    user_id = update.effective_user.id
    if user_id not in user_states:
        await query.edit_message_text("⏱️ 会话已过期，请重新发送域名或IP地址。")
        return
    
    user_data = user_states[user_id]
    callback_data = query.data
    
    if callback_data.startswith("file:"):
        file_key = callback_data.split(":")[1]
        if file_key in RULE_FILES:
            file_path = RULE_FILES[file_key]
            await add_rule_and_commit(query, user_data, file_path)
        else:
            await query.edit_message_text("❌ 无效的文件选择，请重新操作。")

async def add_rule_and_commit(query, user_data, file_path):
    """添加规则到文件并提交到Git仓库"""
    input_value = user_data["input"]
    input_type = user_data["type"]
    
    try:
        # 检查是否为有效的Git仓库
        is_git_repo = False
        if os.path.exists(REPO_PATH):
            try:
                repo = git.Repo(REPO_PATH)
                is_git_repo = True
            except git.exc.InvalidGitRepositoryError:
                is_git_repo = False
        
        # 如果目录不存在或不是有效的Git仓库，则克隆
        if not os.path.exists(REPO_PATH) or not is_git_repo:
            await query.edit_message_text("⏳ 正在克隆仓库...")
            
            # 对于挂载的目录，不尝试删除，而是尝试直接在其中初始化Git仓库
            if os.path.exists(REPO_PATH) and not is_git_repo:
                try:
                    # 清空目录内容，但保留目录本身
                    for item in os.listdir(REPO_PATH):
                        item_path = os.path.join(REPO_PATH, item)
                        if os.path.isfile(item_path):
                            os.remove(item_path)
                        elif os.path.isdir(item_path):
                            import shutil
                            shutil.rmtree(item_path)
                    
                    # 在现有目录中克隆
                    repo = git.Repo.clone_from(REPO_URL, REPO_PATH)
                except Exception as e:
                    logger.error(f"清空目录失败: {str(e)}")
                    # 如果清空失败，尝试直接初始化Git仓库
                    repo = git.Repo.init(REPO_PATH)
                    origin = repo.create_remote('origin', REPO_URL)
                    origin.fetch()
                    repo.create_head('main', origin.refs.main)
                    repo.heads.main.set_tracking_branch(origin.refs.main)
                    repo.heads.main.checkout()
                    origin.pull()
            else:
                # 确保父目录存在
                os.makedirs(os.path.dirname(REPO_PATH), exist_ok=True)
                repo = git.Repo.clone_from(REPO_URL, REPO_PATH)
        else:
            await query.edit_message_text("🔄 正在更新仓库...")
            repo = git.Repo(REPO_PATH)
            origin = repo.remotes.origin
            origin.pull()
        
        # 添加规则到文件
        full_path = os.path.join(REPO_PATH, file_path)
        
        # 生成规则行
        if input_type == "domain":
            rule_line = f"DOMAIN-SUFFIX,{input_value}\n"
            comment = f"# 添加域名 {input_value}"
        else:  # IP
            rule_line = f"IP-CIDR,{input_value}/32,no-resolve\n"
            comment = f"# 添加IP {input_value}"
        
        # 检查文件是否存在，不存在则创建
        os.makedirs(os.path.dirname(full_path), exist_ok=True)
        
        # 检查规则是否已经存在
        rule_exists = False
        if os.path.exists(full_path):
            with open(full_path, 'r', encoding='utf-8') as f:
                content = f.read()
                if rule_line in content:
                    rule_exists = True
        
        if rule_exists:
            await query.edit_message_text(f"ℹ️ 规则 '{input_value}' 已存在于文件中，无需添加。")
            return
        
        # 追加规则到文件
        with open(full_path, 'a', encoding='utf-8') as f:
            f.write(f"\n{comment}\n{rule_line}")
        
        # 提交并推送更改
        repo.git.add(file_path)
        repo.git.commit('-m', f'添加规则: {input_value} 到 {os.path.basename(file_path)}')
        origin = repo.remotes.origin
        origin.push()
        
        await query.edit_message_text(
            f"✅ 成功！\n\n'{input_value}' 已添加到 {os.path.basename(file_path)} 并推送到仓库。"
        )
        
    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"发生错误: {str(e)}\n{error_details}")
        await query.edit_message_text(f"❌ 操作失败: {str(e)}\n详细错误请查看日志。")

async def run_bot():
    """异步运行机器人"""
    # 创建应用并注册处理程序
    application = Application.builder().token(TELEGRAM_TOKEN).build()
    
    # 添加处理程序
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_input))
    application.add_handler(CallbackQueryHandler(handle_callback))
    
    # 启动机器人 - 移除了多余的start()调用
    await application.initialize()
    await application.run_polling(allowed_updates=Update.ALL_TYPES)

def main() -> None:
    """启动机器人"""
    # 设置并启动事件循环
    asyncio.run(run_bot())

if __name__ == '__main__':
    main() 
EOF

cat > requirements.txt << 'EOF'
python-telegram-bot>=20.0
gitpython>=3.1.30
sniffio>=1.3.0
anyio>=3.7.1
httpx>=0.24.1
nest-asyncio>=1.5.6
EOF

cat > Dockerfile << 'EOF'
FROM python:3.11-slim

WORKDIR /app

COPY bot.py /app/
COPY requirements.txt /app/

RUN apt-get update && \
    apt-get install -y git dbus policykit-1 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir -r requirements.txt && \
    mkdir -p /app/repo && \
    chmod -R 777 /app/repo

CMD ["python", "bot.py"] 
EOF

cat > docker-compose.yml << 'EOF'
services:
  telegram-bot:
    build: .
    container_name: openclash-rule-bot
    restart: always
    network_mode: "host"
    volumes:
      - ./repo:/app/repo
    environment:
      - TZ=Asia/Shanghai 
EOF

# 创建repo目录
mkdir -p repo

# 配置git用户信息
git config --global user.email "1041151706@qq.com"
git config --global user.name "AceDylan"

# 启动Docker容器
docker-compose up -d --build

echo "-------------------------------------"
echo "✅ OpenClash规则管理机器人已启动"
echo "📝 请记得修改bot.py文件中的GitHub用户名"
echo "🤖 您可以在Telegram上搜索您的机器人并开始使用"
echo "-------------------------------------" 