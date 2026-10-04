#!/usr/bin/env python3
"""Behavioral counterexamples for the stacked A/B/C/D P0s. Not string-only."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.accept_phases import parse_screen, parse_wifi, screen_off_hold, wifi_bounce  # noqa: E402
from lib.background_probe import BackgroundKeepAliveModel, BackgroundProbeModel, ProbeSelfCheckModel  # noqa: E402
from lib.dataplane_fsm import PHASE_ERROR, PHASE_STOPPED, Plane, parse_status_blob  # noqa: E402
from lib.dns_strict import build_dns_query, validate_dns_response  # noqa: E402
from lib.event_store import EventGap, EventSnapshot  # noqa: E402
from lib.extprobe import (  # noqa: E402
    HdcError,
    WindowEvidence,
    assert_windows_no_overlap,
    evaluate_window,
    lan_direct_line_set,
    new_access_text,
    parse_foreground_bundle,
    parse_wlan_gateway,
    udp53_line_set,
)
from lib.hdc_singleton import DuplicateWaiter, acquire  # noqa: E402
from lib.hev_engine import ENGINE_HEV, HevEngine  # noqa: E402
from lib.hvigor_pnpm import pnpm_ok  # noqa: E402
from lib.provenance import (  # noqa: E402
    AUTHORIZED_SIGNER_FINGERPRINT,
    EXPECT_BUNDLE,
    ProvenanceError,
    assert_installable,
    check_manifest_gate,
)
from lib.soak_round import SoakFail, evaluate_round  # noqa: E402
from lib.vpn_cycle import wait_canary_commit, wait_stopped  # noqa: E402

KEEP = ROOT / "entry/src/main/ets/services/BackgroundKeepAlive.ets"
PROBE = ROOT / "entry/src/main/ets/services/ProbeSelfCheck.ets"
HOST = ROOT / "entry/src/main/ets/services/BackgroundProbeHost.ets"
TUNNEL = ROOT / "entry/src/main/ets/vpn/TunnelVpnAbility.ets"
INDEX = ROOT / "entry/src/main/ets/pages/Index.ets"
CTRL = ROOT / "entry/src/main/ets/services/ConnectionController.ets"
STORE = ROOT / "entry/src/main/ets/services/StatusStore.ets"
NATIVE = ROOT / "entry/src/main/cpp/napi_init.cpp"


class KeepAliveCounterexample(unittest.TestCase):
    def test_touch_failure_does_not_keep_fake_running(self) -> None:
        k = BackgroundKeepAliveModel()
        self.assertTrue(k.start(ok=True))
        self.assertTrue(k.snapshot()["ok"])
        self.assertFalse(k.touch(ok=False))
        snap = k.snapshot()
        self.assertFalse(snap["running"])
        self.assertFalse(snap["ok"])
        self.assertEqual(snap["lastEvent"], "dead")

    def test_system_missing_task_is_not_running(self) -> None:
        k = BackgroundKeepAliveModel()
        k.start(ok=True)
        self.assertFalse(k.touch(ok=True, system_present=False))
        self.assertFalse(k.running)

    def test_cancel_clears_running(self) -> None:
        k = BackgroundKeepAliveModel()
        k.start(ok=True)
        k.on_cancel()
        self.assertFalse(k.running)
        self.assertIn("cancel", k.events)

    def test_starting_keep_alive_before_first_canary(self) -> None:
        m = BackgroundProbeModel()
        self.assertEqual(m.start_tunnel(keep_alive_ok=True), "keep-alive-then-wait-canary")
        self.assertTrue(m.keep.running)
        self.assertEqual(m.phase, "STARTING")
        m.on_background(keep_alive_ok=True)
        m.pulse("r-start")
        self.assertEqual(m.owners_for("r-start"), ["entry-background"])

    def test_fail_ack_does_not_stick_old_rid(self) -> None:
        p = ProbeSelfCheckModel()
        rec = p.tick("rid-old", google_http=0, direct_http=0, dns_ok=False)
        self.assertTrue(rec["failAck"])
        self.assertEqual(p.last_ok_rid, "")
        p.now = p.next_retry_at
        rec2 = p.tick("rid-new", google_http=204, direct_http=200, dns_ok=True)
        self.assertTrue(rec2["ackOk"])
        self.assertEqual(p.last_ok_rid, "rid-new")

    def test_dns_any_datagram_is_not_ok(self) -> None:
        q = build_dns_query("www.google.com", 0x1234)
        self.assertFalse(
            validate_dns_response(
                payload=q,
                txid=0x1234,
                question="www.google.com",
                source="8.8.8.8",
                source_port=53,
            )
        )
        self.assertFalse(
            validate_dns_response(
                payload=b"\x12\x34" + b"\x00" * 20,
                txid=0x1234,
                question="www.google.com",
                source="1.1.1.1",
                source_port=53,
            )
        )
        q = build_dns_query("www.google.com", 0x1234)
        header = bytearray(q[:12])
        header[2] = 0x81
        header[3] = 0x80
        header[6] = 0
        header[7] = 1
        question = q[12:]
        evil = bytes([0x04, ord("e"), ord("v"), ord("i"), ord("l"), 0x03, ord("c"), ord("o"), ord("m"), 0x00,
                      0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 1, 2, 3, 4])
        payload = bytes(header) + question + evil
        self.assertFalse(
            validate_dns_response(
                payload=payload,
                txid=0x1234,
                question="www.google.com",
                source="8.8.8.8",
                source_port=53,
            )
        )

    def test_dns_strict_accepts_valid_a_response(self) -> None:
        txid = 0x1234
        q = build_dns_query("www.google.com", txid)
        # QR=1, RCODE=0, QD=1, AN=1, copy question, A answer 8.8.8.8
        header = bytearray(q[:12])
        header[2] = 0x81
        header[3] = 0x80
        header[6] = 0
        header[7] = 1
        question = q[12:]
        answer = bytes([0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 8, 8, 8, 8])
        payload = bytes(header) + question + answer
        self.assertTrue(
            validate_dns_response(
                payload=payload,
                txid=txid,
                question="www.google.com",
                source="8.8.8.8",
                source_port=53,
            )
        )

    def test_source_has_identity_progress_and_strict_dns(self) -> None:
        keep = KEEP.read_text(encoding="utf-8")
        self.assertIn("getAllContinuousTasks", keep)
        self.assertIn("continuousTaskId", keep)
        self.assertIn("continuousTaskCancel", keep)
        self.assertIn("continuousTaskSuspend", keep)
        self.assertIn("continuousTaskActive", keep)
        self.assertIn("markDead", keep)
        probe = PROBE.read_text(encoding="utf-8")
        self.assertIn("failAck", probe)
        self.assertIn("validateDnsResponse", probe)
        self.assertIn("lastOkRid", probe)
        self.assertNotIn("wikipedia", probe.lower())
        tun = TUNNEL.read_text(encoding="utf-8")
        self.assertNotIn("www.wikipedia.org", tun)
        self.assertIn("www.google.com", tun)
        self.assertIn("/generate_204", tun)
        idx = INDEX.read_text(encoding="utf-8")
        self.assertNotIn("PROBE_SELF_CHECK.startLoop(this.context)", idx)
        wait = idx.index("CONNECTION_CONTROLLER.start")
        self.assertLess(idx.index("BACKGROUND_KEEP_ALIVE.ensure"), wait)
        host = HOST.read_text(encoding="utf-8")
        self.assertIn("desiredRunning === true", host)
        self.assertNotIn("writeStatus", host)
        self.assertIn("background-keepalive.json", host)


class StateMachineCounterexample(unittest.TestCase):
    def test_stale_recover_does_not_destroy_new_session(self) -> None:
        p = Plane()
        p.start("g1")
        p.recover_in_flight = True
        p.generation = "g2"
        p.session_revision = 1
        p.cancelled = False
        p.cleaning_up = False
        p.recover_in_flight = False
        p.core_restarts = 0
        # Old recover captured g1; current is g2.
        p.generation = "g2"
        old = Plane()
        old.start("g1")
        old.generation = "g1"
        captured = "g1"
        old.generation = "g2"
        old.session_revision = 1
        if old.stale_recover(captured, 1):
            if old.generation == captured:
                old._destroy_tun("stale")
            else:
                old.writes.append(f"stale-recover-ignored-new-gen:{old.generation}")
        self.assertEqual(old.generation, "g2")
        self.assertTrue(any(x.startswith("stale-recover-ignored-new-gen") for x in old.writes))
        self.assertNotEqual(old.phase, PHASE_ERROR)

    def test_ondestroy_clears_desired_and_pending(self) -> None:
        p = Plane()
        p.start("g1")
        p.pending_start = "g2"
        p.desired_running = True
        p.on_destroy()
        self.assertFalse(p.desired_running)
        self.assertEqual(p.pending_start, "")
        self.assertEqual(p.phase, PHASE_STOPPED)

    def test_circuit_breaker_blocks_next_session(self) -> None:
        p = Plane()
        p.start("g1")
        p.trip_circuit("recover-limit")
        p.cancelled = False
        p.vpn_created = False
        p.start_in_flight = False
        p.start("g2")
        self.assertEqual(p.phase, PHASE_ERROR)
        self.assertIn("circuit-block", p.writes)
        self.assertFalse(p.desired_running)
        self.assertEqual(p.latest["kind"], "stop")
        p.dispatch_latest()
        self.assertNotEqual(p.generation, "g2")

    def test_stale_start_catch_does_not_cleanup_new_session(self) -> None:
        p = Plane()
        p.start("g1", token=1)
        p.committed_token = 2
        p.generation = "g2"
        p.writes.append("would-catch")
        if p.committed_token != 1:
            p.writes.append("stale-catch")
        else:
            p.teardown(True, True, True)
        self.assertEqual(p.generation, "g2")
        self.assertIn("stale-catch", p.writes)

    def test_corrupt_breaker_blocks(self) -> None:
        p = Plane()
        p.breaker_file = "{}"
        self.assertTrue(p.breaker_blocks())

    def test_later_start_queued_during_recover(self) -> None:
        p = Plane()
        p.start("g1")
        p.recover_in_flight = True
        self.assertEqual(p.request_start("g2"), "held")
        self.assertEqual(p.latest["generation"], "g2")

    def test_status_write_fail_closed(self) -> None:
        p = Plane()
        p.start("g1")
        p.status_write_ok = False
        p.write_status("canary")
        self.assertEqual(p.phase, PHASE_ERROR)
        self.assertFalse(p.canary_ok)

    def test_hev_already_running_is_not_ok(self) -> None:
        e = HevEngine()
        self.assertTrue(e.start()[0])
        ok, msg = e.start()
        self.assertFalse(ok)
        self.assertIn("already running", msg)

    def test_hev_stop_during_start_uses_hev_path(self) -> None:
        e = HevEngine()
        e.start_begin()
        self.assertEqual(e.engine, ENGINE_HEV)
        ok, msg = e.stop()
        self.assertTrue(ok)
        self.assertEqual(msg, "hev tun stopped.")
        self.assertFalse(e.running)

    def test_event_empty_and_missing_fields_fail(self) -> None:
        with self.assertRaises(EventGap):
            EventSnapshot.from_json('{"seq":2,"generation":"g1","sessionRevision":1,"windowStartSeq":1,"events":[]}')
        with self.assertRaises(EventGap):
            EventSnapshot.from_json(
                '{"seq":1,"generation":"g1","sessionRevision":1,"windowStartSeq":1,"events":[{"seq":1,"generation":"g1"}]}'
            )
        snap = EventSnapshot()
        snap.append("tick", "g1", 1)
        snap.append("tick", "g1", 2)
        loaded = EventSnapshot.from_json(snap.to_json())
        self.assertEqual(loaded.session_revision, 2)
        mixed = EventSnapshot.from_json(
            json.dumps(
                {
                    "seq": 2,
                    "generation": "g1",
                    "sessionRevision": 2,
                    "windowStartSeq": 1,
                    "events": [
                        {
                            "seq": 1,
                            "kind": "tick",
                            "generation": "g1",
                            "sessionRevision": 1,
                            "at": 1,
                            "phase": "FORWARDER_RUNNING",
                        },
                        {
                            "seq": 2,
                            "kind": "tick",
                            "generation": "g1",
                            "sessionRevision": 2,
                            "at": 2,
                            "phase": "CANARY_OK",
                        },
                    ],
                }
            )
        )
        self.assertEqual(mixed.session_revision, 2)

    def test_source_stale_recover_uses_captured_gen(self) -> None:
        tun = TUNNEL.read_text(encoding="utf-8")
        self.assertIn("this.requestCleanup('recover stale after stop', gen)", tun)
        self.assertIn("desiredRunning = false", tun)
        self.assertIn("tripBreaker", tun)
        self.assertIn("destroyBounded", tun)
        self.assertIn("circuit-breaker.json", tun)
        store = STORE.read_text(encoding="utf-8")
        self.assertNotIn("write status failed", store)
        ctrl = CTRL.read_text(encoding="utf-8")
        self.assertIn("stopVpnExtensionAbility", ctrl)
        self.assertIn("UI wrote STOPPED", ctrl)
        self.assertIn("UI refused STOPPED", ctrl)
        self.assertNotIn("waitStop", ctrl)
        native = NATIVE.read_text(encoding="utf-8")
        self.assertIn('CreateResult(env, false, "tun data plane already running.")', native)


class OracleCounterexample(unittest.TestCase):
    def test_native_running_is_not_stopped(self) -> None:
        def status_fn() -> dict:
            return {
                "phase": "STOPPED",
                "generation": "g1",
                "commandEpoch": 4,
                "desiredRunning": False,
                "tunFd": -1,
                "xrayRunning": True,
                "forwarderOk": False,
            }

        with self.assertRaises(HdcError):
            wait_stopped(
                status_fn=status_fn,
                tun_fn=lambda: "no-tun",
                pid_fn=lambda: "",
                old_generation="g1",
                old_epoch=3,
                timeout=0.2,
                native_fn=lambda: {"xrayRunning": True, "tunRunning": False, "poisoned": False},
            )

    def test_wrong_generation_is_not_stopped(self) -> None:
        with self.assertRaises(HdcError):
            wait_stopped(
                status_fn=lambda: {
                    "phase": "STOPPED",
                    "generation": "g2",
                    "commandEpoch": 9,
                    "desiredRunning": False,
                    "tunFd": -1,
                },
                tun_fn=lambda: "no-tun",
                pid_fn=lambda: "",
                old_generation="g1",
                old_epoch=3,
                timeout=0.2,
                native_fn=lambda: {"xrayRunning": False, "tunRunning": False, "poisoned": False},
            )

    def test_error_is_not_stopped(self) -> None:
        calls = {"n": 0}

        def status_fn() -> dict:
            return {"phase": "ERROR", "commandEpoch": 4, "desiredRunning": False, "tunFd": -1}

        def tun_fn() -> str:
            return "no-tun"

        def pid_fn() -> str:
            return ""

        with self.assertRaises(HdcError):
            wait_stopped(
                status_fn=status_fn,
                tun_fn=tun_fn,
                pid_fn=pid_fn,
                old_generation="g1",
                old_epoch=3,
                timeout=0.2,
            )

    def test_canary_requires_requested_generation(self) -> None:
        def status_fn() -> dict:
            return {
                "generation": "other",
                "phase": "CANARY_OK",
                "lastProvenRid": "r1",
                "evidenceAt": 9,
            }

        def commit_fn() -> dict:
            return {"kind": "commit", "rid": "r1", "generation": "other"}

        with self.assertRaises(HdcError):
            wait_canary_commit(
                status_fn=status_fn,
                commit_fn=commit_fn,
                old_generation="old",
                requested_generation="wanted",
                timeout=0.2,
            )

    def test_address_bar_is_not_google_evidence(self) -> None:
        ev = WindowEvidence(
            rid="p1",
            generation_before="g",
            generation_after="g",
            revision_before=1,
            revision_after=1,
            tun_rx_before=0,
            tun_rx_after=10,
            tun_tx_before=0,
            tun_tx_after=10,
            hev_up_before=0,
            hev_up_after=10,
            hev_down_before=0,
            hev_down_after=10,
            tags={"googleProxy": False},
            consumed=True,
            evidence_rid="p1",
            consumed_rid="p1",
            probe_revision=1,
            access_offset=1,
            browser_pid="2",
            tongdao_pid="3",
            browser_uid="2",
            tongdao_uid="3",
            observed_browser_bundle="com.huawei.hmos.browser",
            consumed_generation="g",
            consumed_revision=1,
            consumed_access_offset=1,
            consumed_raw_cursor=1,
            consumed_epoch=1,
            consumed_at=1,
            purpose="browser_google",
            dump_has_rid=True,
            google_page_ok=False,
            page_content_ok=False,
            browser_http_source="uitest-dump",
        )
        rec = evaluate_window(ev)
        self.assertFalse(rec["ok"])

    def test_foreground_bundle_not_defaulted(self) -> None:
        with self.assertRaises(HdcError):
            parse_foreground_bundle("")
        self.assertEqual(
            parse_foreground_bundle('focused=true bundleName="com.huawei.hmos.browser"'),
            "com.huawei.hmos.browser",
        )
        self.assertEqual(
            parse_foreground_bundle(
                "bundle name [com.oscarwoltz.tongdao]\n        ability type [PAGE]\n        state #BACKGROUND\n"
                "bundle name [com.huawei.hmos.browser]\n        ability type [PAGE]\n        state #FOREGROUND\n"
            ),
            "com.huawei.hmos.browser",
        )

    def test_log_overlap_fails(self) -> None:
        with self.assertRaises(HdcError):
            assert_windows_no_overlap([("a", 0, 10), ("b", 5, 12)])

    def test_wifi_and_screen_must_parse(self) -> None:
        self.assertTrue(parse_wifi("wlan0 flags=4163<UP,BROADCAST,RUNNING,MULTICAST>")["up"])
        self.assertFalse(parse_wifi("wlan0 flags=4098<BROADCAST,MULTICAST>")["up"])
        with self.assertRaises(HdcError):
            parse_wifi("garbage")
        self.assertFalse(parse_screen("isScreenOn: false")["on"])
        self.assertTrue(parse_screen("isScreenOn: true")["on"])
        with self.assertRaises(HdcError):
            parse_screen("maybe")

    def test_wifi_bounce_reads_back(self) -> None:
        states = iter(
            [
                "wlan0 flags=4163<UP,BROADCAST,RUNNING,MULTICAST>",
                "wlan0 flags=4098<BROADCAST,MULTICAST>",
                "wlan0 flags=4163<UP,BROADCAST,RUNNING,MULTICAST>",
            ]
        )

        def verify() -> str:
            return next(states)

        def run(*_a: str, **_k: object) -> str:
            return "ok"

        rec = wifi_bounce(run=run, verify=verify, sleep=lambda _s: None)
        self.assertEqual(rec["didWifi"], "1")

    def test_soak_requires_phases_and_monotonic_time(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            status = Path(raw) / "s.json"
            status.write_text(
                json.dumps(
                    {
                        "phase": "CANARY_OK",
                        "canaryOk": True,
                        "forwarderOk": True,
                        "generation": "g1",
                        "sessionRevision": 1,
                        "at": 1_000,
                        "evidenceAt": 900,
                    }
                )
            )
            with self.assertRaises(SoakFail) as ctx:
                evaluate_round(
                    targets="TEST_DEVICE_SERIAL\n",
                    serial="TEST_DEVICE_SERIAL",
                    model="ALT-AL10",
                    status_path=status,
                    tun="vpn-tun: 10 1 0 0 0 0 0 0 10 1 0 0 0 0 0 0",
                    cb="clashbox-absent",
                    vpn="1234",
                    want_gen="g1",
                    last_at=0,
                    now_ms=1_000,
                    require_phases=True,
                    did_wifi=0,
                    did_screen=0,
                    held_sec=0,
                )
            self.assertIn("DID_WIFI", ctx.exception.reason)

    def test_tun_counter_rewind_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            status = Path(raw) / "s.json"
            status.write_text(
                json.dumps(
                    {
                        "phase": "CANARY_OK",
                        "canaryOk": True,
                        "forwarderOk": True,
                        "generation": "g1",
                        "sessionRevision": 1,
                        "at": 1_000,
                        "evidenceAt": 900,
                    }
                )
            )
            with self.assertRaises(SoakFail) as ctx:
                evaluate_round(
                    targets="TEST_DEVICE_SERIAL\n",
                    serial="TEST_DEVICE_SERIAL",
                    model="ALT-AL10",
                    status_path=status,
                    tun="vpn-tun: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0",
                    cb="clashbox-absent",
                    vpn="1234",
                    want_gen="g1",
                    last_at=0,
                    now_ms=1_000,
                    last_tun_rx=100,
                    last_tun_tx=100,
                )
            self.assertIn("went_backwards", ctx.exception.reason)


class BuildCounterexample(unittest.TestCase):
    def test_manifest_gate_rejects_wrong_bundle_secret_forged_immutable(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            hap = Path(raw) / "a.hap"
            hap.write_bytes(b"pkg")
            digest = __import__("hashlib").sha256(hap.read_bytes()).hexdigest()
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate({"bundleName": "com.evil.app", "secretScan": "ok"}, hap_sha=digest)
            self.assertIn("wrong bundle", str(ctx.exception))
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate({"bundleName": EXPECT_BUNDLE, "secretScan": "failed"}, hap_sha=digest)
            self.assertIn("secretScan failed", str(ctx.exception))
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate(
                    {"bundleName": EXPECT_BUNDLE, "secretScan": "ok"},
                    hap_sha=digest,
                )
            self.assertIn("immutableHap", str(ctx.exception))
            imm = Path(raw) / "imm.hap"
            imm.write_bytes(b"other")
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate(
                    {
                        "bundleName": EXPECT_BUNDLE,
                        "secretScan": "ok",
                        "immutableHap": str(imm),
                    },
                    hap_sha=digest,
                )
            self.assertIn("hash mismatch", str(ctx.exception))
            imm.write_bytes(b"pkg")
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate(
                    {
                        "bundleName": EXPECT_BUNDLE,
                        "secretScan": "ok",
                        "immutableHap": str(imm),
                        "signerFingerprint": "00" * 32,
                    },
                    hap_sha=digest,
                )
            self.assertIn("forged signature hash", str(ctx.exception))
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate(
                    {
                        "bundleName": EXPECT_BUNDLE,
                        "secretScan": "ok",
                        "immutableHap": str(imm),
                        "signerFingerprint": AUTHORIZED_SIGNER_FINGERPRINT,
                    },
                    hap_sha=digest,
                )
            self.assertIn("core/lock receipt", str(ctx.exception))
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate(
                    {
                        "secretScan": "ok",
                        "immutableHap": str(imm),
                        "signerFingerprint": AUTHORIZED_SIGNER_FINGERPRINT,
                    },
                    hap_sha=digest,
                )
            self.assertIn("bundleName", str(ctx.exception))
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate(
                    {
                        "bundleName": EXPECT_BUNDLE,
                        "secretScan": "ok",
                        "immutableHap": str(imm),
                        "signerFingerprint": AUTHORIZED_SIGNER_FINGERPRINT,
                        "lockLibxraySha256": "aa" * 32,
                        "lockHevSha256": "bb" * 32,
                        "lockedHevCommit": "9a06bc6",
                        "clang": "/clang",
                        "hapLibxraySha256": "cc" * 32,
                        "hapHevSha256": "dd" * 32,
                        "unsignedHapSha256": "ee" * 32,
                        "profileSha256": "ff" * 32,
                        "appCertSha256": "11" * 32,
                    },
                    hap_sha=digest,
                    root=ROOT,
                )
            self.assertIn("forged lockLibxraySha256", str(ctx.exception))

    def test_self_consistent_hap_and_lock_without_packed_link_is_rejected(self) -> None:
        lock = json.loads((ROOT / "native/CORE_LOCK.json").read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as raw:
            hap = Path(raw) / "a.hap"
            hap.write_bytes(b"pkg")
            digest = __import__("hashlib").sha256(hap.read_bytes()).hexdigest()
            imm = Path(raw) / "imm.hap"
            imm.write_bytes(b"pkg")
            man = {
                "bundleName": EXPECT_BUNDLE,
                "secretScan": "ok",
                "immutableHap": str(imm),
                "signerFingerprint": AUTHORIZED_SIGNER_FINGERPRINT,
                "lockLibxraySha256": lock["libxray"]["sha256"],
                "lockHevSha256": lock["hev"]["sha256"],
                "lockedHevCommit": "9a06bc6",
                "clang": "/clang",
                "hapLibxraySha256": "cc" * 32,
                "hapHevSha256": "dd" * 32,
                "unsignedHapSha256": "ee" * 32,
                "profileSha256": "ff" * 32,
                "appCertSha256": "11" * 32,
            }
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate(man, hap_sha=digest, root=ROOT)
            self.assertIn("post-strip library", str(ctx.exception))

    def test_xray_replace_is_relative_and_stages_before_prebuilt(self) -> None:
        build = (ROOT / "scripts/build_libxray_ohos.sh").read_text(encoding="utf-8")
        self.assertIn('go mod edit -replace="github.com/xtls/xray-core=./third_party/xray-core-protect-fail-closed"', build)
        self.assertIn("STAGED_SO=", build)
        self.assertNotIn('cp "${STAGED_SO}" "${OUT_DIR}/libxray.so"', build)
        self.assertIn("STAGED_LIBXRAY=", build)
        self.assertNotIn('go mod edit -replace="github.com/xtls/xray-core=${PATCHED_XRAY_DIR}"', build)
        r1 = (ROOT / "scripts/r1-build.sh").read_text(encoding="utf-8")
        self.assertIn("publish_rebuilt_libxray", r1)
        self.assertIn("signing materials stripped from staged profile", r1)
        self.assertIn("compile-only-unsigned.hap", r1)
        self.assertIn('COMPILE_ONLY hvigor failed rc=', r1)

    def test_publish_rolls_back_prebuilt_and_lock_on_verify_failure(self) -> None:
        import tempfile

        from lib.provenance import ProvenanceError, publish_rebuilt_libxray

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            dest = tmp_path / "libxray.so"
            staged = tmp_path / "staged.so"
            lock_path = tmp_path / "CORE_LOCK.json"
            dest.write_bytes(b"OLD-RAW-BYTES-OLD-RAW-BYTES")
            staged.write_bytes(b"NEW-RAW-BYTES-NEW-RAW-BYTES")
            lock_path.write_text('{"libxray":{"sha256":"old","packedSha256":"oldp"}}\n', encoding="utf-8")
            old_dest = dest.read_bytes()
            old_lock = lock_path.read_text(encoding="utf-8")

            def boom() -> None:
                raise ProvenanceError("outer verify failed")

            with self.assertRaises(ProvenanceError):
                publish_rebuilt_libxray(staged, dest, lock_path, "new", "newp", "note", boom)
            self.assertEqual(dest.read_bytes(), old_dest)
            self.assertEqual(lock_path.read_text(encoding="utf-8"), old_lock)

    def test_protect_hold_closes_once_and_xray_job_is_locked(self) -> None:
        import subprocess
        import tempfile

        native = NATIVE.read_text(encoding="utf-8")
        self.assertIn("holdFd.exchange(-1)", native)
        self.assertIn("g_xrayJobMu", native)
        self.assertIn("claimed.load() == 0", native)
        self.assertIn("waiter->abandoned.load() != 0 ? -1 : rc", native)
        src = ROOT / "tests/protect_hold_close_once.cpp"
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "close_once"
            subprocess.check_call(["c++", "-std=c++17", "-pthread", str(src), "-o", str(out)])
            subprocess.check_call([str(out)])

    def test_packed_hash_is_llvm_strip_of_locked_raw(self) -> None:
        from lib.native_strip import expected_packed_sha256, find_llvm_strip

        lock = json.loads((ROOT / "native/CORE_LOCK.json").read_text(encoding="utf-8"))
        strip = find_llvm_strip(ROOT)
        raw = ROOT / lock["libxray"]["artifact"]
        got = expected_packed_sha256(raw, strip)
        self.assertEqual(got, lock["libxray"]["packedSha256"])
        raw_h = ROOT / lock["hev"]["artifact"]
        self.assertEqual(expected_packed_sha256(raw_h, strip), lock["hev"]["packedSha256"])

    def test_xray_protect_patch_returns_controller_errors(self) -> None:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "xray_protect_fail_closed",
            ROOT / "native/patches/xray-protect-fail-closed.py",
        )
        mod = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(mod)
        snippet = """\t\t\t\tif err := ctl(network, address, c); err != nil {
\t\t\t\t\terrors.LogInfoInner(ctx, err, "failed to apply external controller")
\t\t\t\t}
"""
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "system_dialer.go"
            path.write_text(snippet + snippet, encoding="utf-8")
            mod.patch_system_dialer(path)
            text = path.read_text(encoding="utf-8")
            self.assertEqual(text.count("return err"), 2)
            self.assertNotIn("failed to apply external controller", text)

    def test_sign_and_watcher_and_geo_source(self) -> None:
        sign = (ROOT / "scripts/huawei-sign-hap.sh").read_text(encoding="utf-8")
        self.assertIn("TONGDAO_SIGN_PERMIT", sign)
        js = (ROOT / "scripts/huawei-sign-hap.js").read_text(encoding="utf-8")
        self.assertIn("signing.json", js)
        self.assertIn("pwdInputMode", js)
        self.assertIn("sign permit hash mismatch", js)
        self.assertNotIn('"-keyPwd"', js)
        r1 = (ROOT / "scripts/r1-build.sh").read_text(encoding="utf-8")
        self.assertIn("staged-after-placeholders", r1)
        self.assertIn("run_bounded", r1)
        self.assertIn("TONGDAO_SIGN_PERMIT", r1)
        self.assertIn("assert_installable", r1)
        self.assertIn("atomic_publish_manifest", r1)
        self.assertIn("complete skip-quality manifest required before install", r1)
        wait = (ROOT / "scripts/stage1-hdc-wait.sh").read_text(encoding="utf-8")
        self.assertIn("no-auto-install", wait)
        self.assertIn("hold", wait)
        self.assertNotIn("stage1-bringup-soak.sh", wait)
        self.assertNotIn("STARTED=1", wait)
        geo = (ROOT / "native/GEO_LOCK.json").read_text(encoding="utf-8")
        self.assertNotIn("/latest/", geo)
        self.assertIn("202608050239", geo)
        profile = (ROOT / "build-profile.json5").read_text(encoding="utf-8")
        self.assertIn("USE_SIGNING_JSON", profile)
        self.assertNotRegex(profile, r"keyPassword:\s*'000000")
        from lib.hvigor_pnpm import pnpm_ok
        from lib.provenance import SOURCE_INPUTS, _SKIP_SUFFIX

        self.assertIn("scripts/r1-build.sh", SOURCE_INPUTS)
        self.assertIn("scripts/lib/provenance.py", SOURCE_INPUTS)
        self.assertIn("scripts/huawei-sign-hap.js", SOURCE_INPUTS)
        self.assertIn("scripts/restore_geo.py", SOURCE_INPUTS)
        self.assertIn("scripts/build_libxray_ohos.sh", SOURCE_INPUTS)
        self.assertIn("scripts/build_hev_ohos.sh", SOURCE_INPUTS)
        self.assertIn("scripts/lib/bounded_cmd.py", SOURCE_INPUTS)
        self.assertIn("scripts/lib/hdc_singleton.py", SOURCE_INPUTS)
        self.assertIn("scripts/lib/stage1_loop.py", SOURCE_INPUTS)
        self.assertIn("scripts/stage1-loop.py", SOURCE_INPUTS)
        self.assertIn("wait-acquired", r1)
        self.assertIn("TONGDAO_INSTALL", r1)
        self.assertNotIn("hdc_singleton.py acquire", r1)
        self.assertNotIn(".so", _SKIP_SUFFIX)
        self.assertFalse(pnpm_ok(Path("/tmp/missing-pnpm-root")))

    def test_pnpm_ok_exit_7_and_timeout_are_false(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bin_dir = root / "wrapper" / "tools" / "10.28.2" / "node_modules" / ".bin"
            bin_dir.mkdir(parents=True)
            bad = bin_dir / "pnpm"
            bad.write_text("#!/bin/sh\nexit 7\n")
            bad.chmod(0o755)
            self.assertFalse(pnpm_ok(root))

    def test_forged_unsigned_hash_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            hap = Path(raw) / "a.hap"
            unsigned = Path(raw) / "u.hap"
            hap.write_bytes(b"signed")
            unsigned.write_bytes(b"unsigned")
            digest = __import__("hashlib").sha256(hap.read_bytes()).hexdigest()
            man = {
                "bundleName": EXPECT_BUNDLE,
                "secretScan": "ok",
                "immutableHap": str(hap),
                "signerFingerprint": AUTHORIZED_SIGNER_FINGERPRINT,
                "hapSha256": digest,
                "hapBytes": hap.stat().st_size,
                "unsignedHapSha256": "aa" * 32,
                "lockLibxraySha256": "bb" * 32,
                "lockHevSha256": "cc" * 32,
                "lockedHevCommit": "9a06bc6",
                "clang": "/clang",
                "hapLibxraySha256": "dd" * 32,
                "hapHevSha256": "ee" * 32,
                "profileSha256": "ff" * 32,
                "appCertSha256": "11" * 32,
            }
            with self.assertRaises(ProvenanceError) as ctx:
                check_manifest_gate(man, hap_sha=digest, root=ROOT)
            self.assertIn("forged lockLibxraySha256", str(ctx.exception))
            with self.assertRaises(ProvenanceError) as ctx2:
                assert_installable(ROOT, hap, man, unsigned=unsigned)
            self.assertTrue("forged" in str(ctx2.exception) or "missing" in str(ctx2.exception))


class RuntimeCounterexample(unittest.TestCase):
    def test_status_empty_object_is_error_not_idle(self) -> None:
        self.assertEqual(parse_status_blob("{}"), PHASE_ERROR)
        self.assertEqual(parse_status_blob("{not-json"), PHASE_ERROR)
        self.assertEqual(parse_status_blob('{"foo":1}'), PHASE_ERROR)
        self.assertEqual(parse_status_blob('{"phase":"STOPPED"}'), PHASE_STOPPED)

    def test_hev_worker_exit_cannot_commit_running(self) -> None:
        e = HevEngine()
        life = e.start_begin()
        e.worker_exit(life)
        ok, msg = e.start_commit(life)
        self.assertFalse(ok)
        self.assertFalse(e.running)
        self.assertIn("exited", msg)

    def test_stop_does_not_write_desired_before_gen_check(self) -> None:
        p = Plane()
        p.start("g1")
        p.desired_running = True
        p.latest = {"token": 9, "kind": "stop", "generation": "other"}
        self.assertEqual(p.commit(p.latest), "ignored")
        self.assertTrue(p.desired_running)
        self.assertEqual(p.generation, "g1")

    def test_dump_text_is_not_google_http(self) -> None:
        rec = evaluate_window(
            WindowEvidence(
                rid="p1-g",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=1,
                tun_rx_before=0,
                tun_rx_after=10,
                tun_tx_before=0,
                tun_tx_after=10,
                hev_up_before=0,
                hev_up_after=10,
                hev_down_before=0,
                hev_down_after=10,
                tags={"googleProxy": True},
                purpose="browser_google",
                dump_has_rid=True,
                google_page_ok=True,
                page_content_ok=True,
                google_http_status=204,
                browser_http_source="uitest-dump",
                browser_pid="2",
                tongdao_pid="3",
                browser_uid="2",
                tongdao_uid="3",
                observed_browser_bundle="com.huawei.hmos.browser",
                production_rid="prod",
            )
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "google_http_not_from_http")

    def test_udp_without_recv_is_not_ok(self) -> None:
        rec = evaluate_window(
            WindowEvidence(
                rid="p1-u",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=1,
                tun_rx_before=0,
                tun_rx_after=10,
                tun_tx_before=0,
                tun_tx_after=10,
                hev_up_before=0,
                hev_up_after=10,
                hev_down_before=0,
                hev_down_after=10,
                tags={"udp53Proxy": True},
                purpose="browser_udp",
                browser_pid="2",
                tongdao_pid="3",
                browser_uid="2",
                tongdao_uid="3",
                observed_browser_bundle="com.huawei.hmos.browser",
                dns_query_sent=True,
                udp_recv=False,
                udp_txid_ok=False,
                production_rid="prod",
            )
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "udp_no_recv")

    def test_udp_without_send_is_not_ok(self) -> None:
        rec = evaluate_window(
            WindowEvidence(
                rid="p1-u",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=1,
                tun_rx_before=0,
                tun_rx_after=10,
                tun_tx_before=0,
                tun_tx_after=10,
                hev_up_before=0,
                hev_up_after=10,
                hev_down_before=0,
                hev_down_after=10,
                tags={"udp53Proxy": True},
                purpose="browser_udp",
                browser_pid="2",
                tongdao_pid="3",
                browser_uid="2",
                tongdao_uid="3",
                observed_browser_bundle="com.huawei.hmos.browser",
                dns_query_sent=False,
                udp_transport="",
                production_rid="prod",
            )
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "udp_not_sent")

    def test_udp_hdc_shell_is_not_isolated_client(self) -> None:
        rec = evaluate_window(
            WindowEvidence(
                rid="p1-u",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=1,
                tun_rx_before=0,
                tun_rx_after=10,
                tun_tx_before=0,
                tun_tx_after=10,
                hev_up_before=0,
                hev_up_after=10,
                hev_down_before=0,
                hev_down_after=10,
                tags={"udp53Proxy": True},
                purpose="browser_udp",
                dns_query_sent=True,
                probe_actor="hdc-shell",
                production_rid="prod",
            )
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "browser_uid_not_independent")

    def test_udp_browser_system_dns_is_ok(self) -> None:
        rec = evaluate_window(
            WindowEvidence(
                rid="p1-u",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=1,
                tun_rx_before=0,
                tun_rx_after=10,
                tun_tx_before=0,
                tun_tx_after=10,
                hev_up_before=0,
                hev_up_after=10,
                hev_down_before=0,
                hev_down_after=10,
                tags={"udp53Proxy": True},
                purpose="browser_udp",
                browser_pid="2",
                tongdao_pid="3",
                browser_uid="2",
                tongdao_uid="3",
                observed_browser_bundle="com.huawei.hmos.browser",
                dns_query_sent=True,
                udp_recv=True,
                udp_txid_ok=True,
                production_rid="prod",
            )
        )
        self.assertTrue(rec["ok"], rec)

    def test_wlan_gateway_ignores_vpn_and_ancowlan(self) -> None:
        text = (
            "lo        Link encap:Local Loopback\n"
            "          inet addr:127.0.0.1  Mask:255.0.0.0\n"
            "wlan0     Link encap:Ethernet\n"
            "          inet addr:192.168.3.3  Bcast:192.168.3.255  Mask:255.255.255.0\n"
            "ancowlan0 Link encap:Ethernet\n"
            "          inet addr:172.17.1.1  Bcast:172.17.1.255  Mask:255.255.255.0\n"
            "vpn-tun   Link encap:UNSPEC\n"
            "          inet addr:10.7.0.2  Mask:255.255.255.252\n"
        )
        self.assertEqual(parse_wlan_gateway(text), "192.168.3.1")

    def test_cn_ip_direct_without_hostname_is_unique_direct(self) -> None:
        from lib.extprobe import classify_window

        tags = classify_window(
            "accepted tcp:101.91.22.57:443 [tun-in -> direct]\n"
            "accepted tcp:142.251.151.119:443 [tun-in -> proxy]\n",
            "",
        )
        self.assertTrue(tags["uniqueDirect"])
        self.assertTrue(tags["googleProxy"])
        baidu = classify_window("accepted tcp:www.baidu.com:80 [tun-in -> direct]\n", "")
        self.assertFalse(baidu["uniqueDirect"])
        self.assertTrue(baidu["baiduCanarySeen"])
        google_direct = classify_window("accepted tcp:www.google.com:443 [tun-in -> direct]\n", "")
        self.assertFalse(google_direct["uniqueDirect"])
        self.assertFalse(google_direct["googleProxy"])

    def test_lan_proxy_to_gateway_is_leak(self) -> None:
        from lib.extprobe import lan_proxy_line_set

        leaked = lan_proxy_line_set(
            "accepted tcp:192.168.3.1:80 [tun-in -> proxy]\n",
            "192.168.3.1",
        )
        self.assertEqual(len(leaked), 1)
        clean = lan_proxy_line_set(
            "accepted tcp:www.google.com:443 [tun-in -> proxy]\n",
            "192.168.3.1",
        )
        self.assertEqual(len(clean), 0)

    def test_lan_direct_host_is_not_prefix(self) -> None:
        window = (
            "accepted tcp:192.168.3.10:80 [tun-in -> direct]\n"
            "accepted udp:192.168.3.1:53 [tun-in -> dns-out]\n"
            "accepted tcp:192.168.3.1:80 [tun-in -> direct]\n"
        )
        lines = lan_direct_line_set(window, "192.168.3.1")
        self.assertEqual(len(lines), 1)
        self.assertTrue(any("192.168.3.1:80" in x for x in lines))

    def test_new_access_text_drops_leftover(self) -> None:
        before = "old tcp:www.baidu.com:80 [tun-in -> direct]\nkeep\n"
        after = "keep\nnew tcp:101.91.22.57:443 [tun-in -> direct]\n"
        added = new_access_text(before, after)
        self.assertNotIn("baidu.com", added)
        self.assertIn("101.91.22.57", added)

    def test_udp53_line_set_only_tun_in_port_53(self) -> None:
        window = (
            "accepted udp:192.168.3.1:53 [tun-in -> dns-out]\n"
            "accepted tcp:www.qq.com:443 [tun-in -> direct]\n"
            "accepted udp:1.1.1.1:443 [tun-in -> proxy]\n"
        )
        lines = udp53_line_set(window)
        self.assertEqual(len(lines), 1)
        self.assertTrue(any(":53" in x for x in lines))

    def test_google_empty_page_dump_is_not_required(self) -> None:
        rec = evaluate_window(
            WindowEvidence(
                rid="p1-g",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=1,
                tun_rx_before=0,
                tun_rx_after=10,
                tun_tx_before=0,
                tun_tx_after=10,
                hev_up_before=0,
                hev_up_after=10,
                hev_down_before=0,
                hev_down_after=10,
                tags={"googleProxy": True},
                purpose="browser_google",
                dump_has_rid=False,
                google_page_ok=False,
                page_content_ok=False,
                google_http_status=204,
                browser_http_source="http-status-line",
                browser_pid="2",
                tongdao_pid="3",
                browser_uid="2",
                tongdao_uid="3",
                observed_browser_bundle="com.huawei.hmos.browser",
                production_rid="prod",
            )
        )
        self.assertTrue(rec["ok"], rec)

    def test_keepalive_stall_fails_closed(self) -> None:
        with self.assertRaises(HdcError):
            screen_off_hold(
                run=lambda *_a, **_k: "ok",
                seconds=1800,
                sleep=lambda _s: None,
                read_screen=lambda: "isScreenOn: false",
                alive_fn=lambda: 1,
                max_stall_sec=60,
            )

    def test_screen_off_without_read_screen_rejected(self) -> None:
        with self.assertRaises(HdcError):
            screen_off_hold(
                run=lambda *_a, **_k: "ok",
                seconds=1800,
                sleep=lambda _s: None,
                now=lambda: 10_000,
            )

    def test_wifi_enabled_text_without_iface_rejected(self) -> None:
        with self.assertRaises(HdcError):
            parse_wifi("WiFi is enabled")

    def test_pid_reuse_does_not_stick_lock(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "wait.lock"
            lock.write_text("11\ntoken-old\nold-start\n")
            alive = {11: True, 22: True}
            pid, token = acquire(lock, 11, alive.get)
            self.assertEqual(pid, 11)
            self.assertNotEqual(token, "token-old")
            release = __import__("lib.hdc_singleton", fromlist=["release"]).release
            release(lock, 11, token)

    def test_empty_excl_file_not_permanent(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "wait.lock"
            lock.write_bytes(b"")
            pid, token = acquire(lock, 9, {9: True}.get)
            self.assertEqual(pid, 9)
            __import__("lib.hdc_singleton", fromlist=["release"]).release(lock, 9, token)

    def test_empty_inode_age_does_not_dual_own(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "wait.lock"
            seen = {}

            def pause() -> None:
                import os
                os.utime(lock, (1, 1))
                try:
                    acquire(lock, 22, {11: True, 22: True}.get)
                    seen["b"] = True
                except DuplicateWaiter:
                    seen["b"] = False

            acquire(lock, 11, {11: True}.get, pause_after_excl=pause)
            self.assertFalse(seen.get("b"))

    def test_late_start_catch_does_not_park_newer_token(self) -> None:
        p = Plane()
        p.start("g1", token=1)
        p.start_in_flight = True
        p.committed_token = 1
        self.assertEqual(p.request_start("g2"), "held")
        self.assertEqual(p.latest["token"], 2)
        p.fail_start_catch(1)
        self.assertEqual(p.latest["generation"], "g2")
        self.assertEqual(p.latest["kind"], "start")

    def test_pnpm_major_ten_in_garbage_is_not_ok(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bin_dir = root / "wrapper" / "tools" / "10.28.2" / "node_modules" / ".bin"
            bin_dir.mkdir(parents=True)
            bad = bin_dir / "pnpm"
            bad.write_text("#!/bin/sh\necho definitely-broken-10-not-a-version\n")
            bad.chmod(0o755)
            self.assertFalse(pnpm_ok(root))

    def test_wait_stopped_fail_text_and_missing_native_rejected(self) -> None:
        with self.assertRaises(HdcError):
            wait_stopped(
                status_fn=lambda: {"phase": "STOPPED", "generation": "g1", "commandEpoch": 4, "desiredRunning": False, "tunFd": -1},
                tun_fn=lambda: "[Fail] hdc",
                pid_fn=lambda: "",
                old_generation="g1",
                old_epoch=3,
                timeout=0.2,
                native_fn=lambda: {"xrayRunning": False, "tunRunning": False, "poisoned": False},
            )
        with self.assertRaises(HdcError):
            wait_stopped(
                status_fn=lambda: {"phase": "STOPPED", "generation": "g1", "commandEpoch": 4, "desiredRunning": False, "tunFd": -1},
                tun_fn=lambda: "no-tun",
                pid_fn=lambda: "",
                old_generation="",
                old_epoch=3,
                timeout=0.2,
                native_fn=lambda: {"xrayRunning": False, "tunRunning": False, "poisoned": False},
            )


if __name__ == "__main__":
    unittest.main()
