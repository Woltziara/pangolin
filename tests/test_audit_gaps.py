#!/usr/bin/env python3
"""Regressions that fail the audited false-online / race implementations."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.atomic_file import recover_canonical, write_atomic_ohos  # noqa: E402
from lib.dataplane_fsm import PHASE_CANARY_OK, PHASE_ERROR, Plane  # noqa: E402
from lib.event_store import EventGap, EventSnapshot  # noqa: E402
from lib.extprobe import BROWSER_BUNDLE, HdcError, UNIQUE_DIRECT_HOST, UNIQUE_PROXY_HOST, WindowEvidence, classify_window, evaluate_window, parse_google_http_helper, slice_raw_window  # noqa: E402
from lib.hdc_singleton import DuplicateWaiter, acquire, release, try_acquire  # noqa: E402
from lib.live_evidence import PHASE_DEGRADED_UNPROVEN, PHASE_UNPROVEN, PlaneSnapshot, has_fresh_plane_evidence, phase_from_evidence  # noqa: E402
from lib.provenance import (  # noqa: E402
    AUTHORIZED_SIGNER_FINGERPRINT,
    ProvenanceError,
    assert_installable,
    atomic_publish_hap,
    check_hap_artifact,
    fingerprint_from_verify_app_text,
    git_tracked_producers,
    source_tree_digest,
)

def _w(**kw) -> WindowEvidence:
    rid = str(kw.get("rid") or "r1")
    kw.setdefault("consumed", True)
    kw.setdefault("evidence_rid", rid)
    kw.setdefault("consumed_rid", rid)
    rev = int(kw.get("revision_after", kw.get("revision_before", 1)))
    kw.setdefault("probe_revision", rev)
    kw.setdefault("google_http_helper", True)
    kw.setdefault("dns_helper", True)
    if kw.get("browser_pid"):
        kw.setdefault("browser_uid", str(kw.get("browser_pid")))
    if kw.get("tongdao_pid"):
        kw.setdefault("tongdao_uid", str(kw.get("tongdao_pid")))
    kw.setdefault("observed_browser_bundle", kw.get("browser_bundle", BROWSER_BUNDLE))
    kw.setdefault("consumed_generation", kw.get("generation_after", "g"))
    kw.setdefault("consumed_revision", rev)
    kw.setdefault("consumed_access_offset", 0)
    kw.setdefault("consumed_raw_cursor", 0)
    kw.setdefault("consumed_epoch", 1)
    kw.setdefault("consumed_at", 1)
    return WindowEvidence(**kw)


TUNNEL = ROOT / "entry/src/main/ets/vpn/TunnelVpnAbility.ets"
STORE = ROOT / "entry/src/main/ets/services/StatusStore.ets"
EVENTS = ROOT / "entry/src/main/ets/services/EventStore.ets"
INDEX = ROOT / "entry/src/main/ets/pages/Index.ets"
CTRL = ROOT / "entry/src/main/ets/services/ConnectionController.ets"


def _snap(**kwargs) -> PlaneSnapshot:
    base = dict(
        generation="g1",
        session_id="g1",
        session_revision=1,
        tun_fd_valid=True,
        xray_running=True,
        tun_running=True,
        tun_bytes=0,
        hev_bytes=0,
        last_tun_bytes=0,
        last_hev_bytes=0,
    )
    base.update(kwargs)
    return PlaneSnapshot(**base)


class RollingFreshTest(unittest.TestCase):
    def test_first_delta_pass_then_identical_counters_lose_canary(self) -> None:
        p = Plane()
        p.start("g1")
        p.bind_probe("rid-1")
        p.grow(5, 5)
        self.assertEqual(p.phase, PHASE_CANARY_OK)
        self.assertTrue(p.canary_ok)
        p.xray_running = True
        p.tun_running = True
        p.tick_frozen()
        self.assertFalse(p.canary_ok)
        self.assertEqual(p.phase, PHASE_DEGRADED_UNPROVEN)
        p.tick_frozen()
        self.assertEqual(p.phase, PHASE_DEGRADED_UNPROVEN)
        self.assertNotEqual(p.recover(), "ok")

    def test_running_true_does_not_revive_frozen(self) -> None:
        snap = _snap(tun_rx=20, tun_tx=20, hev_up=20, hev_down=20,
                     last_tun_rx=20, last_tun_tx=20, last_hev_up=20, last_hev_down=20,
                     xray_running=True, tun_running=True, ever_proven=True, bound_rid="r")
        self.assertFalse(has_fresh_plane_evidence(snap))
        self.assertEqual(phase_from_evidence(snap, PHASE_CANARY_OK), PHASE_DEGRADED_UNPROVEN)

    def test_new_delta_restores(self) -> None:
        p = Plane()
        p.start("g1")
        p.bind_probe("rid-1")
        p.grow(2, 2)
        p.tick_frozen()
        self.assertEqual(p.phase, PHASE_DEGRADED_UNPROVEN)
        p.bind_probe("rid-2")
        p.grow(3, 3)
        self.assertEqual(p.phase, PHASE_CANARY_OK)

    def test_unidirectional_growth_not_canary(self) -> None:
        p = Plane()
        p.start("g1")
        p.bind_probe("rid-1")
        p.grow_unidirectional()
        self.assertNotEqual(p.phase, PHASE_CANARY_OK)
        self.assertFalse(p.canary_ok)

    def test_noise_without_rid_not_canary(self) -> None:
        p = Plane()
        p.start("g1")
        p.access_proxy = True
        p.access_direct = True
        p.access_udp = True
        p.grow(9, 9)
        self.assertFalse(p.canary_ok)
        self.assertNotEqual(p.phase, PHASE_CANARY_OK)

    def test_never_proven_is_unproven_not_error(self) -> None:
        snap = _snap(tun_bytes=0, hev_bytes=0, last_tun_bytes=0, last_hev_bytes=0)
        self.assertEqual(phase_from_evidence(snap, "FORWARDER_RUNNING"), PHASE_UNPROVEN)

    def test_source_advances_sample_on_success(self) -> None:
        text = TUNNEL.read_text(encoding="utf-8")
        self.assertIn("lastSampleTunBytes", text)
        self.assertIn("PHASE_DEGRADED_UNPROVEN", text)
        self.assertIn("this.status.lastSampleTunBytes = this.status.tunRxBytes + this.status.tunTxBytes", text)


class ProbeAttrTest(unittest.TestCase):
    def _ok_tags(self, rid: str = "r1") -> dict:
        window = "\n".join(
            [
                f"tcp:{UNIQUE_PROXY_HOST}:80 [tun-in -> proxy] {rid}",
                f"tcp:{UNIQUE_DIRECT_HOST}:80 [tun-in -> direct] {rid}",
                "udp:8.8.8.8:53 [tun-in -> proxy]",
                "tcp:[2001:4860::]:443 [tun-in -> proxy]",
            ]
        )
        return classify_window(window, rid)

    def test_rid_empty_raises(self) -> None:
        with self.assertRaises(HdcError):
            evaluate_window(
                _w(
                    rid="", generation_before="g", generation_after="g",
                    revision_before=1, revision_after=1,
                    tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                    hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                    tags=self._ok_tags("r1"), google_page_ok=True, direct_page_ok=True,
                    browser_pid="1", tongdao_pid="2",
                )
            )

    def test_google_direct_qq_proxy_unrelated_must_fail(self) -> None:
        window = "\n".join(
            [
                "accepted tcp:www.google.com:443 [tun-in -> direct]",
                "accepted tcp:www.qq.com:443 [tun-in -> proxy]",
                "accepted tcp:example.com:443 [tun-in -> proxy]",
                "accepted tcp:www.baidu.com:80 [tun-in -> direct]",
                "accepted tcp:1.1.1.1:53 [tun-in -> proxy]",
                "accepted udp:8.8.8.8:53 [tun-in -> proxy]",
            ]
        )
        tags = classify_window(window, "r1")
        self.assertFalse(tags["googleProxy"])
        self.assertFalse(tags["uniqueDirect"])
        self.assertTrue(tags["udp53Proxy"])
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=True, direct_page_ok=True,
                browser_pid="1", tongdao_pid="2",
            )
        )
        self.assertFalse(rec["ok"])

    def test_tcp_53_is_not_udp(self) -> None:
        tags = classify_window("accepted tcp:1.1.1.1:53 [tun-in -> proxy]\n", "r1")
        self.assertFalse(tags["udp53Proxy"])

    def test_same_uid_fails(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=True, direct_page_ok=True,
                rid_in_page=True, browser_pid="9", tongdao_pid="9",
            )
        )
        self.assertEqual(rec["reason"], "browser_uid_not_independent")

    def test_total_counter_growth_without_bidirectional_fails(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=9, tun_tx_before=4, tun_tx_after=4,
                hev_up_before=1, hev_up_after=9, hev_down_before=1, hev_down_after=1,
                tags=tags, google_page_ok=True, direct_page_ok=True,
                rid_in_page=True, browser_pid="1", tongdao_pid="2",
            )
        )
        self.assertFalse(rec["ok"])
        self.assertIn("bidirectional", rec["reason"])

    def test_direct_page_required(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=True, direct_page_ok=False,
                rid_in_page=True, browser_pid="1", tongdao_pid="2",
            )
        )
        self.assertEqual(rec["reason"], "direct_page_fail")

    def test_unique_hosts_and_pages_pass(self) -> None:
        tags = self._ok_tags("r9")
        rec = evaluate_window(
            _w(
                rid="r9", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=3, tun_tx_before=1, tun_tx_after=4,
                hev_up_before=1, hev_up_after=5, hev_down_before=2, hev_down_after=6,
                tags=tags, google_page_ok=True, direct_page_ok=True,
                rid_in_page=True, browser_pid="37209", tongdao_pid="58975",
            )
        )
        self.assertTrue(rec["ok"], rec)

    def test_wrong_browser_bundle_fails(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=True, direct_page_ok=True, http_ok=True,
                rid_in_page=True, browser_pid="1", tongdao_pid="2",
                browser_bundle="com.other.browser",
            )
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "wrong_browser_bundle")

    def test_https_query_rid_not_required_in_access_log(self) -> None:
        tags = self._ok_tags("r1")
        tags["ridSeen"] = False
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=True, direct_page_ok=True, http_ok=True,
                rid_in_page=False, access_offset=0,
                browser_pid="1", tongdao_pid="2", browser_bundle=BROWSER_BUNDLE,
            )
        )
        self.assertTrue(rec["ok"], rec)

    def test_slice_raw_window_remaps_rotated_log(self) -> None:
        before = "AAAA" + "B" * 8
        extra = "CCCC"
        combined = before + extra
        after = combined[-10:]  # drop 2 of A
        window = slice_raw_window(before, after, len(before))
        self.assertEqual(window, extra)

    def test_missing_access_offset_fails(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=True, direct_page_ok=True, http_ok=True,
                rid_in_page=True, access_offset=-1,
                browser_pid="1", tongdao_pid="2",
            )
        )
        self.assertEqual(rec["reason"], "missing_access_offset")

    def test_unobserved_browser_bundle_fails(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=True, direct_page_ok=True,
                browser_pid="1", tongdao_pid="2",
                observed_browser_bundle="",
            )
        )
        self.assertEqual(rec["reason"], "browser_bundle_unobserved")

    def test_issued_doc_is_not_production_commit(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, purpose="production", commit_kind="issued",
                status_phase="CANARY_OK", last_proven_rid="r1",
                google_http_status=204, direct_http_status=200, dns_helper=True,
            )
        )
        self.assertEqual(rec["reason"], "issued_is_not_commit")

    def test_browser_google_does_not_use_direct_tags(self) -> None:
        tags = classify_window("accepted tcp:www.qq.com:443 [tun-in -> direct]\n", "r1")
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, purpose="browser_google", google_page_ok=True,
                page_content_ok=True, dump_has_rid=True,
                browser_pid="1", tongdao_pid="2",
                google_http_status=204, browser_http_source="http-status-line",
            )
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "googleProxy=false")

    def test_helper_cannot_replace_google_page(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=False, direct_page_ok=True, http_ok=True,
                rid_in_page=True, browser_pid="1", tongdao_pid="2",
                google_http_helper=True,
            )
        )
        self.assertEqual(rec["reason"], "google_page_fail")

    def test_unconsumed_marker_fails(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=True, direct_page_ok=True,
                rid_in_page=True, browser_pid="1", tongdao_pid="2",
                consumed=False,
            )
        )
        self.assertEqual(rec["reason"], "probe_not_consumed")

    def test_marker_rid_mismatch_fails(self) -> None:
        tags = self._ok_tags()
        rec = evaluate_window(
            _w(
                rid="r1", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=1, tun_rx_after=2, tun_tx_before=1, tun_tx_after=2,
                hev_up_before=1, hev_up_after=2, hev_down_before=1, hev_down_after=2,
                tags=tags, google_page_ok=True, direct_page_ok=True,
                rid_in_page=True, browser_pid="1", tongdao_pid="2",
                evidence_rid="other",
            )
        )
        self.assertEqual(rec["reason"], "marker_status_rid_mismatch")

    def test_google_http_helper_parse(self) -> None:
        self.assertTrue(parse_google_http_helper("204", ""))
        self.assertTrue(parse_google_http_helper("HTTP/1.1 204 No Content", ""))
        self.assertTrue(parse_google_http_helper("", '{"googleHttp":204,"googleLine":"HTTP/1.1 204 No Content"}'))
        self.assertFalse(parse_google_http_helper("", '{"googleHttp":0,"googleLine":"HTTP/1.1 204 No Content"}'))
        self.assertFalse(parse_google_http_helper("", '{"googleHttp":0,"noise":"204"}'))
        self.assertFalse(parse_google_http_helper("", ""))
        self.assertFalse(parse_google_http_helper("200", ""))


class EventSnapshotTest(unittest.TestCase):
    def test_crash_between_two_writes_cannot_reuse_seq(self) -> None:
        snap = EventSnapshot()
        snap.append("tick", "g1", 1)
        raw = snap.to_json()
        # Old impl: write jsonl then crash before head → nextSeq reads stale head=0 → seq 1 reused.
        recovered = EventSnapshot.from_json(raw)
        recovered.append("tick", "g1", 1)
        self.assertEqual(recovered.seq, 2)
        self.assertEqual(recovered.events[-1]["seq"], 2)

    def test_second_session_isolated(self) -> None:
        snap = EventSnapshot()
        snap.append("start", "g1", 1)
        snap.append("tick", "g1", 1)
        snap.append("start", "g2", 1)
        self.assertEqual(snap.generation, "g2")
        self.assertEqual(snap.seq, 1)
        gens = {e["generation"] for e in snap.events}
        self.assertEqual(gens, {"g2"})

    def test_source_writes_snapshot_only(self) -> None:
        text = EVENTS.read_text(encoding="utf-8")
        self.assertIn("EVENT_SNAPSHOT_FILE", text)
        self.assertNotIn("appendLine", text)
        self.assertIn("recoverCanonical", text)
        self.assertIn("refuse seq reuse", text)
        self.assertIn("windowStartSeq", text)
        self.assertIn("event rolling window gap", text)

    def test_snapshot_window_gap_vs_last_seq_fail_closed(self) -> None:
        from lib.soak_round import SoakFail, check_event_snapshot

        snap = EventSnapshot()
        for _ in range(405):
            snap.append("tick", "g1", 1)
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "snap.json"
            path.write_text(snap.to_json(), encoding="utf-8")
            with self.assertRaises(SoakFail) as ctx:
                check_event_snapshot(
                    snapshot_path=path,
                    last_seq=1,
                    want_gen="g1",
                    want_rev=1,
                    recv_rc=0,
                )
            self.assertIn("event_window_gap", ctx.exception.reason)
            seq = check_event_snapshot(
                snapshot_path=path,
                last_seq=400,
                want_gen="g1",
                want_rev=1,
                recv_rc=0,
            )
            self.assertEqual(seq, 405)

    def test_rolling_window_keeps_seq_continuous(self) -> None:
        snap = EventSnapshot()
        for i in range(405):
            snap.append("tick", "g1", 1)
        self.assertEqual(snap.seq, 405)
        self.assertEqual(len(snap.events), 400)
        self.assertEqual(snap.events[0]["seq"], 6)
        self.assertEqual(snap.events[-1]["seq"], 405)
        for i in range(1, len(snap.events)):
            self.assertEqual(snap.events[i]["seq"], snap.events[i - 1]["seq"] + 1)

    def test_from_json_requires_window_start_seq(self) -> None:
        snap = EventSnapshot()
        snap.append("tick", "g1", 1)
        doc = json.loads(snap.to_json())
        self.assertEqual(doc["windowStartSeq"], 1)
        loaded = EventSnapshot.from_json(snap.to_json())
        self.assertEqual(loaded.window_start_seq, 1)
        del doc["windowStartSeq"]
        with self.assertRaises(EventGap):
            EventSnapshot.from_json(json.dumps(doc))

    def test_seq_without_generation_is_corrupt(self) -> None:
        with self.assertRaises(EventGap):
            EventSnapshot.from_json('{"seq":4,"sessionRevision":1,"events":[{"seq":4,"generation":"g1"}]}')

    def test_parse_fail_refuses_seq_reuse(self) -> None:
        with self.assertRaises(EventGap):
            EventSnapshot.from_json("{not-json")

    def test_load_corrupt_marks_seq_negative(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dataplane-event-snapshot.json"
            path.write_text("{not-json", encoding="utf-8")
            loaded = EventSnapshot.load(path)
            self.assertEqual(loaded.seq, -1)
            with self.assertRaises(EventGap):
                loaded.append("tick", "g1", 1)


class StartCleanupTest(unittest.TestCase):
    def test_late_create_destroys_orphan(self) -> None:
        p = Plane()
        p.start("g1")
        p.cancelled = True
        p.vpn_connection = None
        self.assertEqual(p.finish_create("g1", fd=99, conn_handle="local-conn"), "orphan-destroyed")
        self.assertTrue(p.destroyed)
        self.assertEqual(p.tun_fd, -1)
        self.assertIn("orphan-tun-destroyed-local-handle", p.writes)

    def test_create_fd_negative_is_error(self) -> None:
        p = Plane()
        p.start("g1")
        self.assertEqual(p.finish_create("g1", fd=-1, conn_handle="local-conn"), "create-fd-invalid")
        self.assertEqual(p.phase, PHASE_ERROR)
        self.assertEqual(p.tun_fd, -1)

    def test_orphan_destroy_failure_is_error(self) -> None:
        p = Plane()
        p.start("g1")
        p.cancelled = True
        self.assertEqual(p.finish_create("g1", fd=99, conn_handle="local-conn", destroy_ok=False), "orphan-destroy-failed")
        self.assertEqual(p.phase, PHASE_ERROR)

    def test_start_during_cleanup_is_queued(self) -> None:
        p = Plane()
        p.start("g1")
        p.cleaning_up = True
        p.cancelled = True
        self.assertEqual(p.request_start("g2"), "held")
        p.teardown(True, True, True)
        self.assertEqual(p.generation, "g2")
        self.assertFalse(p.cleaning_up)

    def test_stop_cancels_queued_start(self) -> None:
        p = Plane()
        p.start("g1")
        p.cleaning_up = True
        p.cancelled = True
        self.assertEqual(p.request_start("g2"), "held")
        self.assertEqual(p.request_stop(), "held")
        self.assertEqual(p.latest["kind"], "stop")
        p.teardown(True, True, True)
        self.assertFalse(p.desired_running)
        self.assertEqual(p.pending_start, "")
        self.assertNotEqual(p.generation, "g2")

    def test_later_start_switches_session(self) -> None:
        p = Plane()
        p.start("g1")
        self.assertEqual(p.request_start("g2"), "switch")
        self.assertIn("switch-session", p.writes)

    def test_timeout_old_generation_not_success(self) -> None:
        p = Plane()
        self.assertEqual(p.wait_phase("new", "old", PHASE_CANARY_OK, timeout=True), "timeout-mismatch")

    def test_cleanup_clears_truth_values(self) -> None:
        p = Plane()
        p.start("g1")
        p.protect_ok = True
        p.direct_ok = True
        p.teardown(True, True, True)
        self.assertFalse(p.protect_ok)
        self.assertFalse(p.direct_ok)
        self.assertEqual(p.tun_fd, -1)
        self.assertEqual(p.socks_port, 0)
        self.assertFalse(p.dns_ok)
        self.assertFalse(p.tun_receiving)

    def test_stop_timeout_still_destroys(self) -> None:
        p = Plane()
        p.start("g1")
        p.teardown(True, True, True, stop_timeout=True)
        self.assertTrue(p.destroyed)
        self.assertEqual(p.phase, PHASE_ERROR)

    def test_source_guards(self) -> None:
        tun = TUNNEL.read_text(encoding="utf-8")
        self.assertIn("local handle", tun)
        self.assertIn("ignore duplicate start token", tun)
        self.assertIn("resetPlaneTruth", tun)
        cpp = (ROOT / "entry/src/main/cpp/napi_init.cpp").read_text()
        self.assertIn("NATIVE_STOP_TIMEOUT_MS", cpp)
        self.assertIn("KeepOrphan", cpp)
        self.assertIn("MarkPoisoned", cpp)
        self.assertIn("AtomicReplaceFile", cpp)
        self.assertIn("TMP_GRACE_SEC", cpp)
        self.assertIn("TMP_UNLINK_MAX", cpp)
        self.assertNotIn("32 + cap", cpp)
        self.assertNotIn("JoinPthreadBounded", cpp)
        self.assertNotIn("JoinStdThreadBounded", cpp)
        self.assertIn("atomicReplaceFile", STORE.read_text(encoding="utf-8"))
        self.assertIn("queue start until in-flight command finishes", tun)
        self.assertIn("abortPoisonedNative", tun)
        self.assertIn("accessOffset", tun)
        self.assertIn("probe-commit.json", tun)
        self.assertIn("rawCursor", tun)
        self.assertIn("tunFd<0", tun)
        self.assertIn("issueSelfProbe", tun)
        self.assertIn("writeProbeCommit", tun)
        self.assertNotIn("StatusStore.writeText(this.context, 'probe-consumed.json'", tun)
        self.assertIn("failClosed", tun)
        self.assertIn("applyDesired", tun)
        self.assertIn("rotateAccessAfterStop", tun)
        self.assertIn("parseAccessLine", tun)
        self.assertNotIn("window.indexOf(rid)", tun)
        self.assertNotIn("window.indexOf(':53 [tun-in -> proxy]')", tun)
        self.assertNotIn("this.tunFd = await conn.create", tun)
        self.assertIn("const localFd = await conn.create", tun)
        self.assertIn("xray-access-pub.log", tun)
        self.assertIn("Never rewrite xray-access.log", tun)
        self.assertNotIn("appendLine", STORE.read_text(encoding="utf-8"))
        self.assertIn("stopVpnExtensionAbility", CTRL.read_text(encoding="utf-8"))
        self.assertIn("UI wrote STOPPED", CTRL.read_text(encoding="utf-8"))
        self.assertNotIn("waitStop", CTRL.read_text(encoding="utf-8"))
        self.assertNotIn("startVpnExtensionAbility(createStopWant", CTRL.read_text(encoding="utf-8"))
        self.assertNotIn("PROBE_SELF_CHECK.tick", INDEX.read_text(encoding="utf-8"))
        entry = (ROOT / "entry/src/main/ets/entryability/EntryAbility.ets").read_text(encoding="utf-8")
        self.assertIn("BACKGROUND_PROBE_HOST.start", entry)
        self.assertIn("onBackground", entry)
        self.assertIn("HevStopWorker", cpp)
        self.assertIn("Tun2SocksStopWorker", cpp)
        self.assertIn("atomicReplace flock failed", cpp)
        self.assertNotIn("tun2socks stop requested.", cpp)
        self.assertIn("seq > 0 && ledger.generation.length === 0", EVENTS.read_text(encoding="utf-8"))
        idx = INDEX.read_text(encoding="utf-8")
        self.assertIn("!this.running", idx)
        ctrl = CTRL.read_text(encoding="utf-8")
        self.assertIn("旧会话", ctrl)


class OhosAtomicTest(unittest.TestCase):
    def test_no_bak_missing_window(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dataplane-status.json"
            write_atomic_ohos(path, '{"a":1}')
            write_atomic_ohos(path, '{"a":2}', crash_after_tmp=True)
            self.assertTrue(path.exists())
            self.assertIn('"a":1', path.read_text().replace(" ", ""))
            self.assertFalse(list(Path(raw).glob("*.bak")))

    def test_recover_from_tmp_if_dest_missing(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dataplane-status.json"
            tmp = write_atomic_ohos(path, '{"ok":true}', crash_after_tmp=True)
            self.assertFalse(path.exists())
            text = recover_canonical(path)
            self.assertIn("ok", text)
            self.assertTrue(path.exists())

    def test_source_has_no_bak_rename(self) -> None:
        text = STORE.read_text(encoding="utf-8")
        self.assertNotIn("renameSync(path, bak)", text)
        self.assertIn("atomicReplaceFile", text)
        self.assertIn("listFileSync", text)
        self.assertIn("attempt < 2", text)

    def test_second_write_visible_on_canonical(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dataplane-status.json"
            write_atomic_ohos(path, '{"a":1}')
            write_atomic_ohos(path, '{"a":2}')
            self.assertIn('"a":2', path.read_text().replace(" ", ""))
            self.assertEqual(len(list(Path(raw).glob("*.tmp"))), 0)

    def test_cleanup_does_not_unlink_inflight_tmp(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dataplane-status.json"
            write_atomic_ohos(path, '{"a":1}')
            inflight = write_atomic_ohos(path, '{"a":9}', crash_after_tmp=True)
            write_atomic_ohos(path, '{"a":2}')
            self.assertTrue(inflight.exists(), "B cleanup must not delete A's in-flight tmp")
            self.assertIn('"a":2', path.read_text().replace(" ", ""))

    def test_cleanup_unlinks_old_tmp_only(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dataplane-status.json"
            write_atomic_ohos(path, '{"a":1}')
            stale = write_atomic_ohos(path, '{"a":9}', crash_after_tmp=True)
            os.utime(stale, (1_600_000_000, 1_600_000_000))
            write_atomic_ohos(path, '{"a":2}')
            self.assertFalse(stale.exists())
            self.assertIn('"a":2', path.read_text().replace(" ", ""))

    def test_recover_promotes_tmp_if_dest_missing(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dataplane-status.json"
            write_atomic_ohos(path, '{"a":1}')
            write_atomic_ohos(path, '{"a":2}', crash_after_tmp=True)
            path.unlink()
            text = recover_canonical(path)
            self.assertIn('"a":2', text.replace(" ", ""))
            self.assertTrue(path.exists())


class TokenLockTest(unittest.TestCase):
    def test_empty_file_during_excl_is_held(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "wait.lock"
            seen = {}

            def pause() -> None:
                ok, holder, _tok = try_acquire(lock, 22, alive={11: True, 22: True}.get)
                seen["ok"] = ok
                seen["holder"] = holder

            pid, token = acquire(lock, 11, alive={11: True}.get, pause_after_excl=pause)
            self.assertEqual(pid, 11)
            self.assertFalse(seen["ok"])
            release(lock, 11, token)

    def test_empty_token_cannot_drop_lock(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "wait.lock"
            alive = {1: True}
            _p, token = acquire(lock, 1, alive.get)
            release(lock, 1, "")
            ok, _, _ = try_acquire(lock, 2, {1: True, 2: True}.get)
            self.assertFalse(ok)
            release(lock, 1, token)
            ok2, holder, tok = try_acquire(lock, 2, {2: True}.get)
            self.assertTrue(ok2)
            release(lock, 2, tok)

    def test_release_wrong_token_does_not_drop_new_owner(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            lock = Path(raw) / "wait.lock"
            alive = {1: True, 2: True}
            _p, token1 = acquire(lock, 1, alive.get)
            release(lock, 1, token1)
            _p2, token2 = acquire(lock, 2, alive.get)
            release(lock, 1, token1)
            holder, tok, _started = __import__("lib.hdc_singleton", fromlist=["read_holder"]).read_holder(lock)
            self.assertEqual(holder, 2)
            self.assertEqual(tok, token2)
            release(lock, 2, token2)

    def test_old_mkdir_empty_dir_would_double_hold(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            d = Path(raw) / "old.lock"
            d.mkdir()
            # empty dir: new protocol treats live takeover only if pid missing/dead then becomes file
            alive = {1: True, 2: True}
            acquire(d, 1, alive.get)
            with self.assertRaises(DuplicateWaiter):
                acquire(d, 2, alive.get)


class PublishLockTest(unittest.TestCase):
    def test_hash_mismatch_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            hap = Path(raw) / "a.hap"
            hap.write_bytes(b"abc")
            with self.assertRaises(Exception):
                check_hap_artifact(hap, {"hapSha256": "0" * 64, "hapBytes": 3})

    def test_atomic_publish_keeps_immutable(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            src = Path(raw) / "in.hap"
            dest = Path(raw) / "entry-default-signed.hap"
            src.write_bytes(b"hello-hap")
            pub = atomic_publish_hap(src, dest)
            self.assertTrue(Path(pub["immutable"]).is_file())
            self.assertEqual(dest.read_bytes(), b"hello-hap")
            src.write_bytes(b"other")
            self.assertEqual(Path(pub["immutable"]).read_bytes(), b"hello-hap")
            self.assertEqual(oct(Path(pub["immutable"]).stat().st_mode & 0o777), "0o444")

    def test_atomic_publish_rejects_corrupt_frozen(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            src = Path(raw) / "in.hap"
            dest = Path(raw) / "entry-default-signed.hap"
            src.write_bytes(b"hello-hap")
            digest = __import__("hashlib").sha256(b"hello-hap").hexdigest()
            frozen = dest.with_name(f"{dest.stem}.{digest}{dest.suffix}")
            frozen.write_bytes(b"polluted-bytes-not-the-source")
            with self.assertRaises(ProvenanceError) as ctx:
                atomic_publish_hap(src, dest)
            self.assertIn("corrupt", str(ctx.exception))
            self.assertNotEqual(dest.read_bytes() if dest.exists() else b"", b"hello-hap")

    def test_verify_app_fingerprint_skips_profile_cert(self) -> None:
        text = (
            "SHA256: DF:21:A3:C0:9F:79:54:57:93:05:F8:5C:64:F8:0C:AD:86:F7:98:53:EE:3A:88:7C:1D:EC:95:D2:18:DF:3A:37\n"
            "+++++++++++++++++++++++++++certificate #1 +++++++++++++++++++++++++++++++\n"
            "SHA256: 41:72:9B:E2:33:3D:65:F4:34:06:B8:A4:14:4A:FE:59:86:23:8C:5A:54:F9:A8:75:AD:BD:09:5F:EC:2E:87:17\n"
            "certificate #2\n"
            "SHA256: 0D:AA:8A:96:5B:51:53:12:4F:79:D4:B4:23:78:D0:AC:2F:55:36:AC:B5:FC:E1:92:4F:43:72:3E:97:58:71:80\n"
        )
        self.assertEqual(
            fingerprint_from_verify_app_text(text),
            AUTHORIZED_SIGNER_FINGERPRINT,
        )

    def test_hvigor_pnpm_uses_cache_not_fresh_home(self) -> None:
        from lib.hvigor_pnpm import PnpmSeedError, seed_hvigor_pnpm

        r1 = (ROOT / "scripts/r1-build.sh").read_text(encoding="utf-8")
        self.assertIn("seed_hvigor_pnpm", r1)
        self.assertIn("npm_config_audit=false", r1)
        self.assertIn(".runtime/hvigor-pnpm", r1)
        self.assertIn("fetch_timeout", r1)
        with tempfile.TemporaryDirectory() as raw:
            cache = Path(raw) / "cache" / "10.28.2"
            (cache / "node_modules" / ".bin").mkdir(parents=True)
            pnpm = cache / "node_modules" / ".bin" / "pnpm"
            pnpm.write_text("#!/bin/sh\necho 10.28.2\n")
            pnpm.chmod(0o755)
            dest = Path(raw) / "user"
            how = seed_hvigor_pnpm(dest, Path(raw) / "cache", npm="/usr/bin/false")
            self.assertEqual(how, "restored-from-cache")
            self.assertTrue((dest / "wrapper" / "tools" / "10.28.2" / "node_modules" / ".bin" / "pnpm").is_file())

    def test_screen_off_rejects_short_hold(self) -> None:
        from lib.accept_phases import screen_off_hold
        from lib.extprobe import HdcError

        calls: list[str] = []

        def run(*args: str, timeout: int = 40) -> str:
            calls.append(" ".join(args))
            return "ok"

        with self.assertRaises(HdcError):
            screen_off_hold(run=run, seconds=2, sleep=lambda _s: None, now=lambda: 0)

    def test_startstop5_source_is_real_cycles(self) -> None:
        text = (ROOT / "scripts/stage1-startstop5.py").read_text(encoding="utf-8")
        self.assertIn("def start_vpn", text)
        self.assertIn("def stop_vpn", text)
        self.assertIn("wait_canary_commit", text)
        self.assertIn("wait_stopped", text)
        self.assertNotRegex(text, r"for i in range\(1, 6\):\n(?:.*\n){0,8}.*stage1-extprobe.py")

    def test_geo_lock_restore_producer(self) -> None:
        lock = ROOT / "native/GEO_LOCK.json"
        self.assertTrue(lock.is_file())
        restore = (ROOT / "scripts/restore_geo.py").read_text(encoding="utf-8")
        self.assertIn("sha256", restore)
        self.assertIn("geo-cache", restore)
        self.assertIn("urls", lock.read_text(encoding="utf-8"))
        self.assertNotIn("/latest/", lock.read_text(encoding="utf-8"))
        self.assertNotIn("@release", lock.read_text(encoding="utf-8"))
        self.assertIn("urlopen", restore)
        self.assertIn("not immutable", restore)

    def test_device_sh_cannot_sign_or_install(self) -> None:
        text = (ROOT / "scripts/device.sh").read_text(encoding="utf-8")
        self.assertIn("device.sh sign is disabled", text)
        self.assertIn("device.sh install is disabled", text)
        self.assertIn("TONGDAO_DEVICE", text)
        self.assertIn("retired", (ROOT / "scripts/sign-ohos-debug.sh").read_text(encoding="utf-8"))
        self.assertIn("retired", (ROOT / "scripts/build.sh").read_text(encoding="utf-8"))
        self.assertIn("TONGDAO_R1_PUBLISH", (ROOT / "scripts/huawei-sign-hap.sh").read_text(encoding="utf-8"))
        self.assertIn("TONGDAO_SIGN_PERMIT", (ROOT / "scripts/huawei-sign-hap.sh").read_text(encoding="utf-8"))
        self.assertIn("TONGDAO_NATIVE_BUILD", (ROOT / "scripts/build_hev_ohos.sh").read_text(encoding="utf-8"))

    def test_core_lock_not_gitignored(self) -> None:
        gi = (ROOT / ".gitignore").read_text(encoding="utf-8") if (ROOT / ".gitignore").is_file() else ""
        missing = git_tracked_producers(ROOT, gi)
        self.assertEqual(missing, [], missing)

    def test_manifest_without_source_digest_refuses_install(self) -> None:
        hap = ROOT / "entry/build/default/outputs/default/entry-default-signed.hap"
        if not hap.is_file():
            self.skipTest("hap missing")
        digest = __import__("hashlib").sha256(hap.read_bytes()).hexdigest()
        with self.assertRaises(ProvenanceError) as ctx:
            assert_installable(
                ROOT,
                hap,
                {
                    "hapSha256": digest,
                    "hapBytes": hap.stat().st_size,
                    "versionName": "0.3.10-r1",
                    "versionCode": 1000015,
                },
            )
        self.assertIn("sourceTreeDigest", str(ctx.exception))

    def test_stale_hap_vs_current_source_refuses(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            hap = Path(raw) / "old.hap"
            hap.write_bytes(b"stale-package")
            import os
            os.utime(hap, (1_600_000_000, 1_600_000_000))
            digest = source_tree_digest(ROOT)
            man = {
                "hapSha256": __import__("hashlib").sha256(hap.read_bytes()).hexdigest(),
                "hapBytes": hap.stat().st_size,
                "sourceTreeDigest": digest,
                "versionName": "0.3.10-r1",
                "versionCode": 1000015,
            }
            with self.assertRaises(ProvenanceError) as ctx:
                assert_installable(ROOT, hap, man)
            self.assertIn("source newer", str(ctx.exception))

    def test_manifest_without_signer_refuses(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            hap = Path(raw) / "a.hap"
            hap.write_bytes(b"pkg")
            import time
            later = time.time() + 60
            os.utime(hap, (later, later))
            digest = __import__("hashlib").sha256(hap.read_bytes()).hexdigest()
            man = {
                "hapSha256": digest,
                "hapBytes": hap.stat().st_size,
                "sourceTreeDigest": source_tree_digest(ROOT),
                "versionName": "0.3.10-r1",
                "versionCode": 1000015,
            }
            with self.assertRaises(ProvenanceError) as ctx:
                assert_installable(ROOT, hap, man)
            self.assertTrue(
                "not a zip" in str(ctx.exception)
                or "signerFingerprint" in str(ctx.exception)
                or "bundleName" in str(ctx.exception)
                or "missing" in str(ctx.exception)
            )
            import zipfile
            with zipfile.ZipFile(hap, "w") as zf:
                zf.writestr(
                    "module.json",
                    json.dumps({"app": {"versionName": "0.3.10-r1", "versionCode": 1000015, "bundleName": "com.oscarwoltz.tongdao"}}),
                )
                zf.writestr("libs/arm64-v8a/libxray.so", b"x")
                zf.writestr("libs/arm64-v8a/libhevsocks5tun.so", b"h")
            os.utime(hap, (later, later))
            man["hapSha256"] = __import__("hashlib").sha256(hap.read_bytes()).hexdigest()
            man["hapBytes"] = hap.stat().st_size
            man["signerFingerprint"] = "00" * 32
            with self.assertRaises(ProvenanceError) as ctx2:
                assert_installable(ROOT, hap, man)
            self.assertTrue(
                "not authorized" in str(ctx2.exception)
                or "verify-app" in str(ctx2.exception)
                or "signer" in str(ctx2.exception).lower()
                or "bundleName" in str(ctx2.exception)
                or "missing" in str(ctx2.exception)
            )
            man["signerFingerprint"] = AUTHORIZED_SIGNER_FINGERPRINT
            with self.assertRaises(ProvenanceError) as ctx3:
                assert_installable(ROOT, hap, man)
            self.assertTrue(
                "verify-app" in str(ctx3.exception)
                or "signer" in str(ctx3.exception).lower()
                or "missing" in str(ctx3.exception)
            )


if __name__ == "__main__":
    unittest.main()
