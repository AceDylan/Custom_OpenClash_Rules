#!/bin/bash
# 定时策略切换脚本
# 通过容器内 bot.py 的 switch_application_proxies 调 OpenClash API 批量切换应用策略组
#
# 用法：
#   auto_proxy_switch.sh chain   # 🔗 切到链式（直连智能 → 链式前置）
#   auto_proxy_switch.sh smart   # 🧠 切回智能（链式前置 → 直连智能）
#
# 典型 crontab（每天凌晨 1 点切到链式，每天 18:00 切回智能）：
#   0 1  * * * /root/openclash-bot/auto_proxy_switch.sh chain >> /root/openclash-bot/cron.log 2>&1
#   0 18 * * * /root/openclash-bot/auto_proxy_switch.sh smart >> /root/openclash-bot/cron.log 2>&1

DIRECTION="$1"
case "$DIRECTION" in
    chain) LABEL="🔗 切到链式" ;;
    smart) LABEL="🧠 切回智能" ;;
    *) echo "用法: $0 chain|smart"; exit 1 ;;
esac

TELEGRAM_TOKEN=$(cat /root/TELEGRAM_TOKEN.txt)
CHAT_ID=$(cat /root/AUTHORIZED_USER_ID.txt)

# 发送 Telegram 通知（纯文本，避免结果里的特殊字符破坏 Markdown 解析）
send_message() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "text=$1" > /dev/null
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始执行：${LABEL}"

# 复用容器内 bot.py 的切换逻辑（单一事实源），用 FakeQuery 接收输出
RESULT=$(docker exec openclash-rule-bot python3 -c "
import asyncio
import sys
sys.path.insert(0, '/app')
from bot import switch_application_proxies

class FakeQuery:
    def __init__(self):
        self.last_msg = ''
    async def edit_message_text(self, text, **kwargs):
        self.last_msg = text
    async def answer(self):
        pass

async def main():
    q = FakeQuery()
    await switch_application_proxies(q, '${DIRECTION}')
    print('===RESULT===')
    print(q.last_msg)

asyncio.run(main())
" 2>&1)

echo "$RESULT"

# 提取最终结果并推送通知
FINAL=$(echo "$RESULT" | sed -n '/===RESULT===/,$p' | tail -n +2 | head -c 2000)
if [ -n "$FINAL" ]; then
    send_message "$FINAL"
else
    send_message "⚠️ ${LABEL} 执行异常，详情见 cron.log"
fi
