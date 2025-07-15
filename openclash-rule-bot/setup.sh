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

# 规则文件列表
RULE_FILES = {
    "ai": "rule/Custom_Proxy_AI.list",
    "direct": "rule/Custom_Direct_my.list",
    "emby": "rule/Custom_Proxy_Emby.list",
    "media": "rule/Custom_Proxy_Media.list",
    "google": "rule/Custom_Proxy_Google.list"
}

# 规则文件与OpenClash规则名称映射
OPENCLASH_RULE_MAPPING = {
    "rule/Custom_Proxy_AI.list": "Custom_Proxy_AI",
    "rule/Custom_Direct_my.list": "Custom_Direct_my",
    "rule/Custom_Proxy_Emby.list": "Custom_Proxy_Emby",
    "rule/Custom_Proxy_Media.list": "Custom_Proxy_Media",
    "rule/Custom_Proxy_Google.list": "Custom_Proxy_Google"
}

# 规则文件对应的显示名称
RULE_FILE_NAMES = {
    "ai": "🤖 AI代理规则",
    "direct": "🏠 直连规则",
    "emby": "🎬 Emby代理规则",
    "media": "📺 国外媒体代理规则",
    "google": "🔍 Google代理规则"
}

# 用户状态存储
user_states = {}

# 每页显示的规则条数
RULES_PER_PAGE = 10

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/start命令"""
    user_name = update.effective_user.first_name

    # 创建功能按钮
    keyboard = [
        [InlineKeyboardButton("➕ 添加规则", callback_data="action:add")],
        [InlineKeyboardButton("👁️ 查看规则", callback_data="action:view")],
        [InlineKeyboardButton("❌ 删除规则", callback_data="action:delete")],
        [InlineKeyboardButton("↔️ 移动规则", callback_data="action:move")]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)

    await update.message.reply_text(
        f"🚀 *欢迎 {user_name} 使用 OpenClash 规则管理机器人！*\n\n"
        "✨ *功能简介：*\n"
        "此机器人可以帮您管理OpenClash规则，支持添加、查看、删除和移动规则。\n\n"
        "请选择您要执行的操作：",
        parse_mode='Markdown',
        reply_markup=reply_markup
    )

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/help命令"""
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
        "📋 *支持的规则文件：*\n"
        "• 🤖 AI代理规则 (Custom_Proxy_AI.list)\n"
        "• 🏠 直连规则 (Custom_Direct_my.list)\n"
        "• 🎬 Emby代理规则 (Custom_Proxy_Emby.list)\n"
        "• 📺 国外媒体代理规则 (Custom_Proxy_Media.list)\n"
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
        # 创建功能按钮菜单
        keyboard = [
            [InlineKeyboardButton("➕ 添加规则", callback_data="action:add")],
            [InlineKeyboardButton("👁️ 查看规则", callback_data="action:view")],
            [InlineKeyboardButton("❌ 删除规则", callback_data="action:delete")],
            [InlineKeyboardButton("↔️ 移动规则", callback_data="action:move")]
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
    user_id = update.effective_user.id
    user_states[user_id] = {"action": "view", "page": 0}

    keyboard = []
    for key, name in RULE_FILE_NAMES.items():
        keyboard.append([InlineKeyboardButton(name, callback_data=f"view:file:{key}")])

    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text("👁️ 请选择要查看的规则文件:", reply_markup=reply_markup)

async def delete_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/delete命令，删除规则"""
    user_id = update.effective_user.id
    user_states[user_id] = {"action": "delete"}

    keyboard = []
    for key, name in RULE_FILE_NAMES.items():
        keyboard.append([InlineKeyboardButton(name, callback_data=f"delete:file:{key}")])

    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text("❌ 请选择要从哪个规则文件中删除规则:", reply_markup=reply_markup)

async def move_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/move命令，移动规则"""
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
                origin.pull()
        else:
            # 确保父目录存在
            os.makedirs(os.path.dirname(REPO_PATH), exist_ok=True)
            repo = git.Repo.clone_from(REPO_URL, REPO_PATH)
    else:
        repo = git.Repo(REPO_PATH)
        origin = repo.remotes.origin
        origin.pull()

    return repo

async def refresh_openclash_rule(file_path):
    """刷新OpenClash规则"""
    update_message = ""
    try:
        if file_path in OPENCLASH_RULE_MAPPING:
            rule_name = OPENCLASH_RULE_MAPPING[file_path]
            url = f"{OPENCLASH_API_URL}/providers/rules/{rule_name}"
            headers = {"Authorization": f"Bearer {OPENCLASH_API_SECRET}"}
            response = requests.put(url, headers=headers)
            if response.status_code == 204:
                update_message = f"✅ 已成功刷新OpenClash规则: {rule_name}"
            else:
                update_message = f"❌ 尝试刷新规则失败，状态码: {response.status_code}"
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

async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理按钮回调"""
    query = update.callback_query
    await query.answer()

    user_id = update.effective_user.id
    if user_id not in user_states and not query.data.startswith("action:"):
        await query.edit_message_text("⏱️ 会话已过期，请重新开始。")
        return

    callback_data = query.data

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

    # 添加规则
    elif callback_data.startswith("add:file:"):
        file_key = callback_data.split(":")[2]
        if file_key in RULE_FILES:
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
            file_path = user_states[user_id]["viewing_file"]
            page = int(parts[2])
            user_states[user_id]["page"] = page
            await show_rules_page(query, user_id, file_path, page)

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
            file_path = user_states[user_id]["deleting_file"]
            page = int(parts[2])
            user_states[user_id]["page"] = page
            await show_deletable_rules(query, user_id, file_path, page)
        elif parts[1] == "rule":
            file_path = user_states[user_id]["deleting_file"]
            rule_index = int(parts[2])
            await confirm_delete_rule(query, user_id, file_path, rule_index)
        elif parts[1] == "confirm":
            file_path = user_states[user_id]["deleting_file"]
            rule_index = int(parts[2])
            action = parts[3]
            if action == "yes":
                await delete_rule_and_commit(query, user_id, file_path, rule_index)
            else:
                # 返回规则列表
                page = user_states[user_id].get("page", 0)
                await show_deletable_rules(query, user_id, file_path, page)

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
            source_path = user_states[user_id]["source_file"]
            page = int(parts[2])
            user_states[user_id]["page"] = page
            await show_movable_rules(query, user_id, source_path, page)
        elif parts[1] == "rule":
            source_path = user_states[user_id]["source_file"]
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
            rules = extract_rules_from_file(full_path)
            rule_info = rules[rule_index]

            await query.edit_message_text(
                f"↔️ 请选择要将规则移动到哪个文件：\n\n"
                f"当前规则：{rule_info['value']}\n"
                f"当前文件：{os.path.basename(source_path)}",
                reply_markup=reply_markup
            )
        elif parts[1] == "target":
            target_key = parts[2]
            if target_key in RULE_FILES:
                target_path = RULE_FILES[target_key]
                user_states[user_id]["target_file"] = target_path
                await move_rule_and_commit(query, user_id)
            else:
                await query.edit_message_text("❌ 无效的文件选择，请重新操作。")
        elif parts[1] == "cancel":
            # 返回源文件的规则列表
            source_path = user_states[user_id]["source_file"]
            page = user_states[user_id].get("page", 0)
            user_states[user_id]["step"] = "select_rule"
            await show_movable_rules(query, user_id, source_path, page)

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
        keyboard = []
        paging_buttons = []

        if page > 0:
            paging_buttons.append(InlineKeyboardButton("◀️ 上一页", callback_data=f"view:page:{page-1}"))

        if page < total_pages - 1:
            paging_buttons.append(InlineKeyboardButton("▶️ 下一页", callback_data=f"view:page:{page+1}"))

        if paging_buttons:
            keyboard.append(paging_buttons)

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
        paging_buttons = []
        if page > 0:
            paging_buttons.append(InlineKeyboardButton("◀️ 上一页", callback_data=f"delete:page:{page-1}"))

        if page < total_pages - 1:
            paging_buttons.append(InlineKeyboardButton("▶️ 下一页", callback_data=f"delete:page:{page+1}"))

        if paging_buttons:
            keyboard.append(paging_buttons)

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

        # 获取规则信息
        full_path = os.path.join(REPO_PATH, file_path)
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
        paging_buttons = []
        if page > 0:
            paging_buttons.append(InlineKeyboardButton("◀️ 上一页", callback_data=f"move:page:{page-1}"))

        if page < total_pages - 1:
            paging_buttons.append(InlineKeyboardButton("▶️ 下一页", callback_data=f"move:page:{page+1}"))

        if paging_buttons:
            keyboard.append(paging_buttons)

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
    input_value = user_data["input"]
    input_type = user_data["type"]

    try:
        # 获取仓库
        repo = await get_repo()
        await query.edit_message_text("🔄 正在更新仓库...")

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

        # 通知用户正在等待GitHub更新，并设置60秒倒计时
        await query.edit_message_text(f"✅ 成功！\n\n'{input_value}' 已添加到 {os.path.basename(file_path)} 并推送到仓库。\n\n⏳ 正在等待GitHub同步更新 (60秒)...")

        # 每10秒更新一次倒计时消息
        wait_time = 60
        while wait_time > 0:
            await asyncio.sleep(10)
            wait_time -= 10
            if wait_time > 0:
                await query.edit_message_text(f"✅ 成功！\n\n'{input_value}' 已添加到 {os.path.basename(file_path)} 并推送到仓库。\n\n⏳ 正在等待GitHub同步更新 ({wait_time}秒)...")

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
    application.add_handler(CommandHandler("view", view_command))
    application.add_handler(CommandHandler("delete", delete_command))
    application.add_handler(CommandHandler("move", move_command))
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
echo "🤖 您可以在Telegram上搜索您的机器人并开始使用"
echo "-------------------------------------" 