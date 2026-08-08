import ast
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SETUP_PATH = ROOT / "openclash-rule-bot" / "setup.sh"


def setup_text():
    return SETUP_PATH.read_text(encoding="utf-8")


def generated_file(name, quoted=False):
    quote = "'" if quoted else ""
    marker = f"cat > {name} << {quote}EOF{quote}\n"
    setup = setup_text()
    start = setup.index(marker) + len(marker)
    end = setup.index("\nEOF\n", start)
    return setup[start:end]


def generated_bot_mapping(name):
    bot = generated_file("bot.py")
    marker = f"{name} = {{\n"
    start = bot.index(marker) + len(name) + 3
    end = bot.index("\n}\n", start) + 2
    return ast.literal_eval(bot[start:end])


class SetupContractTests(unittest.TestCase):
    def test_setup_installs_watchdog_module_state_volume_script_and_cron(self):
        setup = setup_text()
        self.assertIn("qoe_watchdog.py", setup)
        self.assertIn("/app/state", setup)
        self.assertIn("auto_qoe_watchdog.sh", setup)
        self.assertIn("*/2 * * * *", setup)

    def test_scheduled_topology_maps_recover_watchdog_node_failovers(self):
        to_chain = generated_bot_mapping("PROXY_SWITCH_TO_CHAIN_MAP")
        to_smart = generated_bot_mapping("PROXY_SWITCH_TO_SMART_MAP")
        regions = (
            ("🇺🇸 美国智能", "🇺🇸 美国节点", "🔗 链式美国"),
            ("🇸🇬 新加坡智能", "🇸🇬 新加坡节点", "🔗 链式新加坡"),
            ("🇯🇵 日本智能", "🇯🇵 日本节点", "🔗 链式日本"),
        )

        for smart, airport, chain in regions:
            # The 01:00 chain command wins from normal Smart or a watchdog failover.
            self.assertEqual(chain, to_chain[smart])
            self.assertEqual(chain, to_chain[airport])
            # The 18:00 smart command wins from day topology or a lingering failover.
            self.assertEqual(smart, to_smart[chain])
            self.assertEqual(smart, to_smart[airport])

        # Hong Kong has no daytime chain landing, but a night watchdog failover
        # must still be returned to VPS-priority by the 18:00 schedule.
        self.assertEqual("🇭🇰 香港智能", to_smart["🇭🇰 香港节点"])
        self.assertNotIn("🇭🇰 香港节点", to_chain)

        for manual_value in ("DIRECT", "🎯 全球直连", "🔙 送中组"):
            self.assertNotIn(manual_value, to_chain)
            self.assertNotIn(manual_value, to_smart)

    def test_generated_watchdog_uses_portable_atomic_mkdir_lock(self):
        script = generated_file("auto_qoe_watchdog.sh", quoted=True)
        lock = 'if ! mkdir "${WATCHDOG_LOCK_DIR}" 2>/dev/null; then'
        cleanup = 'trap \'rmdir "${WATCHDOG_LOCK_DIR}" 2>/dev/null || :\' 0'

        self.assertIn('WATCHDOG_LOCK_DIR="/tmp/openclash-auto-qoe-watchdog.lock"', script)
        self.assertIn(lock, script)
        self.assertIn(cleanup, script)
        self.assertIn("trap 'exit 1' 1 2 3 15", script)
        self.assertIn("exit 0", script[script.index(lock):script.index("fi", script.index(lock))])
        self.assertLess(script.index(lock), script.index("TELEGRAM_TOKEN="))
        self.assertLess(script.index(lock), script.index("docker exec"))

    def test_deploy_guide_uses_complete_typed_selective_smart_overwrite(self):
        guide = (ROOT / "openclash-rule-bot" / "DEPLOY_GUIDE.md").read_text(encoding="utf-8")
        allowlist = (
            "✈️ 机场前置",
            "✈️ 机场新加坡",
            "✈️ 机场日本",
            "🇭🇰 香港节点",
            "🇺🇸 美国节点",
            "🇸🇬 新加坡节点",
            "🇯🇵 日本节点",
            "🔙 送中节点",
        )

        for group in allowlist:
            self.assertIn(f'  "{group}",', guide)
        self.assertIn("uci -q get openclash.config.smart_policy_priority", guide)
        self.assertIn('group["policy-priority"] = ENV.fetch("SMART_POLICY_PRIORITY")', guide)
        self.assertIn('group["uselightgbm"] = true', guide)
        self.assertIn('group["type"] = "smart"', guide)
        self.assertIn("上述八组必须同时具有 `type: smart`", guide)
        self.assertIn("仓库中的 `cfg/Custom_Clash.ini` 仍以 `url-test` 定义 `🔙 送中节点`", guide)
        self.assertNotIn('ruby_arr_edit "$CONFIG_FILE"', guide)

    def test_compatibility_script_keeps_commands_times_and_new_mode_labels(self):
        script = (ROOT / "openclash-rule-bot" / "auto_proxy_switch.sh").read_text(encoding="utf-8")
        self.assertIn("auto_proxy_switch.sh chain", script)
        self.assertIn("auto_proxy_switch.sh smart", script)
        self.assertIn("0 1  * * *", script)
        self.assertIn("0 18 * * *", script)
        self.assertIn("白天机场→VPS", script)
        self.assertIn("夜间VPS优先", script)


if __name__ == "__main__":
    unittest.main()
