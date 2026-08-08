# OpenClash 规则机器人与 QoE watchdog 部署指南

## 部署前准备

路由器需要已安装 Docker、Docker Compose 和 OpenClash，并准备以下四个仅保存在路由器 `/root` 下的文件：

```text
/root/TELEGRAM_TOKEN.txt
/root/GITHUB_TOKEN.txt
/root/AUTHORIZED_USER_ID.txt
/root/OPENCLASH_API_SECRET.txt
```

不要把这些文件、控制器密钥、订阅 URL、私有落地节点或 `dialer-proxy` 凭据提交到本仓库。

## OpenClash：关闭全局 Smart，保留选择性 Smart

OpenClash 的全局转换开关是 `auto_smart_switch`，不是 `smart_enable`。执行：

```sh
uci -q set openclash.config.auto_smart_switch='0'
uci commit openclash
uci -q get openclash.config.auto_smart_switch
```

最后一条命令必须输出 `0`。不要为了此变更修改 `openclash.config.smart_enable`；它控制 Smart 核心选择，应保留路由器当前能正常运行 Smart 组的值。

选择性 Smart 属于持久的路由器私有覆写边界。先备份已有文件：

```sh
cp /etc/openclash/custom/openclash_custom_overwrite.sh \
   /etc/openclash/custom/openclash_custom_overwrite.sh.before-selective-smart
```

在现有覆写逻辑的 `exit 0` 之前加入以下不含凭据的代码；不要覆盖脚本中已有的私有落地配置。它从 UCI 读取当前已配置的 Smart `policy-priority`，并通过 Ruby 直接写入带类型的 YAML 值：

```sh
SMART_POLICY_PRIORITY="$(uci -q get openclash.config.smart_policy_priority)"
if [ -z "${SMART_POLICY_PRIORITY}" ]; then
    echo "错误：openclash.config.smart_policy_priority 为空，拒绝写入不完整的 Smart 配置" >&2
    exit 1
fi
export SMART_POLICY_PRIORITY

ruby -ryaml - "${CONFIG_FILE}" <<'RUBY'
config_file = ARGV.fetch(0)
config = YAML.load_file(config_file)
groups = config.fetch("proxy-groups")

smart_allowlist = [
  "✈️ 机场前置",
  "✈️ 机场新加坡",
  "✈️ 机场日本",
  "🇭🇰 香港节点",
  "🇺🇸 美国节点",
  "🇸🇬 新加坡节点",
  "🇯🇵 日本节点",
  "🔙 送中节点",
]
groups_by_name = groups.each_with_object({}) do |group, index|
  index[group["name"]] = group if group.is_a?(Hash)
end

required_groups = smart_allowlist
missing_groups = required_groups.reject { |name| groups_by_name.key?(name) }
abort "缺少策略组：#{missing_groups.join(', ')}" unless missing_groups.empty?

smart_allowlist.each do |name|
  group = groups_by_name.fetch(name)
  group["type"] = "smart"
  group["policy-priority"] = ENV.fetch("SMART_POLICY_PRIORITY")
  group["uselightgbm"] = true
end

File.open(config_file, "w") { |file| YAML.dump(config, file) }
RUBY
```

此列表是完整 allowlist。上述八组必须同时具有 `type: smart`、与 `uci -q get openclash.config.smart_policy_priority` 当前输出相同的 `policy-priority`，以及 YAML 布尔值 `uselightgbm: true`。不要用 `ruby_arr_edit` 写 `uselightgbm`，因为它会写成字符串而不是 YAML 布尔值。订阅更新或 OpenClash 重启后，私有覆写会再次应用这些设置；仓库中的 `cfg/Custom_Clash.ini` 仍以 `url-test` 定义 `🔙 送中节点`，供 Subconverter 生成可移植基础配置；路由器私有覆写才把它转换为 Smart。全局 `auto_smart_switch` 保持 `0`。

应用选择器同时提供对应的 `*智能` 和 `*节点`。`*智能` 仍是 fallback：`*手选` 在前、`*节点` 在后，手选 BEST 节点仍是直连 VPS。新增 `*节点` 选项只供 watchdog 临时绕过 VPS，不改变任何默认选项。

修改私有覆写后重启 OpenClash：

```sh
/etc/init.d/openclash restart
```

## 安装机器人和 watchdog

```sh
cd /root
wget https://raw.githubusercontent.com/AceDylan/Custom_OpenClash_Rules/main/openclash-rule-bot/setup.sh
chmod +x setup.sh
./setup.sh
```

从完整仓库运行时，`setup.sh` 复制同目录的 `qoe_watchdog.py`；只下载 `setup.sh` 时，它会从同一公开仓库下载该模块。随后脚本会：

- 生成并构建 `/root/openclash-bot/bot.py`；
- 把纯决策模块安装为容器内 `/app/qoe_watchdog.py`；
- 创建宿主机 `/root/openclash-bot/state` 并挂载为 `/app/state`；
- 生成 `/root/openclash-bot/auto_qoe_watchdog.sh`；
- 幂等安装每 2 分钟执行一次的 cron，保留其他所有 cron；
- 重建并启动 `openclash-rule-bot` 容器。

现有兼容任务的命令名和时间保持不变：

```cron
0 1  * * * /root/openclash-bot/auto_proxy_switch.sh chain >> /root/openclash-bot/cron.log 2>&1
0 18 * * * /root/openclash-bot/auto_proxy_switch.sh smart >> /root/openclash-bot/cron.log 2>&1
```

`chain` 表示 01:00 开始的白天机场→VPS 链式模式；`smart` 表示 18:00 开始的夜间 VPS 优先模式。命令参数未改变。

## Watchdog 行为

每次 cron 都是独立的一次检查。函数先读取六个应用组当前选择，因此跨白天/夜间执行安全：检测到应用正在使用链式日本、新加坡或美国时执行白天逻辑；否则只处理夜间 `*智能` 或 watchdog 自己记录的 `*节点` failover。任一应用组读取失败时无法可靠判断模式，本轮不会切换或删除连接，并会打断连续计数。

只要任一应用选择器当前为 `🔙 送中组`，送中监视器就在白天或夜间同时运行。它只处理 `/connections` 中 chains 包含 `🔙 送中节点` 的连接；Smart 自己根据实际流量重新评估节点，watchdog 负责在连接卡死时定向重建这些匹配连接，不修改任何应用选择器。应用集合、白天/夜间模式或选择器快照不完整时都会重置连续计数并跳过动作。

### 夜间 VPS 优先

检查范围是现有 `PROXY_SWITCH_APPLICATION_GROUPS`：社交媒体、流媒体、影音娱乐、谷歌与 AI、漏网之鱼、系统与测速。映射如下：

```text
香港智能 ↔ 香港节点
美国智能 ↔ 美国节点
新加坡智能 ↔ 新加坡节点
日本智能 ↔ 日本节点
```

应用当前选择 `*智能` 时，watchdog 直接通过控制器 `/proxies/{智能组}/delay` 探测地区智能 fallback 组。这样既测试实际的 VPS 优先路径，也由 fallback 自身在 VPS 硬故障时尝试后备节点；不会再把手选 selector 返回的 BEST 叶子名称当作可寻址的 `/proxies` 资源。智能组探测失败或延迟高于 1500 ms 连续 3 次，才把该应用临时切换到对应 `*节点`。

failover 会在 `probe_group` 字段记录被探测的原始智能组。只有该记录仍存在且应用仍保持 watchdog 设置的 `*节点` 时才允许恢复；任何人工选择都会使记录失效，watchdog 不会覆盖。恢复要求原智能组连续 5 次健康，并且 failover 至少保持 10 分钟。

### 白天机场→VPS 链式模式

链式组对应的活跃机场组是：

```text
链式日本     → 机场日本
链式新加坡   → 机场新加坡
链式美国     → 机场前置
```

watchdog 从 `/connections` 取两次样本，间隔默认 2 秒，只统计两次都存在且 chains 命中该机场组的连接 ID。没有稳定活跃样本视为“无退化”，不会探测或清理。

只有聚合下载速率低于 `3 MiB/s`，并且对应机场组的 delay 探测失败或高于 1500 ms，才累计一次退化。连续 3 次退化且不在 10 分钟 cooldown 内时，仅逐条删除第二次样本中 chains 包含该机场组的连接，让 Smart 在新连接上重新评估。送中连接使用相同的 2 秒采样、`3 MiB/s` 阈值、1500 ms 探测阈值和连续 3 次要求；健康 delay、没有稳定活跃样本或 inactive 选择都会清零计数。它绝不会调用“清空全部连接”；动作完成或健康结果都会重置连续计数。每次低速/高延迟清理后，送中和白天机场组各自进入默认 10 分钟 cooldown。发生定向清理时才发送 Telegram，正常巡检只写日志；ACTION 文本明确标记 `degraded QoE`。

重要：URL-Test 只提供存活性/RTT fallback，不测量带宽。白天逻辑必须同时满足低吞吐和坏延迟，低吞吐本身不会触发连接清理。

### 配置和持久化

默认探测 URL 为 `https://www.gstatic.com/generate_204`，控制器探测 timeout 为 5000 ms，高延迟阈值为 1500 ms。可在运行 `docker-compose` 前通过环境变量覆盖：

```sh
export QOE_PROBE_URL='https://www.gstatic.com/generate_204'
export QOE_PROBE_TIMEOUT_MS='5000'
export QOE_HIGH_DELAY_MS='1500'
export QOE_NIGHT_FAILURE_STRIKES='3'
export QOE_NIGHT_RECOVERY_PASSES='5'
export QOE_NIGHT_MIN_HOLD_SECONDS='600'
export QOE_DAY_SAMPLE_SECONDS='2'
export QOE_DAY_LOW_RATE_BPS='3145728'
export QOE_DAY_FAILURE_STRIKES='3'
export QOE_DAY_COOLDOWN_SECONDS='600'
```

状态文件为容器内 `/app/state/qoe_watchdog.json`，对应宿主机 `/root/openclash-bot/state/qoe_watchdog.json`。写入使用同目录临时文件、`fsync` 和原子替换；容器重建不会丢失 strike、恢复计数、hold 或 cooldown。文件损坏/缺失及无法识别的旧字段按空状态启动，不会基于未知历史恢复应用选择。watchdog 从不覆盖手工应用选择。宿主脚本还使用 `/tmp/openclash-auto-qoe-watchdog.lock` 的原子 `mkdir` 锁；cron 或手工巡检重叠时，后启动的一次会正常退出且不做任何操作，持锁进程退出时由 trap 清理。

## 风险

这是有意保守但仍会主动断开连接的自动化：只有稳定样本低于 `3 MiB/s` 且同一 `🔙 送中节点` 探测失败/超过 1500 ms 连续 3 次才清理，清理会造成一次重连和短暂中断。Smart leaf 变化不等待退化阈值，但只删除 chains 明确包含 `🔙 送中节点` 的现有连接；它不会改应用选择器。错误的控制器地址、权限或不完整快照只会跳过本轮。URL-Test/Smart 的延迟不是带宽保证，网络本身持续抖动时仍可能出现重连；可先提高 `QOE_DAY_FAILURE_STRIKES` 或 `QOE_HIGH_DELAY_MS`，或按下方步骤停用 watchdog。

## 验证

```sh
# UCI 全局转换必须关闭；Smart 核心选择仅查看、不改动
uci -q get openclash.config.auto_smart_switch
uci -q get openclash.config.smart_enable

# 确认 cron 唯一且原有 01:00/18:00 任务仍在
crontab -l | grep -E 'auto_qoe_watchdog|auto_proxy_switch'

# 手工执行一次；无动作只打印结果，动作同时发送 Telegram
/root/openclash-bot/auto_qoe_watchdog.sh

# 查看 cron 和容器日志
tail -n 50 /root/openclash-bot/qoe_watchdog.log
docker logs --tail 100 openclash-rule-bot

# 确认持久状态挂载
docker inspect openclash-rule-bot | grep '/app/state'
ls -l /root/openclash-bot/state/qoe_watchdog.json
```

在 OpenClash 面板或最终生成的 YAML 中还应确认：八个 allowlist 组均为 `smart`，其 `policy-priority` 与当前 UCI 值相同且 `uselightgbm` 是布尔值 `true`；仓库模板中的 `🔙 送中节点` 仍是便携 `url-test`，但路由器运行时私有覆写后的组应为 `smart`；四个 `*智能` 仍是 fallback 且手选在前；链式组的私有 `dialer-proxy` 仍分别指向正确机场前置。不要用仓库中的模板值代替路由器私有落地配置。

## 回滚

只停用 watchdog、保留选择性 Smart：

```sh
( crontab -l 2>/dev/null | sed '\|/root/openclash-bot/auto_qoe_watchdog.sh|d' ) | crontab -
mv /root/openclash-bot/state/qoe_watchdog.json \
   /root/openclash-bot/state/qoe_watchdog.json.disabled 2>/dev/null || true
```

然后在 OpenClash 面板手工恢复需要的应用选择。移动状态文件是可恢复操作；不要在仍启用 cron 时删除状态，否则连续计数会从零重新开始。

完全恢复原先的全局 Smart 行为时，先停用 watchdog，再恢复备份的私有覆写，并把 `auto_smart_switch` 改回变更前的值（原来为 `1` 才设置为 `1`）：

```sh
cp /etc/openclash/custom/openclash_custom_overwrite.sh.before-selective-smart \
   /etc/openclash/custom/openclash_custom_overwrite.sh
# 只有备份前确实为 1 时才执行下一行；本增强默认要求保持 0。
# uci -q set openclash.config.auto_smart_switch='1'
# uci commit openclash
/etc/init.d/openclash restart
```

`setup.sh` 每次都会重新生成 `bot.py`、Dockerfile、Compose 和宿主 watchdog 脚本；机器人逻辑必须修改仓库源文件，不能只修改运行中容器。路由器私有覆写仍只在本地维护。
