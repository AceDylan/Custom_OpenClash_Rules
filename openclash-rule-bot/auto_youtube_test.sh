#!/bin/bash

TELEGRAM_TOKEN=$(cat /root/TELEGRAM_TOKEN.txt)
CHAT_ID=$(cat /root/AUTHORIZED_USER_ID.txt)

send_message() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    -d "parse_mode=Markdown" \
    -d "text=$1"
}

send_message "🤖 *定时任务启动*%0A开始执行油管解锁全部测试..."

# 执行测试
RESULT=$(docker exec openclash-rule-bot python3 -c "
import asyncio
import sys
sys.path.insert(0, '/app')
from bot import run_youtube_unlock_test

class FakeQuery:
    def __init__(self):
        self.last_msg = ''
    async def edit_message_text(self, text, **kwargs):
        self.last_msg = text
        print(text[:200])
    async def answer(self):
        pass

async def main():
    q = FakeQuery()
    await run_youtube_unlock_test(q, '全部')
    print('===RESULT===')
    print(q.last_msg)

asyncio.run(main())
" 2>&1)

# 提取结果并发送
FINAL=$(echo "$RESULT" | sed -n '/===RESULT===/,$p' | tail -n +2 | head -c 2000)
if [ -n "$FINAL" ]; then
    send_message "✅ *定时任务完成*%0A%0A${FINAL}"
else
    send_message "⚠️ 任务完成，详情见日志"
fi