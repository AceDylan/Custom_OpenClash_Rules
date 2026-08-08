from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
INI_PATH = ROOT / "cfg" / "Custom_Clash.ini"

SMART_TO_AIRPORT = {
    "🇭🇰 香港智能": "🇭🇰 香港节点",
    "🇺🇸 美国智能": "🇺🇸 美国节点",
    "🇸🇬 新加坡智能": "🇸🇬 新加坡节点",
    "🇯🇵 日本智能": "🇯🇵 日本节点",
}


def proxy_group_lines():
    lines = []
    for raw_line in INI_PATH.read_text(encoding="utf-8").splitlines():
        if not raw_line.startswith("custom_proxy_group="):
            continue
        definition = raw_line.split("=", 1)[1]
        fields = definition.split("`")
        lines.append((fields[0], fields, raw_line))
    return lines


class CustomClashIniTests(unittest.TestCase):
    def test_application_defaults_are_unchanged(self):
        definitions = {name: fields for name, fields, _ in proxy_group_lines()}
        expected_defaults = {
            "💬 社交媒体": "🇭🇰 香港智能",
            "🎥 流媒体": "🇭🇰 香港智能",
            "🎬 影音娱乐": "🔙 送中组",
            "🇬 谷歌与AI": "🇺🇸 美国智能",
            "🐟 漏网之鱼": "🇭🇰 香港智能",
            "🛠️ 系统与测速": "🎯 全球直连",
        }

        for application, expected_default in expected_defaults.items():
            self.assertEqual(f"[]{expected_default}", definitions[application][2])

    def test_application_smart_options_also_offer_matching_airport_group(self):
        definitions = {name: fields for name, fields, _ in proxy_group_lines()}
        application_groups = (
            "💬 社交媒体",
            "🎥 流媒体",
            "🎬 影音娱乐",
            "🇬 谷歌与AI",
            "🐟 漏网之鱼",
            "🛠️ 系统与测速",
        )

        for application in application_groups:
            options = {field[2:] for field in definitions[application] if field.startswith("[]")}
            for smart_group, airport_group in SMART_TO_AIRPORT.items():
                if smart_group in options:
                    self.assertIn(
                        airport_group,
                        options,
                        f"{application} offers {smart_group} but not {airport_group}",
                    )

    def test_all_literal_proxy_group_references_are_defined(self):
        definitions = proxy_group_lines()
        defined = {name for name, _, _ in definitions}
        special_values = {"DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"}
        missing = []

        for owner, fields, _ in definitions:
            for field in fields:
                if not field.startswith("[]"):
                    continue
                reference = field[2:]
                if reference not in defined and reference not in special_values:
                    missing.append((owner, reference))

        self.assertEqual([], missing)

    def test_send_to_china_node_remains_url_test(self):
        definitions = {name: fields for name, fields, _ in proxy_group_lines()}
        self.assertEqual("url-test", definitions["🔙 送中节点"][1])

    def test_regional_smart_groups_keep_manual_then_airport_fallback_topology(self):
        definitions = {name: fields for name, fields, _ in proxy_group_lines()}
        regions = {
            "🇭🇰 香港智能": ("🇭🇰 香港手选", "🇭🇰 香港节点"),
            "🇺🇸 美国智能": ("🇺🇸 美国手选", "🇺🇸 美国节点"),
            "🇸🇬 新加坡智能": ("🇸🇬 新加坡手选", "🇸🇬 新加坡节点"),
            "🇯🇵 日本智能": ("🇯🇵 日本手选", "🇯🇵 日本节点"),
        }

        for smart_group, (manual_group, airport_group) in regions.items():
            fields = definitions[smart_group]
            self.assertEqual("fallback", fields[1])
            self.assertEqual(f"[]{manual_group}", fields[2])
            self.assertEqual(f"[]{airport_group}", fields[3])


if __name__ == "__main__":
    unittest.main()
