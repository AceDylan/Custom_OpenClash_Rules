#!/usr/bin/env python3
"""
从 youtube_cn.txt 获取节点名称，更新 Custom_Clash.ini 中的 🔙 送中节点 分组
同时从对应地区节点分组中排除这些送中节点

用法:
    python update_youtube_cn_group.py                       # 从 GitHub 获取
    python update_youtube_cn_group.py --local /path/to/youtube_cn.txt  # 从本地文件获取
    python update_youtube_cn_group.py --local /path/to/youtube_cn.txt --config /path/to/Custom_Clash.ini
"""

import argparse
import re
import sys
import urllib.request
from pathlib import Path


YOUTUBE_CN_URL = "https://raw.githubusercontent.com/AceDylan/clash-speedtest/main/youtube_cn.txt"
CONFIG_FILE = Path(__file__).parent.parent / "cfg" / "Custom_Clash.ini"

# 地区关键词映射：地区名 -> (INI中的分组名, 匹配关键词列表)
# 只更新香港、美国、新加坡、日本这四个地区的节点分组
REGION_MAPPING = {
    "香港": ("🇭🇰 香港节点", ["香港", "hk", "hong kong", "hongkong"]),
    "日本": ("🇯🇵 日本节点", ["日本", "jp", "japan", "tokyo", "osaka"]),
    "美国": ("🇺🇸 美国节点", ["美国", "us", "usa", "america", "united states"]),
    "新加坡": ("🇸🇬 新加坡节点", ["新加坡", "sg", "singapore"]),
}


def parse_node_names(content: str) -> list[str]:
    """从 TSV 格式内容中解析节点名称"""
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


def fetch_remote_content(url: str) -> str:
    """从远程 URL 获取内容"""
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode("utf-8")


def read_local_file(path: str) -> str:
    """读取本地文件内容"""
    file_path = Path(path)
    if not file_path.exists():
        raise FileNotFoundError(f"文件不存在: {path}")
    return file_path.read_text(encoding="utf-8")


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


def categorize_nodes_by_region(names: list[str]) -> dict[str, list[str]]:
    """按地区分类节点名称

    Returns:
        dict: {地区名: [节点名称列表]}
    """
    region_nodes: dict[str, list[str]] = {region: [] for region in REGION_MAPPING}

    for name in names:
        name_lower = name.lower()
        for region, (_, keywords) in REGION_MAPPING.items():
            if any(kw.lower() in name_lower for kw in keywords):
                region_nodes[region].append(name)
                break  # 每个节点只归属一个地区

    return region_nodes


def build_exclude_pattern(region_keyword: str, exclude_nodes: list[str]) -> str:
    """构建带排除的正则表达式

    Args:
        region_keyword: 地区关键词，如 "香港"
        exclude_nodes: 要排除的节点名称列表

    Returns:
        带负向前瞻的正则表达式，格式: ^(?!.*(node1|node2)).*(?i)地区
    """
    if not exclude_nodes:
        # 无排除时返回简单匹配
        return f"(.*((?i){region_keyword}))"

    # 构建排除部分：^(?!.*(node1|node2|...))
    # 关键：前瞻内部需要 .* 来检查整个字符串
    escaped_nodes = [escape_regex(name) for name in exclude_nodes]
    exclude_part = "^(?!.*(" + "|".join(escaped_nodes) + "))"

    # 完整正则：^(?!.*(排除节点)).*(?i)地区关键词
    return f"{exclude_part}.*(?i){region_keyword}"


def update_region_groups(config_path: Path, region_nodes: dict[str, list[str]]) -> int:
    """更新地区节点分组，排除送中节点

    Args:
        config_path: 配置文件路径
        region_nodes: {地区名: [要排除的节点列表]}

    Returns:
        更新的分组数量
    """
    content = config_path.read_text(encoding="utf-8")
    lines = content.split("\n")
    updated_count = 0

    for region, exclude_nodes in region_nodes.items():
        if not exclude_nodes:
            continue

        group_name, keywords = REGION_MAPPING[region]
        # 使用第一个关键词（中文）来匹配
        region_keyword = keywords[0]

        # 查找并更新对应的行
        for i, line in enumerate(lines):
            if not line.startswith(f"custom_proxy_group={group_name}`url-test`"):
                continue

            # 找到了对应行，解析并重建
            # 格式: custom_proxy_group=🇭🇰 香港节点`url-test`REGEX`https://www.gstatic.com/generate_204`120
            parts = line.split("`")
            if len(parts) < 4:
                print(f"  警告: {group_name} 行格式不正确")
                continue

            # parts[0] = "custom_proxy_group=🇭🇰 香港节点"
            # parts[1] = "url-test"
            # parts[2] = 正则表达式
            # parts[3] = "https://www.gstatic.com/generate_204"
            # parts[4] = "120"

            # 构建新的带排除的正则
            new_regex = build_exclude_pattern(region_keyword, exclude_nodes)

            # 重建该行
            parts[2] = new_regex
            lines[i] = "`".join(parts)
            updated_count += 1
            print(f"  已更新 {group_name}，排除 {len(exclude_nodes)} 个节点")
            break

    if updated_count > 0:
        config_path.write_text("\n".join(lines), encoding="utf-8")

    return updated_count


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


def main() -> int:
    """主函数，返回退出码: 0 成功, 1 失败"""
    parser = argparse.ArgumentParser(
        description="更新 Custom_Clash.ini 中的 🔙 送中节点 分组，并从地区分组中排除这些节点"
    )
    parser.add_argument(
        "--local",
        type=str,
        metavar="PATH",
        help="从本地文件读取 youtube_cn.txt，而不是从 GitHub 获取"
    )
    parser.add_argument(
        "--config",
        type=str,
        metavar="PATH",
        help="指定 Custom_Clash.ini 配置文件路径"
    )
    args = parser.parse_args()

    config_path = Path(args.config) if args.config else CONFIG_FILE

    # 获取内容
    try:
        if args.local:
            print(f"从本地文件读取: {args.local}")
            content = read_local_file(args.local)
        else:
            print(f"从 {YOUTUBE_CN_URL} 获取节点列表...")
            content = fetch_remote_content(YOUTUBE_CN_URL)
    except FileNotFoundError as e:
        print(f"错误: {e}")
        return 1
    except Exception as e:
        print(f"获取数据失败: {e}")
        return 1

    # 解析节点名称
    names = parse_node_names(content)

    if not names:
        print("未获取到任何成功的节点")
        return 1

    print(f"获取到 {len(names)} 个成功的节点:")
    for name in names:
        print(f"  - {name}")

    # 按地区分类节点
    region_nodes = categorize_nodes_by_region(names)
    print("\n按地区分类:")
    for region, nodes in region_nodes.items():
        if nodes:
            print(f"  {region}: {len(nodes)} 个节点")
            for node in nodes:
                print(f"    - {node}")

    pattern = build_regex_pattern(names)
    print(f"\n生成的送中节点正则表达式:\n{pattern}")

    print(f"\n更新配置文件: {config_path}")

    # 1. 更新送中节点分组
    print("\n[1/2] 更新 🔙 送中节点 分组...")
    if not update_config(config_path, pattern):
        print("更新送中节点分组失败!")
        return 1
    print("送中节点分组更新成功!")

    # 2. 从地区分组中排除送中节点
    print("\n[2/2] 从地区节点分组中排除送中节点...")
    updated_regions = update_region_groups(config_path, region_nodes)
    if updated_regions > 0:
        print(f"已更新 {updated_regions} 个地区分组")
    else:
        print("无需更新地区分组（没有匹配到地区的送中节点）")

    print("\n全部更新完成!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
