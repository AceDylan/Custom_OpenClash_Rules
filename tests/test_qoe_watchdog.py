import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "openclash-rule-bot"))

from qoe_watchdog import (  # noqa: E402
    AIRPORT_TO_SMART,
    CHAIN_TO_AIRPORT,
    SMART_TO_AIRPORT,
    QoEConfig,
    QoEWatchdog,
    atomic_write_json,
    load_state,
)


APP = "💬 社交媒体"
SEND_APP = "🎬 影音娱乐"
SEND_SELECTOR = "🔙 送中组"
SEND_NODE = "🔙 送中节点"
SMART = "🇺🇸 美国智能"
AIRPORT = "🇺🇸 美国节点"
MANUAL = "🇺🇸 美国手选"
UNADDRESSABLE_BEST = "BEST | 美国 VPS"
CHAIN = "🔗 链式美国"
FRONT = "✈️ 机场前置"


class FakeController:
    def __init__(self, groups, delays=None, connection_samples=None):
        self.groups = groups
        self.delays = delays or {}
        self.connection_samples = list(connection_samples or [])
        self.selections = []
        self.probes = []
        self.deleted = []

    def get_proxy(self, name):
        value = self.groups.get(name)
        return dict(value) if value is not None else None

    def set_proxy(self, group, option):
        self.selections.append((group, option))
        self.groups[group]["now"] = option
        return True

    def probe_delay(self, name, url, timeout_ms):
        self.probes.append((name, url, timeout_ms))
        value = self.delays.get(name)
        if isinstance(value, Exception):
            raise value
        return value

    def get_connections(self):
        if not self.connection_samples:
            return []
        return self.connection_samples.pop(0)

    def delete_connection(self, connection_id):
        self.deleted.append(str(connection_id))
        return True


class MutableClock:
    def __init__(self, value):
        self.value = float(value)

    def __call__(self):
        return self.value

    def sleep(self, seconds):
        self.value += seconds


def night_groups():
    return {
        APP: {"now": SMART, "all": [SMART, AIRPORT]},
        SMART: {"now": MANUAL, "all": [MANUAL, AIRPORT]},
        MANUAL: {"now": UNADDRESSABLE_BEST, "all": [UNADDRESSABLE_BEST]},
    }


def low_rate_samples(target_group=FRONT):
    return [
        [
            {
                "id": "target",
                "download": 10 * 1024 * 1024,
                "start": "1970-01-01T00:15:00Z",
                "chains": [target_group],
            },
            {"id": "other", "download": 20, "chains": ["✈️ 机场日本"]},
        ],
        [
            {
                "id": "target",
                "download": 12 * 1024 * 1024,
                "start": "1970-01-01T00:15:00Z",
                "chains": [target_group],
            },
            {"id": "other", "download": 40, "chains": ["✈️ 机场日本"]},
        ],
    ]


def throttled_flow_samples(target_group=FRONT, *, include_small_web=False):
    first = [
        {
            "id": "sustained",
            "download": 8 * 1024 * 1024,
            "start": "1970-01-01T00:15:00Z",
            "chains": [target_group],
        }
    ]
    second = [
        {
            "id": "sustained",
            "download": 8 * 1024 * 1024 + 512 * 1024,
            "start": "1970-01-01T00:15:00Z",
            "chains": [target_group],
        }
    ]
    if include_small_web:
        first.append(
            {
                "id": "small-web",
                "download": 64 * 1024,
                "start": "1970-01-01T00:15:00Z",
                "chains": [target_group],
            }
        )
        second.append(
            {
                "id": "small-web",
                "download": 96 * 1024,
                "start": "1970-01-01T00:15:00Z",
                "chains": [target_group],
            }
        )
    return [first, second]


def small_web_samples(target_group=FRONT):
    return [
        [
            {
                "id": "small-web",
                "download": 64 * 1024,
                "start": "1970-01-01T00:15:00Z",
                "chains": [target_group],
            }
        ],
        [
            {
                "id": "small-web",
                "download": 96 * 1024,
                "start": "1970-01-01T00:15:00Z",
                "chains": [target_group],
            }
        ],
    ]


def zero_progress_samples(target_group=FRONT):
    first = {
        "id": "idle",
        "download": 8 * 1024 * 1024,
        "start": "1970-01-01T00:15:00Z",
        "chains": [target_group],
    }
    second = dict(first)
    return [[first], [second]]


class QoEWatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.state_path = Path(self.temp_dir.name) / "qoe_watchdog.json"
        self.wall = MutableClock(1_000)
        self.mono = MutableClock(50)
        self.config = QoEConfig(application_groups=(APP,))

    def watchdog(self, controller):
        return QoEWatchdog(
            controller,
            self.state_path,
            config=self.config,
            wall_clock=self.wall,
            monotonic_clock=self.mono,
            sleeper=self.mono.sleep,
        )

    def test_region_and_chain_mappings(self):
        expected_smart = {
            "🇭🇰 香港智能": "🇭🇰 香港节点",
            "🇺🇸 美国智能": "🇺🇸 美国节点",
            "🇸🇬 新加坡智能": "🇸🇬 新加坡节点",
            "🇯🇵 日本智能": "🇯🇵 日本节点",
        }
        expected_chains = {
            "🔗 链式日本": "✈️ 机场日本",
            "🔗 链式新加坡": "✈️ 机场新加坡",
            "🔗 链式美国": "✈️ 机场前置",
        }
        self.assertEqual(expected_smart, SMART_TO_AIRPORT)
        self.assertEqual({value: key for key, value in expected_smart.items()}, AIRPORT_TO_SMART)
        self.assertEqual(expected_chains, CHAIN_TO_AIRPORT)

    def test_night_failover_requires_three_consecutive_bad_probes(self):
        controller = FakeController(night_groups(), delays={SMART: None})
        watchdog = self.watchdog(controller)

        watchdog.run_once()
        watchdog.run_once()
        self.assertEqual([], controller.selections)

        result = watchdog.run_once()
        self.assertEqual([(APP, AIRPORT)], controller.selections)
        self.assertEqual("night", result["mode"])
        self.assertTrue(all(probe[0] == SMART for probe in controller.probes))
        state = load_state(self.state_path)
        self.assertEqual(SMART, state["night"]["failovers"][APP]["probe_group"])

    def test_night_healthy_smart_group_ignores_unaddressable_best_leaf(self):
        controller = FakeController(night_groups(), delays={SMART: 100})
        watchdog = self.watchdog(controller)

        for _ in range(3):
            watchdog.run_once()

        self.assertEqual([], controller.selections)
        self.assertEqual([SMART, SMART, SMART], [probe[0] for probe in controller.probes])
        self.assertNotIn(UNADDRESSABLE_BEST, [probe[0] for probe in controller.probes])
        self.assertNotIn(APP, load_state(self.state_path)["night"]["failures"])

    def test_night_recovery_requires_five_healthy_probes_and_hold_time(self):
        controller = FakeController(night_groups(), delays={SMART: 2_000})
        watchdog = self.watchdog(controller)
        for _ in range(3):
            watchdog.run_once()
        self.assertEqual(AIRPORT, controller.groups[APP]["now"])

        controller.delays[SMART] = 100
        for now in (1_100, 1_200, 1_300, 1_400):
            self.wall.value = now
            watchdog.run_once()
            self.assertEqual(AIRPORT, controller.groups[APP]["now"])

        self.wall.value = 1_600
        watchdog.run_once()
        self.assertEqual(SMART, controller.groups[APP]["now"])
        self.assertEqual((APP, SMART), controller.selections[-1])
        self.assertNotIn(APP, load_state(self.state_path)["night"]["failovers"])

    def test_legacy_active_failover_migrates_and_keeps_recovery_progress(self):
        groups = night_groups()
        groups[APP]["now"] = AIRPORT
        controller = FakeController(groups, delays={SMART: 100})
        atomic_write_json(
            self.state_path,
            {
                "version": 1,
                "night": {
                    "failures": {},
                    "failovers": {
                        APP: {
                            "smart_group": SMART,
                            "airport_group": AIRPORT,
                            "vps_node": UNADDRESSABLE_BEST,
                            "failed_over_at": 1_000,
                            "healthy_count": 2,
                        }
                    },
                },
                "day": {"groups": {}},
            },
        )
        watchdog = self.watchdog(controller)

        self.wall.value = 1_100
        watchdog.run_once()
        migrated = load_state(self.state_path)["night"]["failovers"][APP]
        self.assertEqual(SMART, migrated["probe_group"])
        self.assertNotIn("vps_node", migrated)
        self.assertEqual(3, migrated["healthy_count"])
        self.assertEqual(1_000, migrated["failed_over_at"])
        self.assertEqual(AIRPORT, controller.groups[APP]["now"])

        self.wall.value = 1_200
        watchdog.run_once()
        self.assertEqual(AIRPORT, controller.groups[APP]["now"])

        self.wall.value = 1_600
        watchdog.run_once()
        self.assertEqual(SMART, controller.groups[APP]["now"])
        self.assertEqual((APP, SMART), controller.selections[-1])
        self.assertNotIn(APP, load_state(self.state_path)["night"]["failovers"])
        self.assertEqual([SMART, SMART, SMART], [probe[0] for probe in controller.probes])
        self.assertNotIn(UNADDRESSABLE_BEST, [probe[0] for probe in controller.probes])

    def test_legacy_failure_migrates_and_keeps_strike_progress(self):
        controller = FakeController(night_groups(), delays={SMART: None})
        atomic_write_json(
            self.state_path,
            {
                "version": 1,
                "night": {
                    "failures": {
                        APP: {
                            "smart_group": SMART,
                            "vps_node": UNADDRESSABLE_BEST,
                            "count": 2,
                        }
                    },
                    "failovers": {},
                },
                "day": {"groups": {}},
            },
        )

        self.watchdog(controller).run_once()

        self.assertEqual([(APP, AIRPORT)], controller.selections)
        record = load_state(self.state_path)["night"]["failovers"][APP]
        self.assertEqual(SMART, record["probe_group"])
        self.assertNotIn("vps_node", record)
        self.assertEqual([SMART], [probe[0] for probe in controller.probes])
        self.assertNotIn(UNADDRESSABLE_BEST, [probe[0] for probe in controller.probes])

    def test_recorded_failover_never_overrides_a_manual_selection(self):
        controller = FakeController(night_groups(), delays={SMART: None})
        watchdog = self.watchdog(controller)
        for _ in range(3):
            watchdog.run_once()

        controller.groups[APP]["now"] = "🎯 全球直连"
        controller.delays[SMART] = 100
        selections_before = list(controller.selections)
        watchdog.run_once()

        self.assertEqual(selections_before, controller.selections)
        self.assertNotIn(APP, load_state(self.state_path)["night"]["failovers"])

    def test_send_to_china_activation_establishes_baseline_without_reset(self):
        groups = {
            SEND_APP: {"now": "🎯 全球直连", "all": [SEND_SELECTOR, "🎯 全球直连"]},
            SEND_NODE: {"now": "Smart - Select", "all": ["send-leaf-a", "send-leaf-b"]},
        }
        controller = FakeController(
            groups,
            delays={SEND_NODE: 100},
            connection_samples=[
                [{"id": "new", "download": 10, "chains": [SEND_NODE]}],
            ],
        )
        watchdog = QoEWatchdog(
            controller,
            self.state_path,
            config=QoEConfig(application_groups=(SEND_APP,)),
            wall_clock=self.wall,
            monotonic_clock=self.mono,
            sleeper=self.mono.sleep,
        )

        watchdog.run_once()
        controller.groups[SEND_APP]["now"] = SEND_SELECTOR
        result = watchdog.run_once()

        self.assertEqual([], controller.deleted)
        self.assertEqual([], result["actions"])
        self.assertEqual(0, load_state(self.state_path)["send_to_china"]["degraded_count"])

    def test_send_to_china_degraded_qoe_requires_three_runs_and_cooldown(self):
        groups = {
            SEND_APP: {"now": SEND_SELECTOR, "all": [SEND_SELECTOR]},
            SEND_NODE: {"now": "send-leaf", "all": ["send-leaf"]},
        }
        controller = FakeController(
            groups,
            delays={SEND_NODE: 2_000},
            connection_samples=low_rate_samples(SEND_NODE) * 7,
        )
        watchdog = QoEWatchdog(
            controller,
            self.state_path,
            config=QoEConfig(application_groups=(SEND_APP,)),
            wall_clock=self.wall,
            monotonic_clock=self.mono,
            sleeper=self.mono.sleep,
        )

        for _ in range(4):
            result = watchdog.run_once()
        self.assertEqual(["target"], controller.deleted)
        self.assertTrue(any("degraded QoE" in action for action in result["actions"]))

        for _ in range(3):
            watchdog.run_once()
        self.assertEqual(["target"], controller.deleted)

        self.wall.value = 1_600
        result = watchdog.run_once()
        self.assertEqual(["target", "target"], controller.deleted)
        self.assertTrue(any("degraded QoE" in action for action in result["actions"]))

    def test_send_to_china_ignores_single_small_web_request_even_with_bad_delay(self):
        groups = {
            SEND_APP: {"now": SEND_SELECTOR, "all": [SEND_SELECTOR]},
            SEND_NODE: {"now": "send-leaf", "all": ["send-leaf"]},
        }
        controller = FakeController(
            groups,
            delays={SEND_NODE: None},
            connection_samples=small_web_samples(SEND_NODE) * 3,
        )
        watchdog = QoEWatchdog(
            controller,
            self.state_path,
            config=QoEConfig(application_groups=(SEND_APP,)),
            wall_clock=self.wall,
            monotonic_clock=self.mono,
            sleeper=self.mono.sleep,
        )

        for _ in range(4):
            watchdog.run_once()

        self.assertEqual([], controller.probes)
        self.assertEqual([], controller.deleted)
        self.assertEqual(0, load_state(self.state_path)["send_to_china"]["degraded_count"])

    def test_send_to_china_sustained_throttled_flow_triggers_with_healthy_delay(self):
        groups = {
            SEND_APP: {"now": SEND_SELECTOR, "all": [SEND_SELECTOR]},
            SEND_NODE: {"now": "send-leaf", "all": ["send-leaf"]},
        }
        controller = FakeController(
            groups,
            delays={SEND_NODE: 100},
            connection_samples=throttled_flow_samples(SEND_NODE) * 3,
        )
        watchdog = QoEWatchdog(
            controller,
            self.state_path,
            config=QoEConfig(application_groups=(SEND_APP,)),
            wall_clock=self.wall,
            monotonic_clock=self.mono,
            sleeper=self.mono.sleep,
        )

        watchdog.run_once()  # Establish activation context without consuming samples.
        watchdog.run_once()
        watchdog.run_once()
        self.assertEqual([], controller.deleted)
        result = watchdog.run_once()

        self.assertEqual(["sustained"], controller.deleted)
        self.assertTrue(any("degraded QoE" in action for action in result["actions"]))

    def test_send_to_china_without_stable_samples_is_ignored(self):
        groups = {
            SEND_APP: {"now": SEND_SELECTOR, "all": [SEND_SELECTOR]},
            SEND_NODE: {"now": "send-leaf", "all": ["send-leaf"]},
        }
        unstable = [
            [
                {
                    "id": "old",
                    "download": 8 * 1024 * 1024,
                    "start": "1970-01-01T00:15:00Z",
                    "chains": [SEND_NODE],
                }
            ],
            [
                {
                    "id": "new",
                    "download": 9 * 1024 * 1024,
                    "start": "1970-01-01T00:15:00Z",
                    "chains": [SEND_NODE],
                }
            ],
        ]
        controller = FakeController(
            groups,
            delays={SEND_NODE: None},
            connection_samples=unstable,
        )
        watchdog = QoEWatchdog(
            controller,
            self.state_path,
            config=QoEConfig(application_groups=(SEND_APP,)),
            wall_clock=self.wall,
            monotonic_clock=self.mono,
            sleeper=self.mono.sleep,
        )

        watchdog.run_once()
        watchdog.run_once()

        self.assertEqual([], controller.probes)
        self.assertEqual([], controller.deleted)
        self.assertEqual(0, load_state(self.state_path)["send_to_china"]["degraded_count"])

    def test_send_to_china_ignores_historically_large_zero_progress_flow(self):
        groups = {
            SEND_APP: {"now": SEND_SELECTOR, "all": [SEND_SELECTOR]},
            SEND_NODE: {"now": "send-leaf", "all": ["send-leaf"]},
        }
        controller = FakeController(
            groups,
            delays={SEND_NODE: None},
            connection_samples=zero_progress_samples(SEND_NODE) * 3,
        )
        watchdog = QoEWatchdog(
            controller,
            self.state_path,
            config=QoEConfig(application_groups=(SEND_APP,)),
            wall_clock=self.wall,
            monotonic_clock=self.mono,
            sleeper=self.mono.sleep,
        )

        for _ in range(4):
            watchdog.run_once()
            self.assertEqual(0, load_state(self.state_path)["send_to_china"]["degraded_count"])

        self.assertEqual([], controller.probes)
        self.assertEqual([], controller.deleted)

    def test_send_to_china_healthy_or_inactive_resets_without_mutation(self):
        groups = {
            SEND_APP: {"now": SEND_SELECTOR, "all": [SEND_SELECTOR, "🎯 全球直连"]},
            SEND_NODE: {"now": "send-leaf", "all": ["send-leaf"]},
        }
        controller = FakeController(
            groups,
            delays={SEND_NODE: 100},
            connection_samples=low_rate_samples(SEND_NODE) * 3,
        )
        watchdog = QoEWatchdog(
            controller,
            self.state_path,
            config=QoEConfig(application_groups=(SEND_APP,)),
            wall_clock=self.wall,
            monotonic_clock=self.mono,
            sleeper=self.mono.sleep,
        )

        for _ in range(3):
            watchdog.run_once()
        self.assertEqual([], controller.deleted)
        self.assertEqual(0, load_state(self.state_path)["send_to_china"]["degraded_count"])

        controller.groups[SEND_APP]["now"] = "🎯 全球直连"
        watchdog.run_once()
        self.assertEqual([], controller.deleted)
        self.assertEqual([], load_state(self.state_path)["send_to_china"]["active_applications"])

    def test_incomplete_application_snapshot_makes_no_mutation_and_breaks_strikes(self):
        controller = FakeController(night_groups(), delays={SMART: None})
        watchdog = self.watchdog(controller)
        watchdog.run_once()
        watchdog.run_once()

        application_group = controller.groups.pop(APP)
        result = watchdog.run_once()
        self.assertEqual("unknown", result["mode"])
        self.assertEqual([], controller.selections)

        controller.groups[APP] = application_group
        watchdog.run_once()
        watchdog.run_once()
        self.assertEqual([], controller.selections)
        watchdog.run_once()
        self.assertEqual([(APP, AIRPORT)], controller.selections)

    def test_day_low_rate_and_bad_delay_acts_after_three_runs(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN]}}
        samples = low_rate_samples() + low_rate_samples() + low_rate_samples()
        controller = FakeController(groups, delays={FRONT: 2_000}, connection_samples=samples)
        watchdog = self.watchdog(controller)

        watchdog.run_once()
        watchdog.run_once()
        self.assertEqual([], controller.deleted)
        result = watchdog.run_once()

        self.assertEqual(["target"], controller.deleted)
        self.assertEqual("day", result["mode"])
        self.assertTrue(result["actions"])

    def test_day_low_rate_with_healthy_delay_does_not_act(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN]}}
        controller = FakeController(
            groups,
            delays={FRONT: 100},
            connection_samples=low_rate_samples() * 3,
        )
        watchdog = self.watchdog(controller)

        for _ in range(3):
            watchdog.run_once()

        self.assertEqual([], controller.deleted)
        self.assertEqual(0, load_state(self.state_path)["day"]["groups"][FRONT]["degraded_count"])

    def test_day_ignores_single_small_web_request_even_with_bad_delay(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN]}}
        controller = FakeController(
            groups,
            delays={FRONT: None},
            connection_samples=small_web_samples() * 3,
        )
        watchdog = self.watchdog(controller)

        for _ in range(3):
            watchdog.run_once()

        self.assertEqual([], controller.probes)
        self.assertEqual([], controller.deleted)
        self.assertEqual(0, load_state(self.state_path)["day"]["groups"][FRONT]["degraded_count"])

    def test_day_sustained_throttled_flow_triggers_with_healthy_delay(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN]}}
        controller = FakeController(
            groups,
            delays={FRONT: 100},
            connection_samples=throttled_flow_samples() * 3,
        )
        watchdog = self.watchdog(controller)

        watchdog.run_once()
        watchdog.run_once()
        self.assertEqual([], controller.deleted)
        result = watchdog.run_once()

        self.assertEqual(["sustained"], controller.deleted)
        self.assertTrue(result["actions"])

    def test_day_mixed_web_and_sustained_flow_only_qualifies_sustained_flow(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN]}}
        controller = FakeController(
            groups,
            delays={FRONT: 100},
            connection_samples=throttled_flow_samples(include_small_web=True) * 3,
        )
        watchdog = self.watchdog(controller)

        for _ in range(3):
            watchdog.run_once()

        self.assertEqual(["sustained"], controller.deleted)
        self.assertNotIn("small-web", controller.deleted)

    def test_day_without_stable_active_samples_does_not_degrade_or_act(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN]}}
        samples = [
            [{"id": "old", "download": 100, "chains": [FRONT]}],
            [{"id": "new", "download": 200, "chains": [FRONT]}],
        ]
        controller = FakeController(groups, delays={FRONT: 9_999}, connection_samples=samples)
        watchdog = self.watchdog(controller)

        watchdog.run_once()

        self.assertEqual([], controller.deleted)
        self.assertEqual([], controller.probes)
        self.assertEqual(0, load_state(self.state_path)["day"]["groups"][FRONT]["degraded_count"])

    def test_day_ignores_historically_large_zero_progress_flow(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN]}}
        controller = FakeController(
            groups,
            delays={FRONT: None},
            connection_samples=zero_progress_samples() * 3,
        )
        watchdog = self.watchdog(controller)

        for _ in range(3):
            watchdog.run_once()
            self.assertEqual(0, load_state(self.state_path)["day"]["groups"][FRONT]["degraded_count"])

        self.assertEqual([], controller.probes)
        self.assertEqual([], controller.deleted)

    def test_day_action_deletes_only_connections_with_matching_airport_chain(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN]}}
        samples = low_rate_samples() + low_rate_samples() + low_rate_samples()
        controller = FakeController(groups, delays={FRONT: None}, connection_samples=samples)
        watchdog = self.watchdog(controller)

        for _ in range(3):
            watchdog.run_once()

        self.assertEqual(["target"], controller.deleted)
        self.assertNotIn("other", controller.deleted)

    def test_day_degradation_is_not_consecutive_across_an_inactive_mode(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN, SMART]}}
        controller = FakeController(
            groups,
            delays={FRONT: None},
            connection_samples=low_rate_samples() * 3,
        )
        watchdog = self.watchdog(controller)

        watchdog.run_once()
        controller.groups[APP]["now"] = "🎯 全球直连"
        watchdog.run_once()
        controller.groups[APP]["now"] = CHAIN
        watchdog.run_once()
        watchdog.run_once()

        self.assertEqual([], controller.deleted)
        self.assertEqual(2, load_state(self.state_path)["day"]["groups"][FRONT]["degraded_count"])

    def test_day_action_observes_ten_minute_cooldown(self):
        groups = {APP: {"now": CHAIN, "all": [CHAIN]}}
        controller = FakeController(
            groups,
            delays={FRONT: None},
            connection_samples=low_rate_samples() * 7,
        )
        watchdog = self.watchdog(controller)

        for _ in range(3):
            watchdog.run_once()
        self.assertEqual(["target"], controller.deleted)

        for _ in range(3):
            watchdog.run_once()
        self.assertEqual(["target"], controller.deleted)

        self.wall.value = 1_600
        watchdog.run_once()
        self.assertEqual(["target", "target"], controller.deleted)

    def test_probe_url_timeout_and_threshold_are_configurable(self):
        with mock.patch.dict(
            os.environ,
            {
                "QOE_PROBE_URL": "https://probe.example/generate_204",
                "QOE_PROBE_TIMEOUT_MS": "7000",
                "QOE_HIGH_DELAY_MS": "1200",
                "QOE_ACTIVE_FLOW_MIN_AGE_SECONDS": "12.5",
                "QOE_ACTIVE_FLOW_MIN_BYTES": "6291456",
                "QOE_LOW_RATE_DIRECT_TRIGGER_BPS": "262144",
            },
        ):
            config = QoEConfig.from_env((APP,))

        self.assertEqual("https://probe.example/generate_204", config.probe_url)
        self.assertEqual(7_000, config.probe_timeout_ms)
        self.assertEqual(1_200, config.high_delay_ms)
        self.assertEqual(12.5, config.active_flow_min_age_seconds)
        self.assertEqual(6 * 1024 * 1024, config.active_flow_min_bytes)
        self.assertEqual(256 * 1024, config.low_rate_direct_trigger_bps)


class AtomicStateTests(unittest.TestCase):
    def test_atomic_write_preserves_old_file_if_replace_fails(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "qoe_watchdog.json"
            old_state = {"old": True}
            path.write_text(json.dumps(old_state), encoding="utf-8")

            with mock.patch("qoe_watchdog.os.replace", side_effect=OSError("replace failed")):
                with self.assertRaises(OSError):
                    atomic_write_json(path, {"new": True})

            self.assertEqual(old_state, json.loads(path.read_text(encoding="utf-8")))
            leftovers = [item for item in os.listdir(temp_dir) if item != path.name]
            self.assertEqual([], leftovers)


if __name__ == "__main__":
    unittest.main()
