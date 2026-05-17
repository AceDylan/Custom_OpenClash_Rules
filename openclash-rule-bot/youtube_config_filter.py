from __future__ import annotations

import copy
import hashlib
import os
import re
from typing import Any, Iterable

import requests
import yaml


UNSUPPORTED_PROXY_TYPES_ENV = "YOUTUBE_CHECK_UNSUPPORTED_PROXY_TYPES"
DEFAULT_UNSUPPORTED_PROXY_TYPES = set()
DOWNLOAD_TIMEOUT_SECONDS = 60


def sanitize_clash_config_for_youtube_check(
    config: Any,
    unsupported_proxy_types: Iterable[str] | None = None,
) -> tuple[Any, list[str]]:
    """移除当前检测工具仍不支持的代理类型。"""
    unsupported_types = _normalize_proxy_types(unsupported_proxy_types)
    if not unsupported_types:
        return copy.deepcopy(config), []

    if not isinstance(config, dict):
        return config, []

    proxies = config.get("proxies")
    if not isinstance(proxies, list):
        return copy.deepcopy(config), []

    sanitized = copy.deepcopy(config)
    filtered_proxies = []
    removed_names = []
    removed_reference_names = set()

    for index, proxy in enumerate(sanitized.get("proxies", []), start=1):
        if not isinstance(proxy, dict):
            filtered_proxies.append(proxy)
            continue

        proxy_type = str(proxy.get("type", "")).strip().lower()
        if proxy_type not in unsupported_types:
            filtered_proxies.append(proxy)
            continue

        proxy_name = proxy.get("name")
        if isinstance(proxy_name, str) and proxy_name:
            removed_names.append(proxy_name)
            removed_reference_names.add(proxy_name)
        else:
            removed_names.append(f"proxy #{index}")

    if not removed_names:
        return sanitized, []

    sanitized["proxies"] = filtered_proxies

    proxy_groups = sanitized.get("proxy-groups")
    if isinstance(proxy_groups, list) and removed_reference_names:
        for group in proxy_groups:
            if not isinstance(group, dict):
                continue

            group_proxies = group.get("proxies")
            if not isinstance(group_proxies, list):
                continue

            group["proxies"] = [
                proxy_name
                for proxy_name in group_proxies
                if proxy_name not in removed_reference_names
            ]

    return sanitized, removed_names


def prepare_youtube_check_config(
    source_url: str,
    work_dir: str,
    provider: str,
    logger=None,
) -> tuple[str, list[str]]:
    """必要时生成兼容 youtube-check.go 的临时 Clash 配置。"""
    try:
        response = requests.get(source_url, timeout=DOWNLOAD_TIMEOUT_SECONDS)
        response.raise_for_status()
        config = yaml.safe_load(response.text)
    except Exception as exc:
        if logger:
            logger.warning(f"预处理订阅配置失败，沿用原始 URL: {exc}")
        return source_url, []

    sanitized_config, removed_names = sanitize_clash_config_for_youtube_check(
        config,
        _unsupported_proxy_types_from_env(),
    )
    if not removed_names:
        return source_url, []

    remaining_proxies = sanitized_config.get("proxies") if isinstance(sanitized_config, dict) else None
    if isinstance(remaining_proxies, list) and not remaining_proxies:
        raise ValueError("过滤 anytls 节点后没有剩余可测试节点")

    os.makedirs(work_dir, exist_ok=True)
    config_path = os.path.join(work_dir, _build_config_filename(source_url, provider))
    with open(config_path, "w", encoding="utf-8") as config_file:
        yaml.safe_dump(sanitized_config, config_file, allow_unicode=True, sort_keys=False)

    if logger:
        logger.info(
            f"已为油管解锁测试过滤 {len(removed_names)} 个不支持的代理节点: "
            f"{', '.join(removed_names[:10])}"
        )

    return config_path, removed_names


def _build_config_filename(source_url: str, provider: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", provider).strip("._-") or "provider"
    digest = hashlib.sha256(f"{provider}\n{source_url}".encode("utf-8")).hexdigest()[:12]
    return f"youtube_check_{slug}_{digest}.yaml"


def _unsupported_proxy_types_from_env() -> set[str]:
    configured_types = os.getenv(UNSUPPORTED_PROXY_TYPES_ENV)
    if configured_types is None:
        return set(DEFAULT_UNSUPPORTED_PROXY_TYPES)
    return _normalize_proxy_types(configured_types.split(","))


def _normalize_proxy_types(proxy_types: Iterable[str] | None) -> set[str]:
    if proxy_types is None:
        return set(DEFAULT_UNSUPPORTED_PROXY_TYPES)

    return {
        str(proxy_type).strip().lower()
        for proxy_type in proxy_types
        if str(proxy_type).strip()
    }
