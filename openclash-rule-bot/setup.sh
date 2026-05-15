#!/bin/sh

# 检查必要文件是否存在
check_file() {
    if [ ! -f "$1" ]; then
        echo "错误：必要文件 $1 不存在"
        echo "请创建此文件并提供正确的内容"
        return 1
    fi
    return 0
}

# 检查所有必要的配置文件
echo "正在检查必要配置文件..."
check_file "/root/TELEGRAM_TOKEN.txt" || exit 1
check_file "/root/GITHUB_TOKEN.txt" || exit 1
check_file "/root/AUTHORIZED_USER_ID.txt" || exit 1
check_file "/root/OPENCLASH_API_SECRET.txt" || exit 1

echo "所有必要配置文件已找到，继续安装..."

# 安装必要的软件包
opkg update
opkg install git-http docker docker-compose coreutils-nohup

# 创建工作目录
mkdir -p /root/openclash-bot
cd /root/openclash-bot

# 读取令牌值
TELEGRAM_TOKEN=$(cat /root/TELEGRAM_TOKEN.txt)
GITHUB_TOKEN=$(cat /root/GITHUB_TOKEN.txt)
# 设置授权用户ID（替换为您自己的Telegram用户ID）
AUTHORIZED_USER_ID=$(cat /root/AUTHORIZED_USER_ID.txt)
# OpenClash API 配置
OPENCLASH_API_URL="http://192.168.6.1:9090"
OPENCLASH_API_SECRET=$(cat /root/OPENCLASH_API_SECRET.txt)

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
import requests
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
OPENCLASH_API_URL = "${OPENCLASH_API_URL}"
OPENCLASH_API_SECRET = "${OPENCLASH_API_SECRET}"
# 授权用户ID列表
AUTHORIZED_USER_ID = "${AUTHORIZED_USER_ID}"

# 规则文件列表
RULE_FILES = {
    "direct": "rule/Custom_Direct_my.list",
    "emby": "rule/Custom_Proxy_Emby.list",
    "media": "rule/Custom_Proxy_Media.list",
    "google": "rule/Custom_Proxy_Google.list"
}

# 规则文件与OpenClash规则名称映射
OPENCLASH_RULE_MAPPING = {
    "rule/Custom_Direct_my.list": "Custom_Direct_my",
    "rule/Custom_Proxy_Emby.list": "Custom_Proxy_Emby",
    "rule/Custom_Proxy_Media.list": "Custom_Proxy_Media",
    "rule/Custom_Proxy_Google.list": "Custom_Proxy_Google"
}

# 规则文件对应的显示名称
RULE_FILE_NAMES = {
    "direct": "🏠 直连规则",
    "emby": "🎬 Emby代理规则",
    "media": "💬 社交媒体代理规则",
    "google": "🇬 谷歌与AI代理规则"
}

# 用户状态存储
user_states = {}

# 循环清理任务存储：按用户ID记录正在运行的定时任务
loop_clear_tasks = {}
LOOP_CLEAR_INTERVAL_SECONDS = 10

# 每页显示的规则条数
RULES_PER_PAGE = 10

def build_pagination_buttons(page, total_pages, prefix):
    """构建通用分页按钮行

    Args:
        page: 当前页码（0-based）
        total_pages: 总页数
        prefix: 回调数据前缀，如 "view:page", "delete:page"

    Returns:
        list: 包含分页按钮的行列表（可能为空、一行或两行）
    """
    if total_pages <= 1:
        return []

    rows = []
    nav_buttons = []

    # 首页按钮（不在第一页时显示）
    if page > 1:
        nav_buttons.append(InlineKeyboardButton("« 首页", callback_data=f"{prefix}:0"))

    # 上一页按钮
    if page > 0:
        nav_buttons.append(InlineKeyboardButton("‹ 上一页", callback_data=f"{prefix}:{page-1}"))

    # 页码指示器（不可点击，用当前页占位）
    nav_buttons.append(InlineKeyboardButton(f"[{page+1}/{total_pages}]", callback_data="noop"))

    # 下一页按钮
    if page < total_pages - 1:
        nav_buttons.append(InlineKeyboardButton("下一页 ›", callback_data=f"{prefix}:{page+1}"))

    # 末页按钮（不在最后一页时显示）
    if page < total_pages - 2:
        nav_buttons.append(InlineKeyboardButton("末页 »", callback_data=f"{prefix}:{total_pages-1}"))

    if nav_buttons:
        rows.append(nav_buttons)

    return rows

async def check_permission(update: Update) -> bool:
    """检查用户是否有权限使用机器人"""
    user_id = str(update.effective_user.id)
    authorized = user_id == AUTHORIZED_USER_ID
    if not authorized:
        logger.warning(f"未授权的访问尝试：用户ID {user_id}")
    return authorized

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/start命令"""
    # 检查权限
    if not await check_permission(update):
        await update.message.reply_text("❌ 对不起，您没有权限使用此机器人。")
        return
        
    user_name = update.effective_user.first_name

    # 创建现代化功能按钮
    keyboard = [
        [
            InlineKeyboardButton("➕ 添加规则", callback_data="action:add"),
            InlineKeyboardButton("👁️ 查看规则", callback_data="action:view")
        ],
        [
            InlineKeyboardButton("❌ 删除规则", callback_data="action:delete"),
            InlineKeyboardButton("↔️ 移动规则", callback_data="action:move")
        ],
        [
            InlineKeyboardButton("🔍 搜索规则", callback_data="action:search"),
            InlineKeyboardButton("🔄 更新全部", callback_data="action:refresh_all")
        ],
        [
            InlineKeyboardButton("🧹 清空连接", callback_data="action:clear_connections"),
            InlineKeyboardButton("ℹ️ 帮助信息", callback_data="action:help")
        ],
        [
            InlineKeyboardButton("▶️ 启动循环清理", callback_data="action:start_loop_clear_connections"),
            InlineKeyboardButton("⏹️ 关闭循环清理", callback_data="action:stop_loop_clear_connections")
        ],
        [
            InlineKeyboardButton("📺 测试油管解锁", callback_data="action:youtube_unlock")
        ]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)

    await update.message.reply_text(
        f"🚀 *欢迎 {user_name} 使用 OpenClash 规则管理机器人！*\n\n"
        "此机器人可以帮您管理OpenClash规则，支持添加、查看、删除、移动和搜索规则。\n\n"
        "请选择您要执行的操作：",
        parse_mode='Markdown',
        reply_markup=reply_markup
    )

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/help命令"""
    # 检查权限
    if not await check_permission(update):
        await update.message.reply_text("❌ 对不起，您没有权限使用此机器人。")
        return
        
    await update.message.reply_text(
        "📖 *OpenClash规则管理机器人使用指南*\n\n"
        "📌 *基本操作：*\n\n"
        "➕ *添加规则：*\n"
        "- 直接发送域名或IP地址\n"
        "- 选择要添加到哪个规则文件\n"
        "- 机器人将自动添加规则并更新\n\n"
        "👁️ *查看规则：*\n"
        "- 使用 /view 命令\n"
        "- 选择要查看的规则文件\n"
        "- 使用分页浏览规则内容\n\n"
        "❌ *删除规则：*\n"
        "- 使用 /delete 命令\n"
        "- 选择规则文件并选择要删除的规则\n"
        "- 确认删除后机器人将更新规则\n\n"
        "↔️ *移动规则：*\n"
        "- 使用 /move 命令\n"
        "- 选择源规则文件并选择要移动的规则\n"
        "- 选择目标规则文件完成移动\n\n"
        "🔄 *更新全部规则：*\n"
        "- 点击更新全部规则按钮\n"
        "- 机器人会依次刷新所有OpenClash规则\n\n"
        "📋 *支持的规则文件：*\n"
        "• 🏠 直连规则 (Custom_Direct_my.list)\n"
        "• 🎬 Emby代理规则 (Custom_Proxy_Emby.list)\n"
        "• 💬 社交媒体代理规则 (Custom_Proxy_Media.list)\n"
        "• 🇬 谷歌与AI代理规则 (Custom_Proxy_Google.list)\n\n"
        "🧹 *清空连接：*\n"
        "- 点击清空连接按钮\n"
        "- 机器人会调用OpenClash API清空所有当前连接\n\n"
        "🔁 *循环清理：*\n"
        "- 点击启动循环清理按钮后，机器人会立即尝试清空一次连接，并每10秒自动清空一次\n"
        "- 点击关闭循环清理按钮后，停止定时调用OpenClash API",
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

async def check_github_sync_status(repo, commit_hash):
    """检查GitHub同步状态的函数"""
    try:
        # 获取最新的远程引用
        origin = repo.remotes.origin
        origin.fetch()
        
        # 检查提交是否已存在于远程仓库
        for ref in origin.refs:
            if ref.name == 'origin/main':
                # 如果提交已存在于远程仓库，返回True
                if commit_hash in [c.hexsha for c in repo.iter_commits(ref, max_count=5)]:
                    return True
        return False
    except Exception as e:
        logger.error(f"检查GitHub同步状态时发生错误: {str(e)}")
        return False

async def wait_for_github_sync(query, message_template, repo, commit_hash):
    """使用轮询方式等待GitHub同步的函数"""
    max_attempts = 15  # 增加最大尝试次数（原来是12）
    wait_time = 6  # 增加每次等待时间（原来是5秒）
    
    for attempt in range(max_attempts):
        # 更新等待消息
        remaining = (max_attempts - attempt) * wait_time
        await query.edit_message_text(message_template.format(wait_time=remaining))
        
        # 检查同步状态
        if await check_github_sync_status(repo, commit_hash):
            # 同步成功后再多等待5秒，确保完全同步
            await asyncio.sleep(5)
            return True
        
        # 等待一段时间后再次检查
        await asyncio.sleep(wait_time)
    
    # 达到最大尝试次数后，再多等待10秒
    await asyncio.sleep(10)
    return True  # 假设同步已完成

async def handle_input(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理用户输入的文本"""
    # 检查权限
    if not await check_permission(update):
        await update.message.reply_text("❌ 对不起，您没有权限使用此机器人。")
        return
        
    user_input = update.message.text.strip()
    user_id = update.effective_user.id

    # 处理搜索输入
    if user_id in user_states and user_states[user_id].get("action") == "search_waiting":
        await handle_search_input(update, context, user_input)
        return
    
    # 处理添加规则输入
    if user_id in user_states and user_states[user_id].get("action") == "add_waiting_input":
        # 先判断输入类型并设置type字段
        if is_valid_domain(user_input):
            user_states[user_id]["type"] = "domain"
            user_states[user_id]["input"] = user_input
        elif is_valid_ip(user_input):
            user_states[user_id]["type"] = "ip"
            user_states[user_id]["input"] = user_input
        else:
            # 输入格式不正确
            await update.message.reply_text("❌ 输入格式不正确，请输入有效的域名或IP地址。")
            return
        
        # 检查是否已有file_key，如果没有则让用户选择文件
        if "file_key" not in user_states[user_id]:
            # 创建文件选择菜单
            keyboard = []
            for key, name in RULE_FILE_NAMES.items():
                keyboard.append([InlineKeyboardButton(name, callback_data=f"add:file:{key}")])

            reply_markup = InlineKeyboardMarkup(keyboard)
            await update.message.reply_text("🔽 请选择要添加到哪个规则文件:", reply_markup=reply_markup)
            return
        
        # 已有file_key，可以直接调用add_rule_and_commit
        await add_rule_and_commit(update, user_states[user_id], user_input)
        return

    # 验证输入是域名还是IP
    if is_valid_domain(user_input):
        input_type = "domain"
    elif is_valid_ip(user_input):
        input_type = "ip"
    else:
        # 创建功能按钮菜单
        keyboard = [
            [InlineKeyboardButton("➕ 添加规则", callback_data="action:add")],
            [InlineKeyboardButton("👁️ 查看规则", callback_data="action:view")],
            [InlineKeyboardButton("❌ 删除规则", callback_data="action:delete")],
            [InlineKeyboardButton("↔️ 移动规则", callback_data="action:move")],
            [InlineKeyboardButton("ℹ️ 帮助信息", callback_data="action:help")]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)

        await update.message.reply_text(
            "❌ 输入格式不正确，请输入有效的域名或IP地址。\n\n或者选择其他功能：",
            reply_markup=reply_markup
        )
        return

    # 保存用户输入和类型
    user_states[user_id] = {
        "input": user_input,
        "type": input_type,
        "action": "add"
    }

    # 创建文件选择菜单
    keyboard = []
    for key, name in RULE_FILE_NAMES.items():
        keyboard.append([InlineKeyboardButton(name, callback_data=f"add:file:{key}")])

    reply_markup = InlineKeyboardMarkup(keyboard)

    await update.message.reply_text("🔽 请选择要添加到哪个规则文件:", reply_markup=reply_markup)

async def view_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/view命令，查看规则"""
    # 检查权限
    if not await check_permission(update):
        await update.message.reply_text("❌ 对不起，您没有权限使用此机器人。")
        return
        
    user_id = update.effective_user.id
    user_states[user_id] = {"action": "view", "page": 0}

    keyboard = []
    for key, name in RULE_FILE_NAMES.items():
        keyboard.append([InlineKeyboardButton(name, callback_data=f"view:file:{key}")])

    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text("👁️ 请选择要查看的规则文件:", reply_markup=reply_markup)

async def delete_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/delete命令，删除规则"""
    # 检查权限
    if not await check_permission(update):
        await update.message.reply_text("❌ 对不起，您没有权限使用此机器人。")
        return
        
    user_id = update.effective_user.id
    user_states[user_id] = {"action": "delete"}

    keyboard = []
    for key, name in RULE_FILE_NAMES.items():
        keyboard.append([InlineKeyboardButton(name, callback_data=f"delete:file:{key}")])

    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text("❌ 请选择要从哪个规则文件中删除规则:", reply_markup=reply_markup)

async def move_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/move命令，移动规则"""
    # 检查权限
    if not await check_permission(update):
        await update.message.reply_text("❌ 对不起，您没有权限使用此机器人。")
        return
        
    user_id = update.effective_user.id
    user_states[user_id] = {"action": "move", "step": "select_source"}

    keyboard = []
    for key, name in RULE_FILE_NAMES.items():
        keyboard.append([InlineKeyboardButton(name, callback_data=f"move:source:{key}")])

    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text("↔️ 请选择源规则文件:", reply_markup=reply_markup)

async def get_repo():
    """获取或更新Git仓库"""
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
                # 修改这里的 pull 调用
                try:
                    origin.pull()
                except git.exc.GitCommandError as e:
                    if "Need to specify how to reconcile divergent branches" in str(e):
                        logger.warning("检测到分支分歧，强制重置到远程分支")
                        origin.fetch()
                        repo.git.reset('--hard', 'origin/main')
                    else:
                        raise e
        else:
            # 确保父目录存在
            os.makedirs(os.path.dirname(REPO_PATH), exist_ok=True)
            repo = git.Repo.clone_from(REPO_URL, REPO_PATH)
    else:
        repo = git.Repo(REPO_PATH)
        origin = repo.remotes.origin
        
        # 修改这里的 pull 调用，添加错误处理
        try:
            origin.pull()
        except git.exc.GitCommandError as e:
            if "Need to specify how to reconcile divergent branches" in str(e):
                logger.warning("检测到分支分歧，尝试不同的合并策略")
                try:
                    # 方法1: 尝试使用 rebase
                    logger.info("尝试使用 rebase 策略")
                    origin.pull(rebase=True)
                except git.exc.GitCommandError:
                    # 方法2: 如果 rebase 失败，强制重置到远程分支
                    logger.warning("rebase 失败，强制重置到远程分支")
                    origin.fetch()
                    # 获取当前分支名
                    current_branch = repo.active_branch.name
                    repo.git.reset('--hard', f'origin/{current_branch}')
            else:
                # 其他 Git 错误，重新抛出
                raise e

    # 配置 Git 用户信息（用于 commit）
    repo.config_writer().set_value("user", "name", "OpenClash Rule Bot").release()
    repo.config_writer().set_value("user", "email", "bot@openclash-rule-bot.local").release()

    return repo

async def get_rule_info(rule_name):
    """获取OpenClash规则的信息，包括ruleCount"""
    try:
        url = f"{OPENCLASH_API_URL}/providers/rules"
        headers = {"Authorization": f"Bearer {OPENCLASH_API_SECRET}"}
        response = requests.get(url, headers=headers)
        
        if response.status_code == 200:
            data = response.json()
            if 'providers' in data and rule_name in data['providers']:
                return data['providers'][rule_name]
        return None
    except Exception as e:
        logger.error(f"获取规则信息时发生错误: {str(e)}")
        return None

async def refresh_openclash_rule(file_path):
    """刷新OpenClash规则，使用新的API接口并验证更新"""
    update_message = ""
    max_retries = 30  # 最大重试次数
    retry_delay = 10  # 每次重试间隔秒数
    
    try:
        if file_path in OPENCLASH_RULE_MAPPING:
            rule_name = OPENCLASH_RULE_MAPPING[file_path]
            
            # 首先获取当前规则的信息
            before_update = await get_rule_info(rule_name)
            before_count = before_update.get('ruleCount', -1) if before_update else -1
            
            # 更新成功标志
            update_success = False
            
            # 进行多次尝试
            for attempt in range(max_retries):
                # 调用更新接口
                url = f"{OPENCLASH_API_URL}/providers/rules/{rule_name}"
                headers = {"Authorization": f"Bearer {OPENCLASH_API_SECRET}"}
                
                try:
                    response = requests.put(url, headers=headers)
                    
                    if response.status_code != 204:
                        # 如果API调用失败，记录错误并继续尝试
                        logger.warning(f"第 {attempt+1} 次刷新规则失败，状态码: {response.status_code}")
                        await asyncio.sleep(retry_delay)
                        continue
                except Exception as e:
                    logger.warning(f"第 {attempt+1} 次刷新规则请求异常: {str(e)}")
                    await asyncio.sleep(retry_delay)
                    continue
                
                # 等待一段时间让规则更新生效
                await asyncio.sleep(retry_delay)
                
                # 获取更新后的规则信息
                after_update = await get_rule_info(rule_name)
                after_count = after_update.get('ruleCount', -1) if after_update else -1
                
                # 检查ruleCount是否发生变化
                if after_update and after_count != before_count:
                    update_message = f"✅ 已成功刷新OpenClash规则: {rule_name} (规则数量: {after_count})"
                    update_success = True
                    break
                
                # 如果还没成功，继续下一次尝试（会再次调用更新接口）
                logger.info(f"第 {attempt+1} 次刷新尝试后，规则数量未变化，将重试...")
            
            # 如果所有尝试后仍未成功
            if not update_success:
                update_message = f"⚠️ 尝试了 {max_retries} 次更新后，OpenClash规则 {rule_name} 似乎未生效"
        else:
            update_message = "⚠️ 无法确定对应的OpenClash规则，未进行刷新"
    except Exception as e:
        logger.error(f"刷新OpenClash规则失败: {str(e)}")
        update_message = f"❌ 刷新规则时发生错误: {str(e)}"

    return update_message

def extract_rules_from_file(file_path):
    """从文件中提取规则，返回规则列表"""
    rules = []
    if not os.path.exists(file_path):
        return rules

    with open(file_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line and (line.startswith("DOMAIN-SUFFIX,") or line.startswith("IP-CIDR,")):
            # 查找前一行是否为注释
            comment = ""
            if i > 0 and lines[i-1].strip().startswith("#"):
                comment = lines[i-1].strip()

            # 提取规则值
            if line.startswith("DOMAIN-SUFFIX,"):
                value = line.split(",")[1]
                rule_type = "domain"
            elif line.startswith("IP-CIDR,"):
                value = line.split(",")[1]
                if "/32" in value:
                    value = value.replace("/32", "")
                rule_type = "ip"

            rules.append({
                "line": line,
                "value": value,
                "type": rule_type,
                "comment": comment,
                "line_index": i
            })
        i += 1

    return rules

async def refresh_all_rules(query):
    """刷新所有OpenClash规则，直接调用API不验证结果"""
    try:
        await query.edit_message_text("⏳ 正在刷新所有OpenClash规则...")

        # 获取仓库，确保是最新的
        await get_repo()
        
        # 先等待5秒确保GitHub完全同步
        await query.edit_message_text("⏳ 正在等待GitHub同步完成...")
        await asyncio.sleep(5)

        # 创建结果消息
        results = []

        # 依次刷新每个规则
        for file_key, file_path in RULE_FILES.items():
            if file_path in OPENCLASH_RULE_MAPPING:
                rule_name = OPENCLASH_RULE_MAPPING[file_path]
                display_name = RULE_FILE_NAMES[file_key]
                
                # 更新进度消息
                await query.edit_message_text(f"⏳ 正在刷新规则: {display_name}...")
                
                # 直接调用API，不验证结果
                url = f"{OPENCLASH_API_URL}/providers/rules/{rule_name}"
                headers = {"Authorization": f"Bearer {OPENCLASH_API_SECRET}"}
                
                try:
                    response = requests.put(url, headers=headers)
                    if response.status_code == 204:
                        results.append(f"{display_name}: ✅ 已刷新")
                    else:
                        results.append(f"{display_name}: ❌ 刷新失败，状态码: {response.status_code}")
                except Exception as e:
                    results.append(f"{display_name}: ❌ 刷新失败，错误: {str(e)}")

            # 更新进度消息
            progress_message = "⏳ 正在刷新所有OpenClash规则...\n\n"
            progress_message += "\n".join(results)
            await query.edit_message_text(progress_message)

        # 创建返回按钮
        keyboard = [[InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]]
        reply_markup = InlineKeyboardMarkup(keyboard)

        # 显示完成消息
        complete_message = "✅ 所有规则刷新完成！\n\n"
        complete_message += "\n".join(results)

        await query.edit_message_text(complete_message, reply_markup=reply_markup)

    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"刷新所有规则时发生错误: {str(e)}\n{error_details}")

        # 创建返回按钮
        keyboard = [[InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]]
        reply_markup = InlineKeyboardMarkup(keyboard)

        await query.edit_message_text(
            f"❌ 刷新规则失败: {str(e)}\n详细错误请查看日志。",
            reply_markup=reply_markup
        )

async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理按钮回调"""
    query = update.callback_query
    await query.answer()
    
    # 检查权限
    if not await check_permission(update):
        await query.edit_message_text("❌ 对不起，您没有权限使用此机器人。")
        return

    user_id = update.effective_user.id
    if user_id not in user_states and not query.data.startswith("action:") and not query.data.startswith("youtube_unlock:"):
        await query.edit_message_text("⏱️ 会话已过期，请重新开始。")
        return

    callback_data = query.data

    # 忽略页码指示器的点击
    if callback_data == "noop":
        return

    # 处理主菜单动作选择
    if callback_data.startswith("action:"):
        action = callback_data.split(":")[1]
        if action == "add":
            await query.edit_message_text("➕ 请直接发送要添加的域名或IP地址")
            user_states[user_id] = {"action": "add_waiting_input"}
            return
        elif action == "view":
            user_states[user_id] = {"action": "view", "page": 0}
            keyboard = []
            for key, name in RULE_FILE_NAMES.items():
                keyboard.append([InlineKeyboardButton(name, callback_data=f"view:file:{key}")])
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text("👁️ 请选择要查看的规则文件:", reply_markup=reply_markup)
            return
        elif action == "delete":
            user_states[user_id] = {"action": "delete"}
            keyboard = []
            for key, name in RULE_FILE_NAMES.items():
                keyboard.append([InlineKeyboardButton(name, callback_data=f"delete:file:{key}")])
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text("❌ 请选择要从哪个规则文件中删除规则:", reply_markup=reply_markup)
            return
        elif action == "move":
            user_states[user_id] = {"action": "move", "step": "select_source"}
            keyboard = []
            for key, name in RULE_FILE_NAMES.items():
                keyboard.append([InlineKeyboardButton(name, callback_data=f"move:source:{key}")])
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text("↔️ 请选择源规则文件:", reply_markup=reply_markup)
            return
        elif action == "refresh_all":
            # 调用刷新所有规则的函数
            await refresh_all_rules(query)
            return
        elif action == "help":
            # 调用帮助命令逻辑
            keyboard = [[InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]]
            reply_markup = InlineKeyboardMarkup(keyboard)

            await query.edit_message_text(
                "📖 *OpenClash规则管理机器人使用指南*\n\n"
                "📌 *基本操作：*\n\n"
                "➕ *添加规则：*\n"
                "- 直接发送域名或IP地址\n"
                "- 选择要添加到哪个规则文件\n"
                "- 机器人将自动添加规则并更新\n\n"
                "👁️ *查看规则：*\n"
                "- 使用 /view 命令\n"
                "- 选择要查看的规则文件\n"
                "- 使用分页浏览规则内容\n\n"
                "❌ *删除规则：*\n"
                "- 使用 /delete 命令\n"
                "- 选择规则文件并选择要删除的规则\n"
                "- 确认删除后机器人将更新规则\n\n"
                "↔️ *移动规则：*\n"
                "- 使用 /move 命令\n"
                "- 选择源规则文件并选择要移动的规则\n"
                "- 选择目标规则文件完成移动\n\n"
                "🔄 *更新全部规则：*\n"
                "- 点击更新全部规则按钮\n"
                "- 机器人会依次刷新所有OpenClash规则\n\n"
                "📋 *支持的规则文件：*\n"
                "• 🏠 直连规则 (Custom_Direct_my.list)\n"
                "• 🎬 Emby代理规则 (Custom_Proxy_Emby.list)\n"
                "• 💬 社交媒体代理规则 (Custom_Proxy_Media.list)\n"
                "• 🇬 谷歌与AI代理规则 (Custom_Proxy_Google.list)\n\n"
                "🧹 *清空连接：*\n"
                "- 点击清空连接按钮\n"
                "- 机器人会调用OpenClash API清空所有当前连接\n\n"
                "🔁 *循环清理：*\n"
                "- 点击启动循环清理按钮后，机器人会立即尝试清空一次连接，并每10秒自动清空一次\n"
                "- 点击关闭循环清理按钮后，停止定时调用OpenClash API",
                parse_mode='Markdown',
                reply_markup=reply_markup
            )
            return
        elif action == "start":
            # 返回主菜单，清除用户状态
            user_states.pop(user_id, None)

            keyboard = [
                [InlineKeyboardButton("➕ 添加规则", callback_data="action:add")],
                [InlineKeyboardButton("👁️ 查看规则", callback_data="action:view")],
                [InlineKeyboardButton("❌ 删除规则", callback_data="action:delete")],
                [InlineKeyboardButton("↔️ 移动规则", callback_data="action:move")],
                [InlineKeyboardButton("🔄 更新全部规则", callback_data="action:refresh_all")],
                [InlineKeyboardButton("🧹 清空连接", callback_data="action:clear_connections")],
                [
                    InlineKeyboardButton("▶️ 启动循环清理", callback_data="action:start_loop_clear_connections"),
                    InlineKeyboardButton("⏹️ 关闭循环清理", callback_data="action:stop_loop_clear_connections")
                ],
                [InlineKeyboardButton("ℹ️ 帮助信息", callback_data="action:help")],
                [InlineKeyboardButton("📺 测试油管解锁", callback_data="action:youtube_unlock")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)

            await query.edit_message_text(
                f"🚀 *欢迎使用 OpenClash 规则管理机器人！*\n\n"
                "✨ *功能简介：*\n"
                "此机器人可以帮您管理OpenClash规则，支持添加、查看、删除和移动规则。\n\n"
                "请选择您要执行的操作：\n"
                "或者使用 /help 查看详细使用说明",
                parse_mode='Markdown',
                reply_markup=reply_markup
            )
            return
        elif action == "search":
            user_states[user_id] = {"action": "search_waiting"}
            await query.edit_message_text("🔍 请输入要搜索的域名或IP地址关键词：")
            return
        elif action == "clear_connections":
            await clear_connections(query)
            return
        elif action == "start_loop_clear_connections":
            await start_loop_clear_connections(query, user_id)
            return
        elif action == "stop_loop_clear_connections":
            await stop_loop_clear_connections(query, user_id)
            return
        elif action == "youtube_unlock":
            await show_youtube_unlock_options(query)
            return
    # 添加规则
    elif callback_data.startswith("add:file:"):
        file_key = callback_data.split(":")[2]
        if file_key in RULE_FILES:
            user_states[user_id]["file_key"] = file_key
            file_path = RULE_FILES[file_key]
            await add_rule_and_commit(query, user_states[user_id], file_path)
        else:
            await query.edit_message_text("❌ 无效的文件选择，请重新操作。")

    # 查看规则
    elif callback_data.startswith("view:"):
        parts = callback_data.split(":")
        if parts[1] == "file":
            file_key = parts[2]
            if file_key in RULE_FILES:
                file_path = RULE_FILES[file_key]
                user_states[user_id]["viewing_file"] = file_path
                user_states[user_id]["page"] = 0
                await show_rules_page(query, user_id, file_path, 0)
            else:
                await query.edit_message_text("❌ 无效的文件选择，请重新操作。")
        elif parts[1] == "page":
            if "viewing_file" not in user_states[user_id]:
                await query.edit_message_text("❌ 会话状态错误，请重新开始。")
                return
                
            file_path = user_states[user_id]["viewing_file"]
            try:
                page = int(parts[2])
                user_states[user_id]["page"] = page
                await show_rules_page(query, user_id, file_path, page)
            except (ValueError, IndexError):
                await query.edit_message_text("❌ 无效的页码，请重新操作。")

    # 删除规则
    elif callback_data.startswith("delete:"):
        parts = callback_data.split(":")
        if parts[1] == "file":
            file_key = parts[2]
            if file_key in RULE_FILES:
                file_path = RULE_FILES[file_key]
                user_states[user_id]["deleting_file"] = file_path
                user_states[user_id]["page"] = 0
                await show_deletable_rules(query, user_id, file_path, 0)
            else:
                await query.edit_message_text("❌ 无效的文件选择，请重新操作。")
        elif parts[1] == "page":
            if "deleting_file" not in user_states[user_id]:
                await query.edit_message_text("❌ 会话状态错误，请重新开始。")
                return
                
            file_path = user_states[user_id]["deleting_file"]
            try:
                page = int(parts[2])
                user_states[user_id]["page"] = page
                await show_deletable_rules(query, user_id, file_path, page)
            except (ValueError, IndexError):
                await query.edit_message_text("❌ 无效的页码，请重新操作。")
        elif parts[1] == "rule":
            if "deleting_file" not in user_states[user_id]:
                await query.edit_message_text("❌ 会话状态错误，请重新开始。")
                return
                
            file_path = user_states[user_id]["deleting_file"]
            try:
                rule_index = int(parts[2])
                await confirm_delete_rule(query, user_id, file_path, rule_index)
            except (ValueError, IndexError):
                await query.edit_message_text("❌ 无效的规则索引，请重新操作。")
        elif parts[1] == "confirm":
            if "deleting_file" not in user_states[user_id]:
                await query.edit_message_text("❌ 会话状态错误，请重新开始。")
                return
                
            file_path = user_states[user_id]["deleting_file"]
            try:
                rule_index = int(parts[2])
                action = parts[3]
                if action == "yes":
                    await delete_rule_and_commit(query, user_id, file_path, rule_index)
                else:
                    # 返回规则列表
                    page = user_states[user_id].get("page", 0)
                    await show_deletable_rules(query, user_id, file_path, page)
            except (ValueError, IndexError):
                await query.edit_message_text("❌ 无效的操作参数，请重新操作。")

    # 移动规则
    elif callback_data.startswith("move:"):
        parts = callback_data.split(":")
        if parts[1] == "source":
            source_key = parts[2]
            if source_key in RULE_FILES:
                source_path = RULE_FILES[source_key]
                user_states[user_id]["source_file"] = source_path
                user_states[user_id]["page"] = 0
                user_states[user_id]["step"] = "select_rule"
                await show_movable_rules(query, user_id, source_path, 0)
            else:
                await query.edit_message_text("❌ 无效的文件选择，请重新操作。")
        elif parts[1] == "page":
            if "source_file" not in user_states[user_id]:
                await query.edit_message_text("❌ 会话状态错误，请重新开始。")
                return
                
            source_path = user_states[user_id]["source_file"]
            try:
                page = int(parts[2])
                user_states[user_id]["page"] = page
                await show_movable_rules(query, user_id, source_path, page)
            except (ValueError, IndexError):
                await query.edit_message_text("❌ 无效的页码，请重新操作。")
        elif parts[1] == "rule":
            if "source_file" not in user_states[user_id] or user_states[user_id].get("step") != "select_rule":
                await query.edit_message_text("❌ 会话状态错误，请重新开始。")
                return
                
            source_path = user_states[user_id]["source_file"]
            try:
                rule_index = int(parts[2])
                user_states[user_id]["rule_index"] = rule_index
                user_states[user_id]["step"] = "select_target"

                # 显示目标文件选择菜单（不包括当前源文件）
                keyboard = []
                source_key = next((k for k, v in RULE_FILES.items() if v == source_path), None)
                for key, name in RULE_FILE_NAMES.items():
                    if key != source_key:  # 排除源文件
                        keyboard.append([InlineKeyboardButton(name, callback_data=f"move:target:{key}")])
                keyboard.append([InlineKeyboardButton("↩️ 返回", callback_data=f"move:cancel")])
                reply_markup = InlineKeyboardMarkup(keyboard)

                # 获取规则信息用于显示
                full_path = os.path.join(REPO_PATH, source_path)
                if not os.path.exists(full_path):
                    await query.edit_message_text(f"❌ 源文件 {os.path.basename(source_path)} 不存在。")
                    return
                    
                rules = extract_rules_from_file(full_path)
                if rule_index >= len(rules):
                    await query.edit_message_text("❌ 规则索引无效，请重新操作。")
                    return
                    
                rule_info = rules[rule_index]

                await query.edit_message_text(
                    f"↔️ 请选择要将规则移动到哪个文件：\n\n"
                    f"当前规则：{rule_info['value']}\n"
                    f"当前文件：{os.path.basename(source_path)}",
                    reply_markup=reply_markup
                )
            except (ValueError, IndexError):
                await query.edit_message_text("❌ 无效的规则索引，请重新操作。")
        elif parts[1] == "target":
            if "source_file" not in user_states[user_id] or "rule_index" not in user_states[user_id] or user_states[user_id].get("step") != "select_target":
                await query.edit_message_text("❌ 会话状态错误，请重新开始。")
                return
                
            target_key = parts[2]
            if target_key in RULE_FILES:
                target_path = RULE_FILES[target_key]
                user_states[user_id]["target_file"] = target_path
                await move_rule_and_commit(query, user_id)
            else:
                await query.edit_message_text("❌ 无效的文件选择，请重新操作。")
        elif parts[1] == "cancel":
            # 返回源文件的规则列表
            if "source_file" not in user_states[user_id]:
                await query.edit_message_text("❌ 会话状态错误，请重新开始。")
                return
                
            source_path = user_states[user_id]["source_file"]
            page = user_states[user_id].get("page", 0)
            user_states[user_id]["step"] = "select_rule"
            await show_movable_rules(query, user_id, source_path, page)

    # 油管解锁测试
    elif callback_data.startswith("youtube_unlock:"):
        parts = callback_data.split(":")
        if parts[1] == "test":
            provider = parts[2]
            await run_youtube_unlock_test(query, provider)
        elif parts[1] == "update_rule":
            provider = parts[2]
            await update_youtube_cn_rule(query, provider)

async def show_rules_page(query, user_id, file_path, page):
    """显示规则文件的内容（分页）"""
    try:
        await query.edit_message_text("⏳ 正在加载规则...")

        # 获取仓库
        await get_repo()

        # 检查文件是否存在
        full_path = os.path.join(REPO_PATH, file_path)
        if not os.path.exists(full_path):
            await query.edit_message_text(f"⚠️ 规则文件 {os.path.basename(file_path)} 不存在。")
            return

        # 提取规则
        rules = extract_rules_from_file(full_path)

        if not rules:
            # 如果没有规则
            keyboard = [[InlineKeyboardButton("🏠 返回主菜单", callback_data="action:view")]]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text(
                f"📋 {os.path.basename(file_path)}\n\n"
                f"此规则文件为空或没有有效的规则。",
                reply_markup=reply_markup
            )
            return

        # 计算分页
        total_pages = (len(rules) + RULES_PER_PAGE - 1) // RULES_PER_PAGE
        start_idx = page * RULES_PER_PAGE
        end_idx = min(start_idx + RULES_PER_PAGE, len(rules))
        current_rules = rules[start_idx:end_idx]

        # 构建规则显示文本
        rules_text = f"📋 {os.path.basename(file_path)} ({len(rules)}条规则)\n\n"
        for i, rule in enumerate(current_rules, start=start_idx + 1):
            value = rule["value"]
            rules_text += f"{i}. {value}\n"

        # 构建分页按钮
        keyboard = build_pagination_buttons(page, total_pages, "view:page")
        keyboard.append([InlineKeyboardButton("🏠 返回主菜单", callback_data="action:view")])
        reply_markup = InlineKeyboardMarkup(keyboard)

        # 显示规则
        await query.edit_message_text(
            f"{rules_text}\n页码: {page+1}/{total_pages}",
            reply_markup=reply_markup
        )

    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"显示规则时发生错误: {str(e)}\n{error_details}")
        await query.edit_message_text(f"❌ 显示规则失败: {str(e)}\n详细错误请查看日志。")

async def show_deletable_rules(query, user_id, file_path, page):
    """显示可删除的规则列表"""
    try:
        await query.edit_message_text("⏳ 正在加载规则...")

        # 获取仓库
        await get_repo()

        # 检查文件是否存在
        full_path = os.path.join(REPO_PATH, file_path)
        if not os.path.exists(full_path):
            await query.edit_message_text(f"⚠️ 规则文件 {os.path.basename(file_path)} 不存在。")
            return

        # 提取规则
        rules = extract_rules_from_file(full_path)

        if not rules:
            # 如果没有规则
            keyboard = [[InlineKeyboardButton("🏠 返回主菜单", callback_data="action:delete")]]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text(
                f"📋 {os.path.basename(file_path)}\n\n"
                f"此规则文件为空或没有有效的规则。",
                reply_markup=reply_markup
            )
            return

        # 计算分页
        total_pages = (len(rules) + RULES_PER_PAGE - 1) // RULES_PER_PAGE
        start_idx = page * RULES_PER_PAGE
        end_idx = min(start_idx + RULES_PER_PAGE, len(rules))
        current_rules = rules[start_idx:end_idx]

        # 构建规则显示文本
        rules_text = f"📋 {os.path.basename(file_path)} ({len(rules)}条规则)\n"
        rules_text += "请选择要删除的规则：\n\n"

        # 构建规则选择按钮
        keyboard = []
        for i, rule in enumerate(current_rules):
            rule_idx = start_idx + i
            value = rule["value"]
            keyboard.append([InlineKeyboardButton(f"{rule_idx+1}. {value}", callback_data=f"delete:rule:{rule_idx}")])

        # 构建分页按钮
        keyboard.extend(build_pagination_buttons(page, total_pages, "delete:page"))
        keyboard.append([InlineKeyboardButton("🏠 返回主菜单", callback_data="action:delete")])
        reply_markup = InlineKeyboardMarkup(keyboard)

        # 显示规则
        await query.edit_message_text(
            f"{rules_text}页码: {page+1}/{total_pages}",
            reply_markup=reply_markup
        )

    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"显示可删除规则时发生错误: {str(e)}\n{error_details}")
        await query.edit_message_text(f"❌ 显示规则失败: {str(e)}\n详细错误请查看日志。")

async def confirm_delete_rule(query, user_id, file_path, rule_index):
    """确认删除规则"""
    try:
        # 获取仓库
        await get_repo()

        # 获取规则信息
        full_path = os.path.join(REPO_PATH, file_path)
        rules = extract_rules_from_file(full_path)

        if rule_index >= len(rules):
            await query.edit_message_text("❌ 规则索引无效，请重新操作。")
            return

        rule = rules[rule_index]

        # 创建确认按钮
        keyboard = [
            [
                InlineKeyboardButton("✅ 确认删除", callback_data=f"delete:confirm:{rule_index}:yes"),
                InlineKeyboardButton("❌ 取消", callback_data=f"delete:confirm:{rule_index}:no")
            ]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)

        # 显示确认信息
        await query.edit_message_text(
            f"⚠️ 确认删除以下规则？\n\n"
            f"规则值: {rule['value']}\n"
            f"规则类型: {rule['type']}\n"
            f"所在文件: {os.path.basename(file_path)}\n\n"
            f"此操作不可撤销！",
            reply_markup=reply_markup
        )

    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"确认删除规则时发生错误: {str(e)}\n{error_details}")
        await query.edit_message_text(f"❌ 操作失败: {str(e)}\n详细错误请查看日志。")

async def delete_rule_and_commit(query, user_id, file_path, rule_index):
    """删除规则并提交到Git仓库"""
    try:
        await query.edit_message_text("⏳ 正在删除规则...")

        # 获取仓库
        repo = await get_repo()

        # 检查文件路径和规则索引是否有效
        if not file_path or not isinstance(rule_index, int):
            await query.edit_message_text("❌ 无效的文件路径或规则索引。")
            return

        # 获取规则信息
        full_path = os.path.join(REPO_PATH, file_path)
        
        # 检查文件是否存在
        if not os.path.exists(full_path):
            await query.edit_message_text(f"❌ 规则文件 {os.path.basename(file_path)} 不存在。")
            return
            
        rules = extract_rules_from_file(full_path)

        if rule_index >= len(rules):
            await query.edit_message_text("❌ 规则索引无效，请重新操作。")
            return

        rule = rules[rule_index]
        rule_value = rule["value"]

        # 读取文件内容
        with open(full_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()

        # 删除规则行和关联的注释行
        line_index = rule["line_index"]
        lines_to_remove = []
        lines_to_remove.append(line_index)  # 添加规则行

        # 如果前一行是注释，也将其删除
        if line_index > 0 and lines[line_index-1].strip().startswith("#"):
            lines_to_remove.append(line_index-1)

        # 从大到小排序，以确保删除时索引不会变化
        lines_to_remove.sort(reverse=True)

        for idx in lines_to_remove:
            del lines[idx]

        # 写回文件
        with open(full_path, 'w', encoding='utf-8') as f:
            f.writelines(lines)

        # 提交并推送更改
        repo.git.add(file_path)
        repo.git.commit('-m', f'删除规则: {rule_value} 从 {os.path.basename(file_path)}')
        origin = repo.remotes.origin
        origin.push()

        # 等待GitHub同步
        message_template = f"✅ 已从 {os.path.basename(file_path)} 中删除规则: {rule_value}\n\n⏳ 正在等待GitHub同步更新 ({{wait_time}}秒)..."
        await wait_for_github_sync(query, message_template, repo, repo.head.commit.hexsha)

        # 更新OpenClash规则
        await query.edit_message_text(f"✅ 已从 {os.path.basename(file_path)} 中删除规则: {rule_value}\n\n🔄 正在更新OpenClash规则...")
        update_message = await refresh_openclash_rule(file_path)

        # 显示完成信息
        keyboard = [[InlineKeyboardButton("🔄 查看更新后的规则", callback_data=f"delete:file:{next((k for k, v in RULE_FILES.items() if v == file_path), None)}")]]
        keyboard.append([InlineKeyboardButton("🏠 返回主菜单", callback_data="action:delete")])
        reply_markup = InlineKeyboardMarkup(keyboard)

        await query.edit_message_text(
            f"✅ 已从 {os.path.basename(file_path)} 中删除规则: {rule_value}\n\n{update_message}",
            reply_markup=reply_markup
        )

    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"删除规则时发生错误: {str(e)}\n{error_details}")
        await query.edit_message_text(f"❌ 删除规则失败: {str(e)}\n详细错误请查看日志。")

async def show_movable_rules(query, user_id, file_path, page):
    """显示可移动的规则列表"""
    try:
        await query.edit_message_text("⏳ 正在加载规则...")

        # 获取仓库
        await get_repo()

        # 检查文件是否存在
        full_path = os.path.join(REPO_PATH, file_path)
        if not os.path.exists(full_path):
            await query.edit_message_text(f"⚠️ 规则文件 {os.path.basename(file_path)} 不存在。")
            return

        # 提取规则
        rules = extract_rules_from_file(full_path)

        if not rules:
            # 如果没有规则
            keyboard = [[InlineKeyboardButton("🏠 返回主菜单", callback_data="action:move")]]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text(
                f"📋 {os.path.basename(file_path)}\n\n"
                f"此规则文件为空或没有有效的规则。",
                reply_markup=reply_markup
            )
            return

        # 计算分页
        total_pages = (len(rules) + RULES_PER_PAGE - 1) // RULES_PER_PAGE
        start_idx = page * RULES_PER_PAGE
        end_idx = min(start_idx + RULES_PER_PAGE, len(rules))
        current_rules = rules[start_idx:end_idx]

        # 构建规则显示文本
        rules_text = f"📋 {os.path.basename(file_path)} ({len(rules)}条规则)\n"
        rules_text += "请选择要移动的规则：\n\n"

        # 构建规则选择按钮
        keyboard = []
        for i, rule in enumerate(current_rules):
            rule_idx = start_idx + i
            value = rule["value"]
            keyboard.append([InlineKeyboardButton(f"{rule_idx+1}. {value}", callback_data=f"move:rule:{rule_idx}")])

        # 构建分页按钮
        keyboard.extend(build_pagination_buttons(page, total_pages, "move:page"))
        keyboard.append([InlineKeyboardButton("🏠 返回主菜单", callback_data="action:move")])
        reply_markup = InlineKeyboardMarkup(keyboard)

        # 显示规则
        await query.edit_message_text(
            f"{rules_text}页码: {page+1}/{total_pages}",
            reply_markup=reply_markup
        )

    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"显示可移动规则时发生错误: {str(e)}\n{error_details}")
        await query.edit_message_text(f"❌ 显示规则失败: {str(e)}\n详细错误请查看日志。")

async def move_rule_and_commit(query, user_id):
    """移动规则并提交到Git仓库"""
    try:
        await query.edit_message_text("⏳ 正在移动规则...")

        # 获取仓库
        repo = await get_repo()

        # 检查用户状态中是否包含所需的所有键
        required_keys = ["source_file", "target_file", "rule_index"]
        missing_keys = [key for key in required_keys if key not in user_states[user_id]]
        if missing_keys:
            await query.edit_message_text(f"❌ 操作失败：缺少必要信息 {', '.join(missing_keys)}")
            return

        # 获取源文件和目标文件
        source_path = user_states[user_id]["source_file"]
        target_path = user_states[user_id]["target_file"]
        rule_index = user_states[user_id]["rule_index"]

        # 获取规则信息
        source_full_path = os.path.join(REPO_PATH, source_path)
        target_full_path = os.path.join(REPO_PATH, target_path)

        rules = extract_rules_from_file(source_full_path)

        if rule_index >= len(rules):
            await query.edit_message_text("❌ 规则索引无效，请重新操作。")
            return

        rule = rules[rule_index]
        rule_value = rule["value"]

        # 从源文件删除规则
        with open(source_full_path, 'r', encoding='utf-8') as f:
            source_lines = f.readlines()

        # 删除规则行和关联的注释行
        line_index = rule["line_index"]
        lines_to_remove = []
        lines_to_remove.append(line_index)  # 添加规则行

        # 获取注释（如果有）
        comment = ""
        if line_index > 0 and source_lines[line_index-1].strip().startswith("#"):
            comment = source_lines[line_index-1].strip()
            lines_to_remove.append(line_index-1)

        # 从大到小排序，以确保删除时索引不会变化
        lines_to_remove.sort(reverse=True)

        for idx in lines_to_remove:
            del source_lines[idx]

        # 写回源文件
        with open(source_full_path, 'w', encoding='utf-8') as f:
            f.writelines(source_lines)

        # 添加到目标文件
        # 确保目标目录存在
        os.makedirs(os.path.dirname(target_full_path), exist_ok=True)

        # 生成规则行
        if rule["type"] == "domain":
            rule_line = f"DOMAIN-SUFFIX,{rule_value}\n"
            if not comment:
                comment = f"# 添加域名 {rule_value}"
        else:  # IP
            rule_line = f"IP-CIDR,{rule_value}/32,no-resolve\n"
            if not comment:
                comment = f"# 添加IP {rule_value}"

        # 检查规则是否已经存在于目标文件
        rule_exists = False
        if os.path.exists(target_full_path):
            with open(target_full_path, 'r', encoding='utf-8') as f:
                content = f.read()
                if rule_line in content:
                    rule_exists = True

        if rule_exists:
            # 如果规则已存在于目标文件，撤销源文件的更改
            repo.git.checkout('--', source_full_path)
            await query.edit_message_text(f"⚠️ 规则 '{rule_value}' 已存在于目标文件中，移动操作已取消。")
            return

        # 追加规则到目标文件
        with open(target_full_path, 'a', encoding='utf-8') as f:
            f.write(f"\n{comment}\n{rule_line}")

        # 提交并推送更改
        repo.git.add([source_path, target_path])
        repo.git.commit('-m', f'移动规则: {rule_value} 从 {os.path.basename(source_path)} 到 {os.path.basename(target_path)}')
        origin = repo.remotes.origin
        origin.push()

        # 等待GitHub同步
        message_template = f"✅ 已将规则 {rule_value} 从 {os.path.basename(source_path)} 移动到 {os.path.basename(target_path)}\n\n⏳ 正在等待GitHub同步更新 ({{wait_time}}秒)..."
        await wait_for_github_sync(query, message_template, repo, repo.head.commit.hexsha)

        # 更新OpenClash规则
        await query.edit_message_text(
            f"✅ 已将规则 {rule_value} 从 {os.path.basename(source_path)} 移动到 {os.path.basename(target_path)}\n\n"
            f"🔄 正在更新OpenClash规则..."
        )

        # 更新两个受影响的规则
        source_update = await refresh_openclash_rule(source_path)
        target_update = await refresh_openclash_rule(target_path)

        # 显示完成信息
        keyboard = [[InlineKeyboardButton("🏠 返回主菜单", callback_data="action:move")]]
        reply_markup = InlineKeyboardMarkup(keyboard)

        await query.edit_message_text(
            f"✅ 已将规则 {rule_value} 从 {os.path.basename(source_path)} 移动到 {os.path.basename(target_path)}\n\n"
            f"源文件更新: {source_update}\n"
            f"目标文件更新: {target_update}",
            reply_markup=reply_markup
        )

    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"移动规则时发生错误: {str(e)}\n{error_details}")
        await query.edit_message_text(f"❌ 移动规则失败: {str(e)}\n详细错误请查看日志。")

async def add_rule_and_commit(query, user_data, file_path):
    """添加规则到文件并提交到Git仓库"""
    # 根据调用来源确定参数类型
    is_from_callback = hasattr(query, 'edit_message_text')
    
    # 严格检查参数是否有效
    if not user_data or not isinstance(user_data, dict):
        error_message = "❌ 内部错误：无效的用户数据。"
        if is_from_callback:
            await query.edit_message_text(error_message)
        else:
            await query.message.reply_text(error_message)
        return
        
    # 确定文件路径和输入值
    if isinstance(file_path, str) and (file_path in RULE_FILES.values()):
        # 如果第三个参数是文件路径（来自回调查询）
        if "input" not in user_data or "type" not in user_data:
            error_message = "❌ 内部错误：缺少输入数据或类型信息。"
            if is_from_callback:
                await query.edit_message_text(error_message)
            else:
                await query.message.reply_text(error_message)
            return
        
        input_value = user_data["input"]
        input_type = user_data["type"]
    else:
        # 如果第三个参数是用户输入（来自直接消息）
        input_value = file_path
        input_type = user_data.get("type")
        
        if not input_type:
            error_message = "❌ 内部错误：缺少输入类型信息。"
            if is_from_callback:
                await query.edit_message_text(error_message)
            else:
                await query.message.reply_text(error_message)
            return
            
        # 检查是否有file_key
        if "file_key" not in user_data:
            error_message = "❌ 内部错误：缺少文件键信息。"
            if is_from_callback:
                await query.edit_message_text(error_message)
            else:
                await query.message.reply_text(error_message)
            return
            
        # 找到用户选择的文件
        file_key = user_data["file_key"]
        if file_key not in RULE_FILES:
            error_message = f"❌ 内部错误：无效的文件键 '{file_key}'。"
            if is_from_callback:
                await query.edit_message_text(error_message)
            else:
                await query.message.reply_text(error_message)
            return
            
        file_path = RULE_FILES[file_key]

    try:
        # 获取仓库
        repo = await get_repo()
        
        # 根据调用来源选择显示消息的方法
        if is_from_callback:
            await query.edit_message_text("🔄 正在更新仓库...")
        else:
            await query.message.reply_text("🔄 正在更新仓库...")

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
            if is_from_callback:
                await query.edit_message_text(f"ℹ️ 规则 '{input_value}' 已存在于文件中，无需添加。")
            else:
                await query.message.reply_text(f"ℹ️ 规则 '{input_value}' 已存在于文件中，无需添加。")
            return

        # 追加规则到文件
        with open(full_path, 'a', encoding='utf-8') as f:
            f.write(f"\n{comment}\n{rule_line}")

        # 提交并推送更改
        repo.git.add(file_path)
        repo.git.commit('-m', f'添加规则: {input_value} 到 {os.path.basename(file_path)}')
        commit_hash = repo.head.commit.hexsha
        origin = repo.remotes.origin
        origin.push()

        # 等待GitHub同步
        message_template = f"✅ 成功！\n\n'{input_value}' 已添加到 {os.path.basename(file_path)} 并推送到仓库。\n\n⏳ 正在等待GitHub同步更新 ({{wait_time}}秒)..."
        
        if is_from_callback:
            await wait_for_github_sync(query, message_template, repo, commit_hash)
            # 更新OpenClash规则
            await query.edit_message_text(f"✅ 成功！\n\n'{input_value}' 已添加到 {os.path.basename(file_path)} 并推送到仓库。\n\n🔄 正在更新OpenClash规则...")
            update_message = await refresh_openclash_rule(file_path)
            
            # 创建返回主菜单按钮
            keyboard = [[InlineKeyboardButton("🏠 返回主菜单", callback_data="action:add")]]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await query.edit_message_text(
                f"✅ 成功！\n\n'{input_value}' 已添加到 {os.path.basename(file_path)} 并推送到仓库。\n\n{update_message}",
                reply_markup=reply_markup
            )
        else:
            # 为直接消息方式创建一个临时消息对象
            temp_message = await query.message.reply_text(message_template.format(wait_time=60))
            
            # 手动等待GitHub同步，而不使用wait_for_github_sync函数
            await asyncio.sleep(20)  # 给GitHub一些时间来同步
            
            # 更新OpenClash规则
            await temp_message.edit_text(f"✅ 成功！\n\n'{input_value}' 已添加到 {os.path.basename(file_path)} 并推送到仓库。\n\n🔄 正在更新OpenClash规则...")
            update_message = await refresh_openclash_rule(file_path)
            
            # 创建返回主菜单按钮
            keyboard = [[InlineKeyboardButton("🏠 返回主菜单", callback_data="action:add")]]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await temp_message.edit_text(
                f"✅ 成功！\n\n'{input_value}' 已添加到 {os.path.basename(file_path)} 并推送到仓库。\n\n{update_message}",
                reply_markup=reply_markup
            )

    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"发生错误: {str(e)}\n{error_details}")
        error_message = f"❌ 操作失败: {str(e)}\n详细错误请查看日志。"
        
        if is_from_callback:
            await query.edit_message_text(error_message)
        else:
            await query.message.reply_text(error_message)

async def search_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/search命令，搜索规则"""
    # 检查权限
    if not await check_permission(update):
        await update.message.reply_text("❌ 对不起，您没有权限使用此机器人。")
        return
        
    user_id = update.effective_user.id
    user_states[user_id] = {"action": "search_waiting"}
    
    await update.message.reply_text("🔍 请输入要搜索的域名或IP地址关键词:")

def build_connection_control_keyboard():
    """构建连接清理相关操作按钮"""
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("▶️ 启动循环清理", callback_data="action:start_loop_clear_connections"),
            InlineKeyboardButton("⏹️ 关闭循环清理", callback_data="action:stop_loop_clear_connections")
        ],
        [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
    ])

async def request_clear_connections():
    """调用OpenClash API清空当前所有连接"""
    url = f"{OPENCLASH_API_URL}/connections"
    headers = {"Authorization": f"Bearer {OPENCLASH_API_SECRET}"}
    response = await asyncio.to_thread(
        requests.delete,
        url,
        headers=headers,
        timeout=10
    )
    return response.status_code

async def clear_connections(query):
    """清空当前所有连接"""
    try:
        await query.edit_message_text("⏳ 正在清空连接...")
        reply_markup = build_connection_control_keyboard()
        
        try:
            status_code = await request_clear_connections()
            
            if status_code == 204:
                await query.edit_message_text(
                    "✅ 已成功清空所有连接！",
                    reply_markup=reply_markup
                )
            else:
                await query.edit_message_text(
                    f"❌ 清空连接失败，状态码: {status_code}",
                    reply_markup=reply_markup
                )
        except Exception as e:
            logger.error(f"清空连接时发生错误: {str(e)}")
            await query.edit_message_text(
                f"❌ 清空连接失败: {str(e)}",
                reply_markup=reply_markup
            )
            
    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"清空连接时发生错误: {str(e)}\n{error_details}")
        
        await query.edit_message_text(
            f"❌ 操作失败: {str(e)}",
            reply_markup=build_connection_control_keyboard()
        )

async def loop_clear_connections(user_id):
    """按固定间隔循环清空连接"""
    try:
        while True:
            try:
                status_code = await request_clear_connections()
                if status_code == 204:
                    logger.info(f"用户 {user_id} 的循环清理已成功清空连接")
                else:
                    logger.warning(f"用户 {user_id} 的循环清理失败，状态码: {status_code}")
            except Exception as e:
                logger.error(f"用户 {user_id} 的循环清理发生错误: {str(e)}")

            await asyncio.sleep(LOOP_CLEAR_INTERVAL_SECONDS)
    except asyncio.CancelledError:
        logger.info(f"用户 {user_id} 的循环清理任务已取消")
        raise
    finally:
        current_task = asyncio.current_task()
        if loop_clear_tasks.get(user_id) is current_task:
            loop_clear_tasks.pop(user_id, None)

async def start_loop_clear_connections(query, user_id):
    """启动循环清理连接"""
    existing_task = loop_clear_tasks.get(user_id)
    if existing_task and not existing_task.done():
        await query.edit_message_text(
            f"ℹ️ 循环清理已在运行中，每 {LOOP_CLEAR_INTERVAL_SECONDS} 秒自动清空连接。",
            reply_markup=build_connection_control_keyboard()
        )
        return

    task = asyncio.create_task(loop_clear_connections(user_id))
    loop_clear_tasks[user_id] = task

    await query.edit_message_text(
        f"✅ 已启动循环清理。\n\n"
        f"机器人会立即尝试清空一次连接，之后每 {LOOP_CLEAR_INTERVAL_SECONDS} 秒自动清空一次。",
        reply_markup=build_connection_control_keyboard()
    )

async def stop_loop_clear_connections(query, user_id):
    """关闭循环清理连接"""
    task = loop_clear_tasks.pop(user_id, None)
    if task and not task.done():
        task.cancel()
        await query.edit_message_text(
            "✅ 已关闭循环清理。",
            reply_markup=build_connection_control_keyboard()
        )
        return

    await query.edit_message_text(
        "ℹ️ 循环清理当前未运行。",
        reply_markup=build_connection_control_keyboard()
    )

# 油管解锁测试相关配置
YOUTUBE_UNLOCK_DEFAULT_PROVIDER = "全部"
YOUTUBE_UNLOCK_PROVIDERS = {
    "全部": "http://192.168.6.1:3001/QPOI09-8ld35ffa25ha2/download/collection/All?target=ClashMeta"
}

async def show_youtube_unlock_options(query):
    """执行油管解锁测试（仅保留"全部"选项，直接执行）"""
    await run_youtube_unlock_test(query, YOUTUBE_UNLOCK_DEFAULT_PROVIDER)

async def run_youtube_unlock_test(query, provider):
    """执行油管解锁测试"""
    try:
        # 兼容旧回调：未知 provider 回退到默认
        if provider not in YOUTUBE_UNLOCK_PROVIDERS:
            logger.info(f"未知的提供商: {provider}，已回退为 {YOUTUBE_UNLOCK_DEFAULT_PROVIDER}")
            provider = YOUTUBE_UNLOCK_DEFAULT_PROVIDER

        url = YOUTUBE_UNLOCK_PROVIDERS[provider]

        await query.edit_message_text(
            f"⏳ 正在测试 *{provider}* 的油管解锁情况...\n\n"
            f"🔄 正在下载配置并执行测试，请耐心等待...\n"
            f"（此过程可能需要几分钟）",
            parse_mode='Markdown'
        )
        
        # 执行测试命令
        # 工作目录为 /root/clash-speedtest（已挂载到容器）
        work_dir = "/root/clash-speedtest"
        cmd = ["go", "run", "youtube-check.go", "-c", url]
        
        logger.info(f"开始执行油管解锁测试: provider={provider}, cmd={cmd}, work_dir={work_dir}")
        
        try:
            # 运行命令，设置超时时间为10分钟
            process = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=work_dir,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            
            logger.info(f"进程已创建，等待执行完成...")
            
            stdout, stderr = await asyncio.wait_for(
                process.communicate(),
                timeout=1800  # 30分钟超时
            )
            
            stdout_text = stdout.decode('utf-8', errors='ignore') if stdout else ""
            stderr_text = stderr.decode('utf-8', errors='ignore') if stderr else ""
            
            logger.info(f"命令执行完成: returncode={process.returncode}")
            logger.info(f"命令输出 stdout:\n{stdout_text[:2000]}")
            if stderr_text:
                logger.info(f"命令输出 stderr:\n{stderr_text[:2000]}")
            
            if process.returncode != 0:
                error_msg = stderr_text if stderr_text else "未知错误"
                logger.error(f"油管解锁测试命令执行失败: {error_msg}")
                
                keyboard = [
                    [InlineKeyboardButton("🔄 重新测试", callback_data=f"youtube_unlock:test:{provider}")],
                    [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                
                await query.edit_message_text(
                    f"❌ 测试 *{provider}* 失败\n\n"
                    f"错误信息: {error_msg[:500]}",
                    parse_mode='Markdown',
                    reply_markup=reply_markup
                )
                return
                
        except asyncio.TimeoutError:
            keyboard = [
                [InlineKeyboardButton("🔄 重新测试", callback_data=f"youtube_unlock:test:{provider}")],
                [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await query.edit_message_text(
                f"⏰ 测试 *{provider}* 超时\n\n"
                f"测试时间超过30分钟，请稍后重试",
                parse_mode='Markdown',
                reply_markup=reply_markup
            )
            return
        except Exception as cmd_error:
            error_details = traceback.format_exc()
            logger.error(f"执行油管解锁命令时发生错误: {str(cmd_error)}\n{error_details}")
            
            keyboard = [
                [InlineKeyboardButton("🔄 重新测试", callback_data=f"youtube_unlock:test:{provider}")],
                [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await query.edit_message_text(
                f"❌ 执行测试命令失败\n\n"
                f"错误: {str(cmd_error)[:300]}",
                parse_mode='Markdown',
                reply_markup=reply_markup
            )
            return
        
        # 读取结果文件
        result_file = os.path.join(work_dir, "youtube_cn.txt")

        if os.path.exists(result_file):
            with open(result_file, 'r', encoding='utf-8') as f:
                result_content = f.read()

            # Telegram 消息有字数限制，截断过长的内容
            display_content = result_content
            if len(display_content) > 2500:
                display_content = display_content[:2500] + "\n\n... (结果过长已截断)"

            # 先显示测试结果
            await query.edit_message_text(
                f"✅ *{provider}* 油管解锁测试完成\n\n"
                f"📋 *测试结果:*\n"
                f"```\n{display_content}\n```\n\n"
                f"⏳ 正在自动更新送中节点规则...",
                parse_mode='Markdown'
            )

            # 自动调用规则更新函数
            await update_youtube_cn_rule(query, provider)
        else:
            keyboard = [
                [InlineKeyboardButton("🔄 重新测试", callback_data=f"youtube_unlock:test:{provider}")],
                [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await query.edit_message_text(
                f"⚠️ 测试 *{provider}* 完成，但未找到结果文件\n\n"
                f"请检查 youtube_cn.txt 文件是否生成",
                parse_mode='Markdown',
                reply_markup=reply_markup
            )
            
    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"油管解锁测试时发生错误: {str(e)}\n{error_details}")
        
        keyboard = [
            [InlineKeyboardButton("🔄 重新测试", callback_data=f"youtube_unlock:test:{provider}")],
            [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)
        
        await query.edit_message_text(
            f"❌ 测试失败: {str(e)}",
            reply_markup=reply_markup
        )


# 送中节点规则更新相关配置
RULES_REPO_PATH = REPO_PATH  # 使用与主仓库相同的路径 /app/repo
YOUTUBE_CN_FILE = "/root/clash-speedtest/youtube_cn.txt"
UPDATE_SCRIPT = os.path.join(REPO_PATH, "scripts/update_youtube_cn_group.py")
CONFIG_INI_FILE = os.path.join(REPO_PATH, "cfg/Custom_Clash.ini")


async def update_youtube_cn_rule(query, provider):
    """更新送中节点规则并推送到 GitHub"""
    try:
        # 兼容旧回调：未知 provider 回退到默认
        if provider not in YOUTUBE_UNLOCK_PROVIDERS:
            logger.info(f"未知的提供商: {provider}，已回退为 {YOUTUBE_UNLOCK_DEFAULT_PROVIDER}")
            provider = YOUTUBE_UNLOCK_DEFAULT_PROVIDER

        await query.edit_message_text(
            f"📝 正在更新送中节点规则...\n\n"
            f"⏳ 步骤 0/4: 同步最新代码...",
            parse_mode='Markdown'
        )

        # 先拉取最新代码，避免冲突
        await get_repo()

        await query.edit_message_text(
            f"📝 正在更新送中节点规则...\n\n"
            f"✅ 步骤 0/4: 同步最新代码完成\n"
            f"⏳ 步骤 1/4: 解析测试结果...",
            parse_mode='Markdown'
        )

        # 检查测试结果文件是否存在
        if not os.path.exists(YOUTUBE_CN_FILE):
            keyboard = [
                [InlineKeyboardButton("🔄 重新测试", callback_data=f"youtube_unlock:test:{provider}")],
                [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text(
                f"❌ 未找到测试结果文件\n\n"
                f"请先执行油管解锁测试",
                parse_mode='Markdown',
                reply_markup=reply_markup
            )
            return

        # 执行 Python 脚本更新配置
        await query.edit_message_text(
            f"📝 正在更新送中节点规则...\n\n"
            f"✅ 步骤 0/4: 同步最新代码完成\n"
            f"✅ 步骤 1/4: 解析测试结果完成\n"
            f"⏳ 步骤 2/4: 更新配置文件...",
            parse_mode='Markdown'
        )

        update_cmd = [
            "python3", UPDATE_SCRIPT,
            "--local", YOUTUBE_CN_FILE,
            "--config", CONFIG_INI_FILE
        ]

        logger.info(f"执行更新脚本: {update_cmd}")

        try:
            process = await asyncio.create_subprocess_exec(
                *update_cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )

            stdout, stderr = await asyncio.wait_for(
                process.communicate(),
                timeout=60
            )

            stdout_text = stdout.decode('utf-8', errors='ignore') if stdout else ""
            stderr_text = stderr.decode('utf-8', errors='ignore') if stderr else ""

            # 保存更新脚本的输出，用于后续提取节点数量
            update_script_output = stdout_text

            logger.info(f"更新脚本输出: {stdout_text}")
            if stderr_text:
                logger.warning(f"更新脚本错误输出: {stderr_text}")

            if process.returncode != 0:
                keyboard = [
                    [InlineKeyboardButton("🔄 重新测试", callback_data=f"youtube_unlock:test:{provider}")],
                    [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(
                    f"❌ 更新配置文件失败\n\n"
                    f"错误: {stderr_text or stdout_text}",
                    parse_mode='Markdown',
                    reply_markup=reply_markup
                )
                return

        except asyncio.TimeoutError:
            keyboard = [
                [InlineKeyboardButton("🔄 重试", callback_data=f"youtube_unlock:update_rule:{provider}")],
                [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text(
                f"⏰ 更新脚本执行超时",
                reply_markup=reply_markup
            )
            return

        # 检查是否有更改需要提交
        await query.edit_message_text(
            f"📝 正在更新送中节点规则...\n\n"
            f"✅ 步骤 0/4: 同步最新代码完成\n"
            f"✅ 步骤 1/4: 解析测试结果完成\n"
            f"✅ 步骤 2/4: 更新配置文件完成\n"
            f"⏳ 步骤 3/4: 提交到 GitHub...",
            parse_mode='Markdown'
        )

        # 检查 git 状态
        git_status_cmd = ["git", "-C", RULES_REPO_PATH, "status", "--porcelain", "cfg/Custom_Clash.ini"]

        process = await asyncio.create_subprocess_exec(
            *git_status_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )

        stdout, stderr = await asyncio.wait_for(
            process.communicate(),
            timeout=30
        )

        git_status = stdout.decode('utf-8', errors='ignore').strip()

        if not git_status:
            # 没有更改
            keyboard = [
                [InlineKeyboardButton("🔄 重新测试", callback_data=f"youtube_unlock:test:{provider}")],
                [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text(
                f"ℹ️ 配置文件无变化\n\n"
                f"当前规则与测试结果一致，无需更新",
                parse_mode='Markdown',
                reply_markup=reply_markup
            )
            return

        # 执行 git 操作，带冲突自动解决
        async def run_git_cmd(cmd, step_name, timeout_sec=120):
            """执行 git 命令并返回结果"""
            logger.info(f"执行 git 命令 ({step_name}): {cmd}")
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await asyncio.wait_for(
                process.communicate(),
                timeout=timeout_sec
            )
            stdout_text = stdout.decode('utf-8', errors='ignore') if stdout else ""
            stderr_text = stderr.decode('utf-8', errors='ignore') if stderr else ""
            return process.returncode, stdout_text, stderr_text

        # Step 1: git add
        returncode, stdout_text, stderr_text = await run_git_cmd(
            ["git", "-C", RULES_REPO_PATH, "add", "cfg/Custom_Clash.ini"],
            "添加文件"
        )
        if returncode != 0:
            keyboard = [
                [InlineKeyboardButton("🔄 重试", callback_data=f"youtube_unlock:update_rule:{provider}")],
                [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text(
                f"⚠️ Git 添加文件失败\n\n错误: {(stderr_text or stdout_text)[:300]}",
                parse_mode='Markdown',
                reply_markup=reply_markup
            )
            return

        # Step 2: git commit
        returncode, stdout_text, stderr_text = await run_git_cmd(
            ["git", "-C", RULES_REPO_PATH, "commit", "-m", f"chore: update youtube_cn group from {provider} test"],
            "提交更改"
        )
        if returncode != 0:
            keyboard = [
                [InlineKeyboardButton("🔄 重试", callback_data=f"youtube_unlock:update_rule:{provider}")],
                [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text(
                f"⚠️ Git 提交更改失败\n\n错误: {(stderr_text or stdout_text)[:300]}",
                parse_mode='Markdown',
                reply_markup=reply_markup
            )
            return

        # Step 3: git push (带自动拉取和冲突解决)
        returncode, stdout_text, stderr_text = await run_git_cmd(
            ["git", "-C", RULES_REPO_PATH, "push"],
            "推送到远程"
        )

        # 如果 push 失败，尝试 pull --rebase 然后重新 push
        if returncode != 0:
            logger.warning(f"Git push 失败，尝试 pull --rebase: {stderr_text}")

            await query.edit_message_text(
                f"📝 正在更新送中节点规则...\n\n"
                f"✅ 步骤 0/4: 同步最新代码完成\n"
                f"✅ 步骤 1/4: 解析测试结果完成\n"
                f"✅ 步骤 2/4: 更新配置文件完成\n"
                f"⏳ 步骤 3/4: 检测到远程更新，正在同步...",
                parse_mode='Markdown'
            )

            # 尝试 pull --rebase，对于 Custom_Clash.ini 使用我们的版本解决冲突
            returncode, stdout_text, stderr_text = await run_git_cmd(
                ["git", "-C", RULES_REPO_PATH, "pull", "--rebase", "-X", "theirs"],
                "拉取远程更新"
            )

            if returncode != 0:
                # 如果 rebase 失败，尝试中止 rebase 并使用 merge 策略
                logger.warning(f"Git pull --rebase 失败: {stderr_text}")

                # 中止可能的 rebase 状态
                await run_git_cmd(
                    ["git", "-C", RULES_REPO_PATH, "rebase", "--abort"],
                    "中止 rebase"
                )

                # 尝试普通 pull 并自动解决冲突（保留我们的更改）
                returncode, stdout_text, stderr_text = await run_git_cmd(
                    ["git", "-C", RULES_REPO_PATH, "pull", "--no-rebase", "-X", "ours"],
                    "拉取远程更新(merge)"
                )

                if returncode != 0:
                    # 如果还有冲突，强制使用我们的版本
                    logger.warning(f"Git pull merge 失败，尝试强制解决冲突")

                    # 检出我们的版本
                    await run_git_cmd(
                        ["git", "-C", RULES_REPO_PATH, "checkout", "--ours", "cfg/Custom_Clash.ini"],
                        "使用本地版本"
                    )

                    # 添加解决后的文件
                    await run_git_cmd(
                        ["git", "-C", RULES_REPO_PATH, "add", "cfg/Custom_Clash.ini"],
                        "添加解决后的文件"
                    )

                    # 继续 merge/rebase
                    await run_git_cmd(
                        ["git", "-C", RULES_REPO_PATH, "-c", "core.editor=true", "merge", "--continue"],
                        "完成合并"
                    )

            # 再次尝试 push
            returncode, stdout_text, stderr_text = await run_git_cmd(
                ["git", "-C", RULES_REPO_PATH, "push"],
                "重新推送"
            )

            if returncode != 0:
                # 最终失败，报告错误
                logger.error(f"Git push 最终失败: {stderr_text}")
                keyboard = [
                    [InlineKeyboardButton("🔄 重试", callback_data=f"youtube_unlock:update_rule:{provider}")],
                    [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(
                    f"⚠️ Git 推送失败\n\n"
                    f"已尝试自动解决冲突但仍失败\n"
                    f"错误: {(stderr_text or stdout_text)[:300]}",
                    parse_mode='Markdown',
                    reply_markup=reply_markup
                )
                return

        # 成功
        keyboard = [
            [InlineKeyboardButton("🔄 重新测试", callback_data=f"youtube_unlock:test:{provider}")],
            [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)

        # 提取更新脚本输出中的节点数量
        node_count = "未知"
        if "获取到" in update_script_output and "个成功的节点" in update_script_output:
            import re as re_module
            match = re_module.search(r"获取到\s*(\d+)\s*个成功的节点", update_script_output)
            if match:
                node_count = match.group(1)

        # 提取更新的地区分组数量
        region_count = "0"
        if "已更新" in update_script_output and "个地区分组" in update_script_output:
            import re as re_module
            match = re_module.search(r"已更新\s*(\d+)\s*个地区分组", update_script_output)
            if match:
                region_count = match.group(1)

        await query.edit_message_text(
            f"✅ 送中节点规则更新成功!\n\n"
            f"📊 送中节点: *{node_count}* 个\n"
            f"🌍 已从 *{region_count}* 个地区分组中排除\n"
            f"📤 已推送到 GitHub\n\n"
            f"测试提供商: *{provider}*",
            parse_mode='Markdown',
            reply_markup=reply_markup
        )

    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"更新送中节点规则时发生错误: {str(e)}\n{error_details}")

        keyboard = [
            [InlineKeyboardButton("🔄 重试", callback_data=f"youtube_unlock:update_rule:{provider}")],
            [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)

        await query.edit_message_text(
            f"❌ 更新失败: {str(e)}",
            reply_markup=reply_markup
        )


async def handle_search_input(update: Update, context: ContextTypes.DEFAULT_TYPE, search_term) -> None:
    """处理搜索输入并显示结果"""
    user_id = update.effective_user.id
    search_results = []
    
    try:
        # 获取仓库
        await get_repo()
        
        # 在所有规则文件中搜索
        for file_key, file_path in RULE_FILES.items():
            full_path = os.path.join(REPO_PATH, file_path)
            if os.path.exists(full_path):
                rules = extract_rules_from_file(full_path)
                for rule in rules:
                    if search_term.lower() in rule['value'].lower():
                        search_results.append({
                            'file_key': file_key,
                            'file_path': file_path,
                            'rule': rule
                        })
        
        # 显示搜索结果
        if not search_results:
            keyboard = [[InlineKeyboardButton("🔄 重新搜索", callback_data="action:search")],
                       [InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")]]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await update.message.reply_text(f"❌ 未找到包含 '{search_term}' 的规则。", reply_markup=reply_markup)
            return
        
        # 分页显示搜索结果
        user_states[user_id] = {
            "action": "search_results",
            "results": search_results,
            "page": 0,
            "search_term": search_term
        }
        
        await show_search_results(update.message, user_id, 0)
        
    except Exception as e:
        error_details = traceback.format_exc()
        logger.error(f"搜索规则时发生错误: {str(e)}\n{error_details}")
        await update.message.reply_text(f"❌ 搜索失败: {str(e)}\n详细错误请查看日志。")

async def show_search_results(message_obj, user_id, page):
    """分页显示搜索结果"""
    search_results = user_states[user_id]["results"]
    search_term = user_states[user_id]["search_term"]
    
    # 计算分页
    total_pages = (len(search_results) + RULES_PER_PAGE - 1) // RULES_PER_PAGE
    start_idx = page * RULES_PER_PAGE
    end_idx = min(start_idx + RULES_PER_PAGE, len(search_results))
    current_results = search_results[start_idx:end_idx]
    
    # 构建结果显示文本
    results_text = f"🔍 '{search_term}' 的搜索结果 ({len(search_results)}个匹配)\n\n"
    
    for i, result in enumerate(current_results, start=start_idx + 1):
        file_name = os.path.basename(result['file_path'])
        rule_value = result['rule']['value']
        rule_type = "域名" if result['rule']['type'] == "domain" else "IP"
        file_display = RULE_FILE_NAMES.get(result['file_key'], file_name)
        results_text += f"{i}. {rule_value} [{rule_type}]\n   📁 {file_display}\n\n"
    
    # 构建分页按钮
    keyboard = build_pagination_buttons(page, total_pages, "search:page")

    # 添加操作按钮
    keyboard.append([InlineKeyboardButton("🔄 重新搜索", callback_data="action:search")])
    keyboard.append([InlineKeyboardButton("🏠 返回主菜单", callback_data="action:start")])
    
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    # 显示结果
    if hasattr(message_obj, 'edit_message_text'):
        await message_obj.edit_message_text(
            f"{results_text}\n页码: {page+1}/{total_pages}",
            reply_markup=reply_markup
        )
    else:
        await message_obj.reply_text(
            f"{results_text}\n页码: {page+1}/{total_pages}",
            reply_markup=reply_markup
        )

async def run_bot():
    """异步运行机器人"""
    # 创建应用并注册处理程序
    application = Application.builder().token(TELEGRAM_TOKEN).build()

    # 添加处理程序
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("view", view_command))
    application.add_handler(CommandHandler("delete", delete_command))
    application.add_handler(CommandHandler("move", move_command))
    application.add_handler(CommandHandler("search", search_command))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_input))
    application.add_handler(CallbackQueryHandler(handle_callback))

    # 启动机器人
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
requests>=2.28.1
EOF

cat > Dockerfile << 'EOF'
FROM python:3.11-slim-bookworm

WORKDIR /app

COPY bot.py /app/
COPY requirements.txt /app/

# 配置使用国内镜像源并安装依赖（提高稳定性）
RUN set -ex && \
    # 备份原始源列表
    cp /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/debian.sources.bak 2>/dev/null || true && \
    # 使用阿里云镜像源
    echo "deb https://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
    # 配置 apt 选项以提高稳定性
    echo 'Acquire::Retries "3";' > /etc/apt/apt.conf.d/80-retries && \
    echo 'Acquire::http::Timeout "30";' >> /etc/apt/apt.conf.d/80-retries && \
    echo 'Acquire::https::Timeout "30";' >> /etc/apt/apt.conf.d/80-retries && \
    echo 'Acquire::Check-Valid-Until "false";' >> /etc/apt/apt.conf.d/80-retries && \
    # 更新包列表（带重试）
    (apt-get update || apt-get update || apt-get update) && \
    # 安装依赖
    apt-get install -y --no-install-recommends \
        git \
        dbus \
        polkitd \
        pkexec \
        ca-certificates && \
    # 清理缓存
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    # 安装 Python 依赖
    pip install --no-cache-dir -r requirements.txt && \
    # 创建仓库目录
    mkdir -p /app/repo && \
    chmod -R 777 /app/repo

# 安装 Go（从本地文件，避免网络问题）
# Go 必须在容器内安装，不能从宿主机挂载（因为 OpenWrt 使用 musl libc，而容器使用 glibc）
COPY go.tar.gz /tmp/go.tar.gz
RUN tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz

# Go 环境变量
ENV PATH=$PATH:/usr/local/go/bin
ENV GOROOT=/usr/local/go
ENV GOPATH=/root/go
ENV GOPROXY=https://goproxy.cn,direct

CMD ["python", "bot.py"]
EOF

# 检查 Go 安装包是否存在
if [ ! -f "go.tar.gz" ]; then
    # 检测架构
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64) GOARCH="amd64" ;;
        aarch64) GOARCH="arm64" ;;
        armv7l) GOARCH="armv6l" ;;
        *) GOARCH="amd64" ;;
    esac

    echo "=========================================="
    echo "❌ 缺少 Go 安装包 (go.tar.gz)"
    echo ""
    echo "请手动下载 Go 并放到当前目录："
    echo ""
    echo "下载地址（选择一个）："
    echo "  官方: https://go.dev/dl/"
    echo "  中国镜像: https://golang.google.cn/dl/"
    echo ""
    echo "推荐版本: go1.23.4.linux-${GOARCH}.tar.gz"
    echo ""
    echo "下载后重命名为 go.tar.gz 放到此目录："
    echo "  mv go1.23.4.linux-${GOARCH}.tar.gz go.tar.gz"
    echo ""
    echo "然后重新运行此脚本"
    echo "=========================================="
    exit 1
fi
echo "✓ 检测到 Go 安装包: go.tar.gz"

# 生成 docker-compose.yml
# Go 已在 Dockerfile 中安装，无需从宿主机挂载
# 仅挂载 GOPATH 用于缓存 Go 模块
cat > docker-compose.yml << 'EOF'
services:
  telegram-bot:
    build: .
    container_name: openclash-rule-bot
    restart: always
    network_mode: "host"
    volumes:
      - ./repo:/app/repo
      - /root/clash-speedtest:/root/clash-speedtest
      - /root/go:/root/go
    environment:
      - TZ=Asia/Shanghai
EOF

# 创建repo目录
mkdir -p repo

# 检查授权用户ID文件是否存在
if [ ! -f /root/AUTHORIZED_USER_ID.txt ]; then
    echo "请创建/root/AUTHORIZED_USER_ID.txt文件，并将您的Telegram用户ID写入该文件"
    echo "您可以通过与@userinfobot机器人对话来获取您的Telegram用户ID"
    echo "创建完成后，请重新运行此脚本"
    exit 1
fi

# 配置git用户信息
git config --global user.email "1041151706@qq.com"
git config --global user.name "AceDylan"

# 启动Docker容器
docker-compose up -d --build

echo "-------------------------------------"
echo "✅ OpenClash规则管理机器人已启动"
echo "🤖 您可以在Telegram上搜索您的机器人并开始使用"
echo "🔒 已启用权限控制，只有授权用户ID可以使用此机器人"
echo "🆔 当前授权用户ID: $(cat /root/AUTHORIZED_USER_ID.txt)"
echo "-------------------------------------" 
