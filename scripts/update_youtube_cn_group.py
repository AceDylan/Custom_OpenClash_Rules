#!/usr/bin/env python3
"""
从 youtube_cn.txt 获取节点名称，更新 Custom_Clash.ini 中的 🔙 送中节点 分组
"""

import re
import urllib.request
from pathlib import Path


YOUTUBE_CN_URL = "https://raw.githubusercontent.com/AceDylan/clash-speedtest/main/youtube_cn.txt"
CONFIG_FILE = Path(__file__).parent.parent / "cfg" / "Custom_Clash.ini"


def fetch_node_names(url: str) -> list[str]:
    """从 URL 获取 TSV 格式的测速结果并提取成功的节点名称"""
    with urllib.request.urlopen(url, timeout=30) as response:
        content = response.read().decode("utf-8")

    lines = content.strip().split("\n")
    names = []

    # 跳过标题行
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) >= 1:
            node_name = parts[0].strip()
            if node_name:
                names.append(node_name)

    return names


def escape_regex(name: str) -> str:
    """转义正则表达式特殊字符"""
    special_chars = r"\.^$*+?{}[]()|-"
    result = ""
    for char in name:
        if char in special_chars:
            result += "\\" + char
        else:
            result += char
    return result


def build_regex_pattern(names: list[str]) -> str:
    """构建节点匹配的正则表达式"""
    if not names:
        return ""
    escaped_names = [escape_regex(name) for name in names]
    return "(" + "|".join(escaped_names) + ")"


def update_config(config_path: Path, pattern: str) -> bool:
    """更新配置文件中的 🔙 送中节点 分组"""
    content = config_path.read_text(encoding="utf-8")

    # 匹配 🔙 送中节点 分组行
    old_pattern = r"(custom_proxy_group=🔙 送中节点`url-test`)\([^)]+\)(`https://www\.gstatic\.com/generate_204`\d+)"
    new_line = rf"\g<1>{pattern}\g<2>"

    new_content, count = re.subn(old_pattern, new_line, content)

    if count == 0:
        print("未找到 🔙 送中节点 分组配置")
        return False

    config_path.write_text(new_content, encoding="utf-8")
    return True


def main():
    print(f"从 {YOUTUBE_CN_URL} 获取节点列表...")
    names = fetch_node_names(YOUTUBE_CN_URL)

    if not names:
        print("未获取到任何成功的节点")
        return

    print(f"获取到 {len(names)} 个成功的节点:")
    for name in names:
        print(f"  - {name}")

    pattern = build_regex_pattern(names)
    print(f"\n生成的正则表达式:\n{pattern}")

    print(f"\n更新配置文件: {CONFIG_FILE}")
    if update_config(CONFIG_FILE, pattern):
        print("更新成功!")
    else:
        print("更新失败!")


if __name__ == "__main__":
    main()
