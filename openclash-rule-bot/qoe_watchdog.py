"""Conservative one-shot QoE decisions for the OpenClash rule bot.

The module deliberately knows nothing about Telegram or ``requests``.  A small
controller adapter in the generated bot supplies OpenClash API operations, which
keeps the state machine independently testable and avoids duplicated logic.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import tempfile
import time
from typing import Any, Callable, Protocol, Sequence


DEFAULT_APPLICATION_GROUPS = (
    "💬 社交媒体",
    "🎥 流媒体",
    "🎬 影音娱乐",
    "🇬 谷歌与AI",
    "🐟 漏网之鱼",
    "🛠️ 系统与测速",
)

SMART_TO_AIRPORT = {
    "🇭🇰 香港智能": "🇭🇰 香港节点",
    "🇺🇸 美国智能": "🇺🇸 美国节点",
    "🇸🇬 新加坡智能": "🇸🇬 新加坡节点",
    "🇯🇵 日本智能": "🇯🇵 日本节点",
}
AIRPORT_TO_SMART = {airport: smart for smart, airport in SMART_TO_AIRPORT.items()}

CHAIN_TO_AIRPORT = {
    "🔗 链式日本": "✈️ 机场日本",
    "🔗 链式新加坡": "✈️ 机场新加坡",
    "🔗 链式美国": "✈️ 机场前置",
}

SEND_TO_CHINA_SELECTOR = "🔙 送中组"
SEND_TO_CHINA_NODE = "🔙 送中节点"


class Controller(Protocol):
    def get_proxy(self, name: str) -> dict[str, Any] | None: ...

    def set_proxy(self, group: str, option: str) -> bool: ...

    def probe_delay(self, name: str, url: str, timeout_ms: int) -> float | None: ...

    def get_connections(self) -> list[dict[str, Any]]: ...

    def delete_connection(self, connection_id: str) -> bool: ...


@dataclass(frozen=True)
class QoEConfig:
    application_groups: tuple[str, ...] = DEFAULT_APPLICATION_GROUPS
    probe_url: str = "https://www.gstatic.com/generate_204"
    probe_timeout_ms: int = 5_000
    high_delay_ms: int = 1_500
    night_failure_strikes: int = 3
    night_recovery_passes: int = 5
    night_min_hold_seconds: int = 10 * 60
    day_sample_seconds: float = 2.0
    day_low_rate_bps: int = 3 * 1024 * 1024
    day_failure_strikes: int = 3
    day_cooldown_seconds: int = 10 * 60

    @classmethod
    def from_env(
        cls,
        application_groups: Sequence[str] = DEFAULT_APPLICATION_GROUPS,
    ) -> "QoEConfig":
        """Build configuration from optional container environment overrides."""

        return cls(
            application_groups=tuple(application_groups),
            probe_url=os.getenv("QOE_PROBE_URL", cls.probe_url),
            probe_timeout_ms=_positive_int_env("QOE_PROBE_TIMEOUT_MS", cls.probe_timeout_ms),
            high_delay_ms=_positive_int_env("QOE_HIGH_DELAY_MS", cls.high_delay_ms),
            night_failure_strikes=_positive_int_env(
                "QOE_NIGHT_FAILURE_STRIKES", cls.night_failure_strikes
            ),
            night_recovery_passes=_positive_int_env(
                "QOE_NIGHT_RECOVERY_PASSES", cls.night_recovery_passes
            ),
            night_min_hold_seconds=_positive_int_env(
                "QOE_NIGHT_MIN_HOLD_SECONDS", cls.night_min_hold_seconds
            ),
            day_sample_seconds=_positive_float_env(
                "QOE_DAY_SAMPLE_SECONDS", cls.day_sample_seconds
            ),
            day_low_rate_bps=_positive_int_env("QOE_DAY_LOW_RATE_BPS", cls.day_low_rate_bps),
            day_failure_strikes=_positive_int_env(
                "QOE_DAY_FAILURE_STRIKES", cls.day_failure_strikes
            ),
            day_cooldown_seconds=_positive_int_env(
                "QOE_DAY_COOLDOWN_SECONDS", cls.day_cooldown_seconds
            ),
        )


def _positive_int_env(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


def _positive_float_env(name: str, default: float) -> float:
    try:
        value = float(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


def default_state() -> dict[str, Any]:
    return {
        "version": 1,
        "night": {"failures": {}, "failovers": {}},
        "day": {"groups": {}},
        "send_to_china": {
            "active_applications": [],
            "mode": None,
            "degraded_count": 0,
            "last_degraded_action_at": 0,
        },
    }


def load_state(path: str | os.PathLike[str]) -> dict[str, Any]:
    """Load state, failing safely to an empty state if it is absent or invalid."""

    try:
        with open(path, "r", encoding="utf-8") as state_file:
            loaded = json.load(state_file)
    except (FileNotFoundError, OSError, ValueError, TypeError):
        return default_state()

    if not isinstance(loaded, dict):
        return default_state()

    state = default_state()
    night = loaded.get("night")
    if isinstance(night, dict):
        if isinstance(night.get("failures"), dict):
            state["night"]["failures"] = night["failures"]
        if isinstance(night.get("failovers"), dict):
            state["night"]["failovers"] = night["failovers"]
        for records in state["night"].values():
            for record in records.values():
                if isinstance(record, dict) and "probe_group" not in record:
                    smart_group = record.get("smart_group")
                    if isinstance(smart_group, str) and smart_group:
                        record["probe_group"] = smart_group
                        record.pop("vps_node", None)
    day = loaded.get("day")
    if isinstance(day, dict) and isinstance(day.get("groups"), dict):
        state["day"]["groups"] = day["groups"]

    send_to_china = loaded.get("send_to_china")
    if isinstance(send_to_china, dict):
        applications = send_to_china.get("active_applications")
        if isinstance(applications, list):
            state["send_to_china"]["active_applications"] = sorted(
                item for item in applications if isinstance(item, str) and item
            )
        mode = send_to_china.get("mode")
        if mode in ("day", "night"):
            state["send_to_china"]["mode"] = mode
        try:
            degraded_count = int(send_to_china.get("degraded_count") or 0)
        except (TypeError, ValueError):
            degraded_count = 0
        state["send_to_china"]["degraded_count"] = max(0, degraded_count)
        try:
            last_action_at = float(send_to_china.get("last_degraded_action_at") or 0)
        except (TypeError, ValueError):
            last_action_at = 0
        state["send_to_china"]["last_degraded_action_at"] = (
            max(0.0, last_action_at) if math.isfinite(last_action_at) else 0.0
        )
    return state


def atomic_write_json(path: str | os.PathLike[str], value: dict[str, Any]) -> None:
    """Durably replace a JSON file without exposing a partially written state."""

    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        suffix=".tmp",
        dir=str(destination.parent),
    )
    try:
        os.fchmod(file_descriptor, 0o600)
        state_file = os.fdopen(file_descriptor, "w", encoding="utf-8")
        file_descriptor = -1
        with state_file:
            json.dump(value, state_file, ensure_ascii=False, indent=2, sort_keys=True)
            state_file.write("\n")
            state_file.flush()
            os.fsync(state_file.fileno())
        os.replace(temporary_name, destination)
        temporary_name = ""
        try:
            directory_fd = os.open(destination.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            # The file replacement is still atomic on filesystems that do not
            # permit fsync on a directory (some router overlay filesystems).
            pass
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def connection_matches_group(connection: dict[str, Any], group: str) -> bool:
    chains = connection.get("chains") or []
    if isinstance(chains, str):
        chains = [chains]
    return group in chains


def _connection_downloads(
    connections: Sequence[dict[str, Any]],
    group: str,
) -> dict[str, int]:
    downloads: dict[str, int] = {}
    for connection in connections:
        if not isinstance(connection, dict) or not connection_matches_group(connection, group):
            continue
        connection_id = connection.get("id")
        if connection_id in (None, ""):
            continue
        try:
            downloaded = int(connection.get("download") or 0)
        except (TypeError, ValueError):
            downloaded = 0
        downloads[str(connection_id)] = max(0, downloaded)
    return downloads


def stable_download_rate(
    first: Sequence[dict[str, Any]],
    second: Sequence[dict[str, Any]],
    group: str,
    elapsed_seconds: float,
) -> tuple[float | None, set[str]]:
    """Return aggregate bytes/sec and second-sample IDs for stable connections."""

    first_downloads = _connection_downloads(first, group)
    second_downloads = _connection_downloads(second, group)
    stable_ids = set(first_downloads).intersection(second_downloads)
    if not stable_ids:
        return None, set(second_downloads)
    delta = sum(
        max(0, second_downloads[connection_id] - first_downloads[connection_id])
        for connection_id in stable_ids
    )
    return delta / max(float(elapsed_seconds), 0.001), set(second_downloads)


class QoEWatchdog:
    """Run one mode-aware QoE evaluation and persist all counters atomically."""

    def __init__(
        self,
        controller: Controller,
        state_path: str | os.PathLike[str],
        *,
        config: QoEConfig | None = None,
        wall_clock: Callable[[], float] = time.time,
        monotonic_clock: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        self.controller = controller
        self.state_path = Path(state_path)
        self.config = config or QoEConfig()
        self.wall_clock = wall_clock
        self.monotonic_clock = monotonic_clock
        self.sleeper = sleeper

    def run_once(self) -> dict[str, Any]:
        state = load_state(self.state_path)
        application_selections, unreadable_applications = self._application_selections()
        if unreadable_applications:
            # Without a complete selector snapshot the watchdog cannot safely
            # infer day/night mode. Break consecutive counters, keep failover
            # ownership records, and make no controller mutations.
            state["night"]["failures"].clear()
            for record in state["night"]["failovers"].values():
                if isinstance(record, dict):
                    record["healthy_count"] = 0
            for group_state in state["day"]["groups"].values():
                if isinstance(group_state, dict):
                    group_state["degraded_count"] = 0
            send_state = state["send_to_china"]
            send_state["degraded_count"] = 0
            send_state["active_applications"] = []
            send_state["mode"] = None
            send_state["leaf"] = None
            result = {
                "mode": "unknown",
                "actions": [],
                "notes": ["application selector snapshot incomplete"],
            }
            atomic_write_json(self.state_path, state)
            return result

        active_airports = {
            CHAIN_TO_AIRPORT[current]
            for current in application_selections.values()
            if current in CHAIN_TO_AIRPORT
        }
        result: dict[str, Any] = {
            "mode": "day" if active_airports else "night",
            "actions": [],
            "notes": [],
        }

        # A group that was not active in this run cannot retain a consecutive
        # degradation strike across a region or day/night mode change.
        for airport_group, group_state in state["day"]["groups"].items():
            if airport_group not in active_airports and isinstance(group_state, dict):
                group_state["degraded_count"] = 0

        samples = None
        if active_airports:
            samples = self._run_day(state, application_selections, active_airports, result)
        else:
            self._run_night(state, application_selections, result)

        self._run_send_to_china(
            state,
            application_selections,
            result["mode"],
            result,
            samples,
        )

        atomic_write_json(self.state_path, state)
        return result

    def _get_proxy(self, name: str) -> dict[str, Any] | None:
        try:
            value = self.controller.get_proxy(name)
        except Exception:
            return None
        return value if isinstance(value, dict) else None

    def _current_option(self, name: str) -> str | None:
        info = self._get_proxy(name)
        current = info.get("now") if info else None
        return current if isinstance(current, str) and current else None

    def _application_selections(self) -> tuple[dict[str, str], list[str]]:
        selections: dict[str, str] = {}
        unreadable: list[str] = []
        for application in self.config.application_groups:
            current = self._current_option(application)
            if current:
                selections[application] = current
            else:
                unreadable.append(application)
        return selections, unreadable

    def _probe(self, name: str) -> float | None:
        try:
            delay = self.controller.probe_delay(
                name,
                self.config.probe_url,
                self.config.probe_timeout_ms,
            )
            if delay is None or isinstance(delay, bool):
                return None
            delay_value = float(delay)
            return delay_value if delay_value >= 0 else None
        except (TypeError, ValueError, OSError, RuntimeError):
            return None
        except Exception:
            return None

    def _delay_is_bad(self, delay: float | None) -> bool:
        return delay is None or delay > self.config.high_delay_ms

    def _set_if_still_current(self, group: str, expected: str, target: str) -> bool:
        latest = self._get_proxy(group)
        if not latest or latest.get("now") != expected:
            return False
        options = latest.get("all")
        if not isinstance(options, list) or target not in options:
            return False
        try:
            return bool(self.controller.set_proxy(group, target))
        except Exception:
            return False

    def _run_night(
        self,
        state: dict[str, Any],
        application_selections: dict[str, str],
        result: dict[str, Any],
    ) -> None:
        now = float(self.wall_clock())
        failures = state["night"]["failures"]
        failovers = state["night"]["failovers"]

        for application in self.config.application_groups:
            current = application_selections.get(application)
            record = failovers.get(application)
            if isinstance(record, dict):
                airport_group = record.get("airport_group")
                smart_group = record.get("smart_group")
                probe_group = record.get("probe_group")

                # A selector that no longer points to the exact watchdog target
                # was changed by a user or another automation. Forget the record
                # and never use stale state to overwrite that choice.
                if current != airport_group:
                    failovers.pop(application, None)
                    failures.pop(application, None)
                    result["notes"].append(f"{application}: manual selection preserved")
                    continue

                if (
                    not all(
                        isinstance(value, str) and value
                        for value in (smart_group, probe_group)
                    )
                    or probe_group != smart_group
                ):
                    failovers.pop(application, None)
                    continue

                delay = self._probe(probe_group)
                if self._delay_is_bad(delay):
                    record["healthy_count"] = 0
                    continue

                healthy_count = int(record.get("healthy_count") or 0) + 1
                record["healthy_count"] = healthy_count
                failed_over_at = float(record.get("failed_over_at") or now)
                hold_complete = now - failed_over_at >= self.config.night_min_hold_seconds
                if healthy_count < self.config.night_recovery_passes or not hold_complete:
                    continue

                if self._set_if_still_current(application, airport_group, smart_group):
                    result["actions"].append(
                        f"{application}: {airport_group} → {smart_group} (VPS recovered)"
                    )
                    failovers.pop(application, None)
                else:
                    # Re-read failure means the user raced this run or the target
                    # disappeared; either case must not be retried from stale state.
                    if self._current_option(application) != airport_group:
                        failovers.pop(application, None)
                continue

            if current not in SMART_TO_AIRPORT:
                failures.pop(application, None)
                continue

            smart_group = current
            airport_group = SMART_TO_AIRPORT[smart_group]
            probe_group = smart_group
            delay = self._probe(probe_group)
            if not self._delay_is_bad(delay):
                failures.pop(application, None)
                continue

            previous = failures.get(application)
            same_probe_target = (
                isinstance(previous, dict)
                and previous.get("smart_group") == smart_group
                and previous.get("probe_group") == probe_group
            )
            failure_count = int(previous.get("count") or 0) + 1 if same_probe_target else 1
            failures[application] = {
                "smart_group": smart_group,
                "probe_group": probe_group,
                "count": failure_count,
            }
            if failure_count < self.config.night_failure_strikes:
                continue

            if self._set_if_still_current(application, smart_group, airport_group):
                failovers[application] = {
                    "smart_group": smart_group,
                    "airport_group": airport_group,
                    "probe_group": probe_group,
                    "failed_over_at": now,
                    "healthy_count": 0,
                }
                failures.pop(application, None)
                result["actions"].append(
                    f"{application}: {smart_group} → {airport_group} (VPS degraded)"
                )
            elif self._current_option(application) != smart_group:
                failures.pop(application, None)

    def _airport_still_active(self, airport_group: str) -> bool:
        for application in self.config.application_groups:
            current = self._current_option(application)
            if current in CHAIN_TO_AIRPORT and CHAIN_TO_AIRPORT[current] == airport_group:
                return True
        return False

    def _run_day(
        self,
        state: dict[str, Any],
        application_selections: dict[str, str],
        active_airports: set[str],
        result: dict[str, Any],
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]], float] | None:
        del application_selections  # Mode was derived from this immutable snapshot.
        group_states = state["day"]["groups"]
        now = float(self.wall_clock())

        samples = self._sample_connections()
        if samples is None:
            for airport_group in active_airports:
                group_state = self._day_group_state(group_states, airport_group)
                group_state["degraded_count"] = 0
            result["notes"].append("connection sampling unavailable")
            return None
        first, second, elapsed = samples

        deleted_ids: set[str] = set()
        for airport_group in sorted(active_airports):
            group_state = self._day_group_state(group_states, airport_group)
            rate_bps, second_ids = stable_download_rate(
                first,
                second,
                airport_group,
                elapsed,
            )
            if rate_bps is None:
                group_state["degraded_count"] = 0
                result["notes"].append(f"{airport_group}: no stable active samples")
                continue

            if rate_bps >= self.config.day_low_rate_bps:
                group_state["degraded_count"] = 0
                continue

            delay = self._probe(airport_group)
            if not self._delay_is_bad(delay):
                group_state["degraded_count"] = 0
                continue

            degraded_count = int(group_state.get("degraded_count") or 0) + 1
            group_state["degraded_count"] = degraded_count
            if degraded_count < self.config.day_failure_strikes:
                continue

            last_action_at = float(group_state.get("last_action_at") or 0)
            if last_action_at > 0 and now - last_action_at < self.config.day_cooldown_seconds:
                continue
            if not self._airport_still_active(airport_group):
                group_state["degraded_count"] = 0
                result["notes"].append(f"{airport_group}: mode changed during sampling")
                continue

            cleared = 0
            failed = 0
            for connection_id in sorted(second_ids - deleted_ids):
                try:
                    succeeded = bool(self.controller.delete_connection(connection_id))
                except Exception:
                    succeeded = False
                if succeeded:
                    cleared += 1
                else:
                    failed += 1
                deleted_ids.add(connection_id)

            group_state["degraded_count"] = 0
            group_state["last_action_at"] = now
            if cleared:
                result["actions"].append(
                    f"{airport_group}: reset {cleared} matching connection(s), {failed} failed"
                )

        return first, second, elapsed

    def _sample_connections(
        self,
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]], float] | None:
        try:
            first = self.controller.get_connections()
            if not isinstance(first, list):
                raise TypeError("connections response is not a list")
            sample_started = self.monotonic_clock()
            self.sleeper(self.config.day_sample_seconds)
            second = self.controller.get_connections()
            if not isinstance(second, list):
                raise TypeError("connections response is not a list")
            return first, second, self.monotonic_clock() - sample_started
        except Exception:
            return None

    def _application_snapshot_unchanged(
        self,
        expected: dict[str, str],
    ) -> bool:
        current, unreadable = self._application_selections()
        return not unreadable and current == expected

    @staticmethod
    def _matching_connection_ids(
        connections: Sequence[dict[str, Any]],
        group: str,
    ) -> set[str]:
        return set(_connection_downloads(connections, group))

    def _delete_matching_connections(
        self,
        connection_ids: set[str],
    ) -> tuple[int, int]:
        cleared = 0
        failed = 0
        for connection_id in sorted(connection_ids):
            try:
                succeeded = bool(self.controller.delete_connection(connection_id))
            except Exception:
                succeeded = False
            if succeeded:
                cleared += 1
            else:
                failed += 1
        return cleared, failed

    def _run_send_to_china(
        self,
        state: dict[str, Any],
        application_selections: dict[str, str],
        mode: str,
        result: dict[str, Any],
        samples: tuple[list[dict[str, Any]], list[dict[str, Any]], float] | None,
    ) -> None:
        send_state = state["send_to_china"]
        active_applications = sorted(
            application
            for application, current in application_selections.items()
            if current == SEND_TO_CHINA_SELECTOR
        )
        previous_applications = send_state.get("active_applications", [])
        if not isinstance(previous_applications, list):
            previous_applications = []
        previous_mode = send_state.get("mode")
        has_previous_context = bool(previous_applications) or previous_mode in ("day", "night")
        context_changed = has_previous_context and (
            previous_applications != active_applications or previous_mode != mode
        )
        send_state["active_applications"] = active_applications
        send_state["mode"] = mode if active_applications else None

        if not active_applications:
            send_state["degraded_count"] = 0
            return
        if not has_previous_context or context_changed:
            # Establish a baseline on first activation or after topology/app changes.
            send_state["degraded_count"] = 0
            return
        if samples is None:
            samples = self._sample_connections()
        if samples is None:
            send_state["degraded_count"] = 0
            result["notes"].append("send-to-China connection sampling unavailable")
            return

        first, second, elapsed = samples
        rate_bps, second_ids = stable_download_rate(
            first,
            second,
            SEND_TO_CHINA_NODE,
            elapsed,
        )
        if rate_bps is None:
            send_state["degraded_count"] = 0
            result["notes"].append(f"{SEND_TO_CHINA_NODE}: no stable active samples")
            return
        if rate_bps >= self.config.day_low_rate_bps:
            send_state["degraded_count"] = 0
            return

        delay = self._probe(SEND_TO_CHINA_NODE)
        if not self._delay_is_bad(delay):
            send_state["degraded_count"] = 0
            return

        degraded_count = int(send_state.get("degraded_count") or 0) + 1
        send_state["degraded_count"] = degraded_count
        if degraded_count < self.config.day_failure_strikes:
            return

        now = float(self.wall_clock())
        last_action_at = float(send_state.get("last_degraded_action_at") or 0)
        if last_action_at > 0 and now - last_action_at < self.config.day_cooldown_seconds:
            return
        if not self._application_snapshot_unchanged(application_selections):
            send_state["degraded_count"] = 0
            result["notes"].append("send-to-China selector changed during sampling")
            return

        cleared, failed = self._delete_matching_connections(second_ids)
        send_state["degraded_count"] = 0
        if cleared:
            send_state["last_degraded_action_at"] = now
            result["actions"].append(
                f"{SEND_TO_CHINA_NODE}: degraded QoE, reset {cleared} matching "
                f"connection(s), {failed} failed"
            )

    @staticmethod
    def _day_group_state(group_states: dict[str, Any], airport_group: str) -> dict[str, Any]:
        value = group_states.get(airport_group)
        if not isinstance(value, dict):
            value = {}
            group_states[airport_group] = value
        value.setdefault("degraded_count", 0)
        value.setdefault("last_action_at", 0)
        return value


def format_watchdog_result(result: dict[str, Any]) -> str:
    """Return a shell-friendly concise result; only ACTION lines need Telegram."""

    mode_labels = {
        "day": "白天链式",
        "night": "夜间VPS优先",
        "unknown": "模式未确定",
    }
    mode_label = mode_labels.get(result.get("mode"), "模式未确定")
    actions = result.get("actions") or []
    if actions:
        return f"ACTION|QoE watchdog（{mode_label}）：" + "; ".join(str(item) for item in actions)
    return f"OK|QoE watchdog（{mode_label}）：检查完成，无动作"
