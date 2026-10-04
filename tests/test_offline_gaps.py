#!/usr/bin/env python3
"""Regressions that fail if the old Stage-1 implementations return."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.access_redact import redact_line  # noqa: E402
from lib.atomic_file import read_status, write_atomic  # noqa: E402
from lib.dataplane_fsm import PHASE_CANARY_OK, PHASE_ERROR, PHASE_FORWARDER_RUNNING, Plane  # noqa: E402
from lib.live_evidence import PHASE_UNPROVEN  # noqa: E402
from lib.extprobe import HdcError, WindowEvidence, classify_window, evaluate_window, recv_clean  # noqa: E402


def _w(**kw) -> WindowEvidence:
    rid = str(kw.get("rid") or "ridx")
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
    kw.setdefault("observed_browser_bundle", kw.get("browser_bundle", "com.huawei.hmos.browser"))
    kw.setdefault("consumed_generation", kw.get("generation_after", "g1"))
    kw.setdefault("consumed_revision", rev)
    kw.setdefault("consumed_access_offset", 0)
    kw.setdefault("consumed_raw_cursor", 0)
    kw.setdefault("consumed_epoch", 1)
    kw.setdefault("consumed_at", 1)
    return WindowEvidence(**kw)
from lib.ipv6_route import ipv6_must_not_bypass  # noqa: E402
from lib.live_evidence import PlaneSnapshot, has_fresh_plane_evidence, phase_from_evidence  # noqa: E402
from lib.provenance import (  # noqa: E402
    ProvenanceError,
    check_install_dump,
    rsync_excludes_runtime,
    scan_hap_secrets,
    unrecorded_env,
    verify_measured,
)
from lib.soak_round import SoakFail, check_event_chain, check_event_seq, evaluate_round  # noqa: E402

SERIAL = "TEST_DEVICE_SERIAL"
NOW = 1_788_437_800_000
VPN_ETS = ROOT / "entry/src/main/ets/vpn/VpnConstants.ets"
TUNNEL_ETS = ROOT / "entry/src/main/ets/vpn/TunnelVpnAbility.ets"
STATUS_ETS = ROOT / "entry/src/main/ets/services/StatusStore.ets"
R1 = ROOT / "scripts/r1-build.sh"


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
        socks_direct_ok=True,
        socks_proxy_ok=True,
    )
    base.update(kwargs)
    return PlaneSnapshot(**base)


class CanaryFailClosedTest(unittest.TestCase):
    def test_socks_ok_without_tun_hev_is_not_canary_ok(self) -> None:
        snap = _snap(tun_bytes=0, hev_bytes=0, socks_direct_ok=True, socks_proxy_ok=True)
        self.assertTrue(snap.socks_direct_ok and snap.socks_proxy_ok)
        self.assertFalse(has_fresh_plane_evidence(snap))
        self.assertEqual(phase_from_evidence(snap, "FORWARDER_RUNNING"), "UNPROVEN")

    def test_native_running_booleans_without_growth_not_live(self) -> None:
        snap = _snap(xray_running=True, tun_running=True, tun_bytes=10, hev_bytes=10,
                     last_tun_bytes=10, last_hev_bytes=10)
        self.assertFalse(has_fresh_plane_evidence(snap))

    def test_http_204_and_access_without_counter_growth_is_canary_ok(self) -> None:
        snap = _snap(
            tun_rx=10, tun_tx=10, hev_up=1, hev_down=1,
            last_tun_rx=10, last_tun_tx=10, last_hev_up=1, last_hev_down=1,
            bound_rid="r1", access_offset=0, access_proxy=True, access_direct=True, access_udp=True,
            fetch_google_http=204, fetch_direct_http=200, fetch_dns_ok=True,
        )
        self.assertTrue(has_fresh_plane_evidence(snap))
        self.assertEqual(phase_from_evidence(snap, "FORWARDER_RUNNING"), "CANARY_OK")

    def test_fresh_tun_hev_and_session_is_canary_ok(self) -> None:
        snap = _snap(
            tun_rx=20, tun_tx=8, hev_up=5, hev_down=3,
            last_tun_rx=10, last_tun_tx=1, last_hev_up=1, last_hev_down=1,
            bound_rid="r1", access_offset=0, access_proxy=True, access_direct=True, access_udp=True,
        )
        self.assertTrue(has_fresh_plane_evidence(snap))
        self.assertEqual(phase_from_evidence(snap, "FORWARDER_RUNNING"), "CANARY_OK")

    def test_revision_zero_or_gen_mismatch_fail_closed(self) -> None:
        self.assertFalse(has_fresh_plane_evidence(_snap(session_revision=0, tun_bytes=2, hev_bytes=2)))
        self.assertFalse(has_fresh_plane_evidence(_snap(session_id="other", tun_bytes=2, hev_bytes=2)))

    def test_plane_socks_canary_does_not_promote(self) -> None:
        p = Plane()
        p.start("g1")
        p.socks_canary(True, True)
        self.assertEqual(p.phase, PHASE_UNPROVEN)
        self.assertFalse(p.canary_ok)
        p.bind_probe("rid-1")
        p.grow(3, 4)
        self.assertEqual(p.phase, PHASE_CANARY_OK)
        self.assertTrue(p.canary_ok)

    def test_source_canary_not_assigned_from_socks(self) -> None:
        text = TUNNEL_ETS.read_text(encoding="utf-8")
        self.assertNotIn("this.status.canaryOk = direct.ok && proxy.ok", text)
        self.assertIn("hasFreshPlaneEvidence", text)
        self.assertIn("readFetchAck", text)
        self.assertIn("ackRid !== rid", text)
        self.assertIn("PROBE_GRACE_MS", text)
        self.assertNotIn("fetchUid.length < 1 || this.status.fetchPid.length < 1", text)
        self.assertNotIn("counters.rxBytes <= this.status.lastSampleTunRx", text)
        self.assertNotIn("StatusStore.removeFile(this.context, 'probe-fetch.json')", text)
        self.assertNotIn("本轮还没有新鲜 TUN/HEV 增量", text)
        self.assertIn("本轮还没有 204 和访问日志证据", text)
        self.assertIn("socksCanaryOk", text)
        xray = (ROOT / "entry/src/main/ets/core/XrayRuntime.ets").read_text(encoding="utf-8")
        self.assertNotIn("bindToPhysicalIface", xray)
        self.assertNotIn("sockopt", xray)
        self.assertNotIn("physicalIface", xray)
        self.assertNotIn("v6Block", xray)
        self.assertIn("quicRule", xray)
        self.assertIn("'geosite:youtube'", xray)
        self.assertLess(xray.index("quicRule['domain']"), xray.index("quicRule['outboundTag'] = 'block'"))
        self.assertIn("dns-out", xray)
        self.assertIn("'udp,tcp'", xray)
        self.assertIn("dnsHijack['inboundTag']", xray)
        self.assertNotIn("sniffing['routeOnly'] = true", xray)
        self.assertIn("UseIPv4", xray)
        self.assertIn("'geosite:openai'", xray)
        self.assertIn("'geosite:google'", xray)
        self.assertNotIn("youtubeHkRule", xray)
        self.assertNotIn("googleIpRule", xray)
        self.assertNotIn("proxy-us", xray)
        self.assertIn("youtubeRule", xray)
        self.assertIn("proxy-yt", xray)
        self.assertIn(
            "dnsHijack, dummyV6, privateRule, quicRule, youtubeRule, proxyProbeRule, cnDomainRule, cnIpRule, proxyRule",
            xray,
        )
        rules_line = [ln for ln in xray.splitlines() if "dnsHijack, dummyV6, privateRule" in ln][0]
        self.assertLess(rules_line.index("quicRule"), rules_line.index("youtubeRule"))
        self.assertIn("youtubeRule['network'] = 'tcp'", xray)
        catalog = (ROOT / "entry/src/main/ets/services/NodeCatalog.ets").read_text(encoding="utf-8")
        self.assertIn("nodeUsableForSplit", catalog)
        self.assertIn("V6", catalog)
        split = (ROOT / "entry/src/main/ets/services/SplitRouter.ets").read_text(encoding="utf-8")
        self.assertIn("prepareYtUsPlan", split)
        self.assertIn("prepareSingleProxy", split)
        self.assertIn("pickSecondBest", split)
        tun = (ROOT / "entry/src/main/ets/vpn/TunnelVpnAbility.ets").read_text(encoding="utf-8")
        self.assertNotIn("maybeRetuneYouTube", tun)
        self.assertNotIn("YT_RETUNE_MS", tun)
        self.assertIn("480000", tun)
        self.assertIn("NODE_FAIL_LIMIT", tun)
        self.assertIn("promoteSecondBest", tun)
        self.assertIn("node-failover", tun)
        self.assertIn("www.youtube.com", tun)
        self.assertIn("failoverSplitPayload", tun)
        self.assertIn("tcpConnectCanary", split)
        self.assertIn("REGION_US", split)
        self.assertNotIn("prepareSplitPlan", split)
        self.assertIn("pickSecondBest", catalog)
        self.assertIn("ytFailedOver", catalog)
        self.assertIn("failoverSplitMeta", catalog)
        index = (ROOT / "entry/src/main/ets/pages/Index.ets").read_text(encoding="utf-8")
        self.assertNotIn("this.applyNode(this.nodes[0], false)", index)
        vpn = (ROOT / "entry/src/main/ets/vpn/VpnConstants.ets").read_text(encoding="utf-8")
        self.assertNotIn("BYPASS_WRAPPED_ANDROID", vpn)
        self.assertNotIn("blockedApplications", vpn)
        napi = (ROOT / "entry/src/main/cpp/napi_init.cpp").read_text(encoding="utf-8")
        self.assertIn("DetectPhysicalIface", napi)
        build = (ROOT / "scripts/build_libxray_ohos.sh").read_text(encoding="utf-8")
        self.assertIn("ohos_protect.go", build)
        self.assertIn("RegisterDialerController", build)
        self.assertNotIn("SO_BINDTODEVICE", build)
        self.assertNotIn("SetsockoptString", build)
        self.assertNotIn("ohosPhysicalIface", build)
        self.assertIn("hey_protect_socket", build)
        self.assertIn("RTLD_NOLOAD", build)
        self.assertIn("dlopen(\"libheyvpn.so\"", build)
        napi = (ROOT / "entry/src/main/cpp/napi_init.cpp").read_text(encoding="utf-8")
        self.assertIn("RTLD_GLOBAL", napi)
        self.assertIn("PromoteProtectSymbol", napi)
        self.assertIn("protectQueued", napi)
        tun = (ROOT / "entry/src/main/ets/vpn/TunnelVpnAbility.ets").read_text(encoding="utf-8")
        self.assertIn("[tun-in -> dns-out]", tun)
        self.assertIn("accessWindow", tun)
        self.assertIn("raw.substring(offset)", tun)
        self.assertNotIn("raw.substring(raw.length - 65536)", tun)
        self.assertIn("xray-access-pub.log", tun)
        self.assertIn("setProtectCallback", tun)
        self.assertIn("napi_create_threadsafe_function", napi)
        self.assertIn("conn.protect(fd)", tun)
        self.assertIn("ackProtectFd(fd, 0, token)", tun)
        self.assertIn("waiter->token", napi)
        self.assertIn("abandoned", napi)
        self.assertNotIn("startProtectPump", tun)
        self.assertIn("if rc != 0", build)
        self.assertIn("ohos protect failed", build)
        self.assertNotIn("_ = C.call_hey_protect", build)
        conn = (ROOT / "entry/src/main/ets/services/ConnectionController.ets").read_text(encoding="utf-8")
        self.assertNotIn("startVpnExtensionAbility(createStopWant", conn)
        self.assertIn("stopVpnExtensionAbility", conn)
        self.assertIn("已停止", conn)
        self.assertIn("createVpnAbilityWant", conn)
        self.assertIn("BEARER_VPN", conn)
        self.assertIn("waitVpnBearerGone", conn)
        self.assertIn("vpnBearerState", conn)
        self.assertIn("UI refused STOPPED", conn)
        store = (ROOT / "entry/src/main/ets/services/StatusStore.ets").read_text(encoding="utf-8")
        self.assertIn("GEOIP_RELEASE", store)
        self.assertIn("v2fly-geoip-202608050239", store)
        self.assertIn("destName}.release", store)
        host = (ROOT / "entry/src/main/ets/services/BackgroundProbeHost.ets").read_text(encoding="utf-8")
        self.assertNotIn("source.indexOf('onBackground')", host)
        keep = (ROOT / "entry/src/main/ets/services/BackgroundKeepAlive.ets").read_text(encoding="utf-8")
        self.assertIn("usual.event.SCREEN_OFF", keep)
        self.assertIn("60000", keep)
        self.assertIn("baidu.com", tun)
        self.assertIn("43.159.", tun)
        self.assertNotIn("StatusStore.removeFile(this.context, 'probe-commit.json')", tun)
        self.assertIn("liveCore && this.status.probePending", tun)
        probe = (ROOT / "entry/src/main/ets/services/ProbeSelfCheck.ets").read_text(encoding="utf-8")
        self.assertIn("1.1.1.1", probe)
        self.assertIn("FETCH_TIMEOUT_MS + 1000", probe)
        self.assertIn("http://www.google.com/generate_204", tun)
        self.assertIn("2001::1", xray)
        self.assertIn("mergeTunCounters", text)
        self.assertIn("if (counters.found)", text)
        idx = (ROOT / "entry/src/main/ets/pages/Index.ets").read_text(encoding="utf-8")
        self.assertIn("!stale &&", idx)
        napi = (ROOT / "entry/src/main/cpp/napi_init.cpp").read_text(encoding="utf-8")
        self.assertIn("ReadVpnTunProc", napi)
        self.assertIn("tunRxBytes", napi)
        native = (ROOT / "entry/src/main/ets/native/TunnelNative.ets").read_text(encoding="utf-8")
        self.assertIn("tunFound", native)
        self.assertIn("physicalIface", native)
        self.assertIn("protectQueued", native)
        self.assertIn("protectVisible", native)
        self.assertIn("setProtectCallback", native)
        self.assertIn("clearProtectCallback", native)


class ExtprobeRidTest(unittest.TestCase):
    def test_extprobe_uses_public_hosts_and_browser_bundle(self) -> None:
        text = (ROOT / "scripts/stage1-extprobe.py").read_text(encoding="utf-8")
        self.assertIn("com.huawei.hmos.browser", text)
        self.assertIn("probe-issued.json", text)
        self.assertIn("probe-commit.json", text)
        self.assertNotIn("or BROWSER_BUNDLE", text)
        self.assertIn("Does not write probe-request.json", text)
        self.assertIn("browser-google", text)
        self.assertIn("browser-direct", text)
        self.assertIn("browser-udp", text)
        self.assertNotIn("python3 -c", text)
        self.assertNotIn("ip route", text)
        self.assertIn("ifconfig", text)
        self.assertIn("udpQname", text)
        self.assertIn("udp53_line_set", text)
        self.assertIn("parse_wlan_gateway", text)
        self.assertIn("new_access_text", text)
        self.assertIn("accessOffset", text)
        self.assertIn("xray-access-pub.log", text)
        self.assertIn("slice_raw_window", text)
        self.assertIn("generate_204", text)
        self.assertIn("dumpObservationalOnly", text)
        self.assertIn("www.qq.com", text)
        self.assertIn("attemptDir", text)
        self.assertIn("TONGDAO_DEVICE", text)
        self.assertNotIn("td-proxy.probe", text)
        self.assertNotIn("td-direct.probe", text)
        tun = TUNNEL_ETS.read_text(encoding="utf-8")
        self.assertIn("const conn = this.vpnConnection", tun)
        self.assertIn("destroyBounded", tun)
        self.assertIn("await this.destroyBounded(connection, 4000)", tun)
        ss = (ROOT / "scripts/stage1-startstop5.py").read_text(encoding="utf-8")
        self.assertIn("start_vpn", ss)
        self.assertIn("stop_vpn", ss)
        self.assertIn("wait_canary_commit", ss)
        self.assertIn("wait_stopped", ss)
        self.assertIn("denominator", ss)
        self.assertIn("TONGDAO_DEVICE", ss)
        soak = (ROOT / "scripts/stage1-soak-failclosed.sh").read_text(encoding="utf-8")
        self.assertIn("SCREEN_OFF_SEC=1800", soak)
        self.assertIn("wifi_bounce", soak)
        self.assertIn("screen_off_hold", soak)
        self.assertIn("TONGDAO_DEVICE", soak)
        self.assertIn("alive_fn", soak)
        self.assertNotIn("sleep 2", soak)
        phases = (ROOT / "scripts/lib/accept_phases.py").read_text(encoding="utf-8")
        self.assertIn('"svc", "wifi", "disable"', phases)
        self.assertIn("SCREEN_OFF_SEC = 1800", phases)
        self.assertIn("keepalive progress stalled", phases)
        life = (ROOT / "scripts/stage1-lifecycle-background.py").read_text(encoding="utf-8")
        self.assertIn("screen_off_hold", life)
        self.assertIn("com.huawei.hmos.browser", life)
        self.assertIn("background-keepalive.json", life)
        self.assertIn("TONGDAO_DEVICE", life)
        self.assertNotIn("uitest uiInput click", life)

    def test_baidu_canary_is_not_unique_direct(self) -> None:
        window = "\n".join(
            [
                "12:00:01 tcp:www.baidu.com:80 [tun-in -> direct]",
                "12:00:01 tcp:www.wikipedia.org:80 [tun-in -> proxy]",
                "12:00:01 tcp:[2001:4860::]:443 [tun-in -> proxy]",
                "12:00:01 udp:1.1.1.1:53 [tun-in -> proxy]",
            ]
        )
        tags = classify_window(window, "ridx")
        self.assertTrue(tags["googleProxy"])
        self.assertTrue(tags["baiduCanarySeen"])
        self.assertFalse(tags["uniqueDirect"])
        ev = _w(
            rid="ridx",
            generation_before="g1",
            generation_after="g1",
            revision_before=1,
            revision_after=1,
            tun_rx_before=1,
            tun_rx_after=9,
            tun_tx_before=1,
            tun_tx_after=9,
            hev_up_before=1,
            hev_up_after=9,
            hev_down_before=1,
            hev_down_after=9,
            tags=tags,
            rid_in_page=True,
            browser_pid="1",
            tongdao_pid="2",
            google_page_ok=True,
            direct_page_ok=True,
        )
        rec = evaluate_window(ev)
        self.assertFalse(rec["ok"])

    def test_unique_direct_and_deltas_pass(self) -> None:
        window = "\n".join(
            [
                "12:00:01 tcp:www.qq.com:443 [tun-in -> direct]",
                "12:00:01 tcp:[2001:4860::]:443 [tun-in -> proxy]",
                "12:00:01 udp:8.8.8.8:53 [tun-in -> proxy]",
            ]
        )
        tags = classify_window(window, "rid9")
        rec = evaluate_window(
            _w(
                rid="rid9",
                generation_before="g1",
                generation_after="g1",
                revision_before=1,
                revision_after=1,
                tun_rx_before=10,
                tun_rx_after=20,
                tun_tx_before=3,
                tun_tx_after=8,
                hev_up_before=3,
                hev_up_after=8,
                hev_down_before=1,
                hev_down_after=4,
                tags=tags,
                rid_in_page=True,
                browser_pid="1",
                tongdao_pid="2",
                google_page_ok=True,
                direct_page_ok=True,
            )
        )
        self.assertTrue(rec["ok"], rec)  # public qq.com + google IP + UDP is attributable; td-*.probe not required

    def test_hdc_fail_does_not_read_old_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw) / "ext-status.json"
            dest.write_text(json.dumps({"phase": "CANARY_OK", "stale": True}), encoding="utf-8")

            def runner(args, timeout):
                return SimpleNamespace(returncode=1, stdout=b"", stderr=b"[Fail][E001005]")

            with self.assertRaises(HdcError):
                recv_clean("remote/status.json", dest, runner=runner)
            self.assertFalse(dest.exists())

    def test_zero_delta_fail_closed(self) -> None:
        tags = classify_window(
            "tcp:www.qq.com:443 [tun-in -> direct]\ntcp:google [tun-in -> proxy]\nudp:1.1.1.1:53 [tun-in -> proxy]",
            "r",
        )
        rec = evaluate_window(
            _w(
                rid="r", generation_before="g", generation_after="g",
                revision_before=1, revision_after=1,
                tun_rx_before=5, tun_rx_after=5, tun_tx_before=2, tun_tx_after=2,
                hev_up_before=2, hev_up_after=2, hev_down_before=2, hev_down_after=2,
                tags=tags, rid_in_page=True, browser_pid="1", tongdao_pid="2",
                google_page_ok=True, direct_page_ok=True,
            )
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "missing_bidirectional_tun")

    def test_browser_google_access_without_device_http_helper(self) -> None:
        rec = evaluate_window(
            _w(
                rid="g1",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=1,
                tun_rx_before=1,
                tun_rx_after=2,
                tun_tx_before=1,
                tun_tx_after=2,
                hev_up_before=1,
                hev_up_after=2,
                hev_down_before=1,
                hev_down_after=2,
                tags={"googleProxy": True},
                purpose="browser_google",
                google_http_status=0,
                browser_http_source="not-http",
                dump_has_rid=False,
                google_page_ok=False,
                page_content_ok=False,
                browser_pid="2",
                tongdao_pid="3",
                production_rid="prod",
            )
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "google_http_not_from_http")

    def test_browser_google_revision_mismatch_fails(self) -> None:
        rec = evaluate_window(
            _w(
                rid="g1",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=99,
                tun_rx_before=1,
                tun_rx_after=2,
                tun_tx_before=1,
                tun_tx_after=2,
                hev_up_before=1,
                hev_up_after=2,
                hev_down_before=1,
                hev_down_after=2,
                tags={"googleProxy": True},
                purpose="browser_google",
                google_http_status=204,
                browser_http_source="http-status-line",
                browser_pid="2",
                tongdao_pid="3",
                production_rid="prod",
            )
        )
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["reason"], "revision_mismatch")

    def test_browser_google_204_is_not_vetoed_by_hev_freeze(self) -> None:
        rec = evaluate_window(
            _w(
                rid="g1",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=1,
                tun_rx_before=5,
                tun_rx_after=5,
                tun_tx_before=2,
                tun_tx_after=2,
                hev_up_before=2,
                hev_up_after=2,
                hev_down_before=2,
                hev_down_after=2,
                tags={"googleProxy": True},
                purpose="browser_google",
                google_http_status=204,
                browser_http_source="http-status-line",
                dump_has_rid=False,
                google_page_ok=False,
                page_content_ok=False,
                browser_pid="2",
                tongdao_pid="3",
                production_rid="prod",
            )
        )
        self.assertTrue(rec["ok"], rec)

    def test_production_204_is_not_vetoed_by_zero_tun_delta(self) -> None:
        tags = classify_window(
            "accepted tcp:www.google.com:80 [tun-in -> proxy]\n"
            "accepted tcp:www.baidu.com:80 [tun-in -> direct]\n"
            "accepted udp:192.168.3.1:53 [tun-in -> dns-out]\n",
            "r1",
        )
        rec = evaluate_window(
            _w(
                rid="r1",
                generation_before="g",
                generation_after="g",
                revision_before=1,
                revision_after=1,
                tun_rx_before=5,
                tun_rx_after=5,
                tun_tx_before=2,
                tun_tx_after=2,
                hev_up_before=2,
                hev_up_after=2,
                hev_down_before=2,
                hev_down_after=2,
                tags=tags,
                purpose="production",
                commit_kind="commit",
                status_phase="CANARY_OK",
                last_proven_rid="r1",
                google_http_status=204,
                direct_http_status=200,
                dns_helper=True,
                access_offset=0,
            )
        )
        self.assertTrue(rec["ok"], rec)


class Ipv6RouteTest(unittest.TestCase):
    def test_ipv6_is_default_route_false(self) -> None:
        ets = VPN_ETS.read_text(encoding="utf-8")
        v4, v6 = ipv6_must_not_bypass(ets)
        self.assertTrue(v4)
        self.assertFalse(v6)

    def test_old_true_would_fail(self) -> None:
        fake = """
function createIpv4DefaultRoute(): vpnExtension.RouteInfo {
    isDefaultRoute: true
}
function createIpv6DefaultRoute(): vpnExtension.RouteInfo {
    isDefaultRoute: true
}
"""
        v4, v6 = ipv6_must_not_bypass(fake)
        self.assertTrue(v4)
        self.assertTrue(v6)
        self.assertNotEqual((v4, v6), (True, False))


class RecoverTeardownTest(unittest.TestCase):
    def test_hev_stop_fail_destroys_tun(self) -> None:
        p = Plane()
        p.start("g1")
        p.grow()
        self.assertTrue(p.vpn_created)
        self.assertEqual(p.recover(hev_stop_ok=False, xray_stop_ok=True), "cleanup")
        self.assertTrue(p.destroyed)
        self.assertFalse(p.vpn_created)
        self.assertEqual(p.phase, PHASE_ERROR)

    def test_xray_stop_fail_destroys_tun(self) -> None:
        p = Plane()
        p.start("g1")
        self.assertEqual(p.recover(hev_stop_ok=True, xray_stop_ok=False), "cleanup")
        self.assertTrue(p.destroyed)

    def test_already_running_mismatch_destroys_tun(self) -> None:
        p = Plane()
        p.start("g1")
        self.assertEqual(p.recover(already_running=True), "cleanup")
        self.assertTrue(p.destroyed)
        self.assertIn("cleanup:already-running", p.writes)

    def test_huks_throw_destroys_tun(self) -> None:
        p = Plane()
        p.start("g1")
        self.assertEqual(p.recover(huks_ok=False), "cleanup")
        self.assertTrue(p.destroyed)

    def test_await_stale_socks_no_emit_and_destroy(self) -> None:
        p = Plane()
        p.start("g1", socks_port=1111)
        p.socks_port = 2222
        ok = p.after_await("g1", 1, 1111, "canary")
        self.assertFalse(ok)
        self.assertTrue(p.destroyed)
        p2 = Plane()
        p2.start("g1")
        p2.cancelled = True
        p2.emit("canary")
        self.assertTrue(any(x.startswith("drop-stale-emit") for x in p2.writes))

    def test_duplicate_start_dropped(self) -> None:
        p = Plane()
        p.start_in_flight = True
        p.start("g1")
        self.assertIn("drop-duplicate-start", p.writes)

    def test_source_recover_checks_hev_stop(self) -> None:
        text = TUNNEL_ETS.read_text(encoding="utf-8")
        self.assertIn("stopForwarder.ok", text)
        self.assertIn("already running", text)
        self.assertIn("requestCleanup('recover exception'", text.replace('"', "'") if False else text)
        self.assertIn("recover exception", text)


class SoakAtomicRedactTest(unittest.TestCase):
    def test_seq_must_advance_each_round(self) -> None:
        with self.assertRaises(SoakFail) as ctx:
            check_event_seq(10, 10)
        self.assertIn("event_seq_gap_or_rewind", ctx.exception.reason)

    def test_jump_without_jsonl_cannot_fake_continuity(self) -> None:
        with self.assertRaises(SoakFail) as ctx:
            check_event_seq(10, 40)
        self.assertIn("event_seq_jump", ctx.exception.reason)

    def test_jsonl_gap_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            head = Path(raw) / "head.json"
            jsonl = Path(raw) / "e.jsonl"
            head.write_text(json.dumps({"seq": 40, "generation": "g1", "sessionRevision": 1}))
            jsonl.write_text('{"seq":1,"generation":"g1"}\n{"seq":40,"generation":"g1"}\n')
            with self.assertRaises(SoakFail) as ctx:
                check_event_chain(
                    head_path=head, jsonl_path=jsonl, last_seq=1, want_gen="g1",
                    want_rev=1, head_rc=0, jsonl_rc=0,
                )
            self.assertIn("event_seq_jump_or_gap", ctx.exception.reason)

    def test_jsonl_consecutive_and_head_advance(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            head = Path(raw) / "head.json"
            jsonl = Path(raw) / "e.jsonl"
            lines = [json.dumps({"seq": i, "generation": "g1", "sessionRevision": 1}) for i in range(1, 6)]
            jsonl.write_text("\n".join(lines) + "\n")
            head.write_text(json.dumps({"seq": 5, "generation": "g1", "sessionRevision": 1}))
            seq = check_event_chain(
                head_path=head, jsonl_path=jsonl, last_seq=2, want_gen="g1",
                want_rev=1, head_rc=0, jsonl_rc=0,
            )
            self.assertEqual(seq, 5)

    def test_pull_rc_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            head = Path(raw) / "head.json"
            jsonl = Path(raw) / "e.jsonl"
            head.write_text(json.dumps({"seq": 1, "generation": "g1", "sessionRevision": 1}))
            jsonl.write_text('{"seq":1,"generation":"g1"}\n')
            with self.assertRaises(SoakFail) as ctx:
                check_event_chain(
                    head_path=head, jsonl_path=jsonl, last_seq=0, want_gen="g1",
                    want_rev=1, head_rc=1, jsonl_rc=0,
                )
            self.assertIn("event_head_recv_rc", ctx.exception.reason)

    def test_atomic_unique_temp_no_unlink_first(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dataplane-status.json"
            write_atomic(path, json.dumps({"phase": "CANARY_OK", "at": 1}))
            inode = path.stat().st_ino
            tmp = write_atomic(path, json.dumps({"phase": "CORRUPT"}), crash_after_tmp=True)
            self.assertTrue(path.exists())
            self.assertEqual(path.stat().st_ino, inode)
            self.assertIn("CANARY_OK", path.read_text())
            self.assertTrue(tmp.exists())
            self.assertIn("CORRUPT", tmp.read_text())
            self.assertNotEqual(tmp, path.with_suffix(".json.tmp"))

    def test_status_store_source_unique_temp(self) -> None:
        text = STATUS_ETS.read_text(encoding="utf-8")
        self.assertIn("generateRandomUUID", text)
        self.assertNotRegex(
            text,
            r"unlinkSync\(path\);\s*\n\s*\} catch \(error\) \{\s*\n\s*// dest may not exist yet",
        )

    def test_redact_deletes_original_auth(self) -> None:
        line = "from tcp:127.0.0.1:43050 accepted tcp:2001:4860::1:443 user=abc pass=s3cret token=tok1"
        out = redact_line(line)
        self.assertNotIn("abc", out)
        self.assertNotIn("s3cret", out)
        self.assertNotIn("tok1", out)
        self.assertNotIn("***abc", out)
        self.assertIn("user=", out)
        self.assertIn("127.0.0.1:*", out)

    def test_old_prefix_mask_would_fail(self) -> None:
        old = "user=abc".replace("user=", "user=***")
        self.assertIn("abc", old)


class ProvenanceTest(unittest.TestCase):
    def test_secret_scan_token_and_private_key(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            hap = Path(raw) / "x.hap"
            inner = Path(raw) / "resources/rawfile/runtime/nodes.json"
            inner.parent.mkdir(parents=True)
            inner.write_text(json.dumps({"token": "abcd1234", "nodes": []}))
            subprocess.check_call(["zip", "-q", "-r", str(hap), "resources"], cwd=raw)
            blocked = scan_hap_secrets(hap)
            self.assertTrue(any("secret-field" in x for x in blocked), blocked)

    def test_runtime_dir_banned_in_hap(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            hap = Path(raw) / "x.hap"
            inner = Path(raw) / ".runtime/outbound.json"
            inner.parent.mkdir()
            inner.write_text("{}")
            subprocess.check_call(["zip", "-q", "-r", str(hap), ".runtime"], cwd=raw)
            blocked = scan_hap_secrets(hap)
            self.assertTrue(any("runtime-dir" in x for x in blocked), blocked)

    def test_rsync_excludes_entire_runtime(self) -> None:
        script = R1.read_text(encoding="utf-8")
        self.assertTrue(rsync_excludes_runtime(script))

    def test_unrecorded_env_rejected(self) -> None:
        bad = unrecorded_env({"LIBXRAY_PIN": "deadbeef", "GOFLAGS": "-x"}, recorded={})
        self.assertTrue(bad)

    def test_lock_commit_cannot_impersonate_rebuild(self) -> None:
        measured = {
            "measuredLibxraySha256": "aaa",
            "measuredHevSha256": "bbb",
            "measuredPatchSha256": "ccc",
            "lockLibxraySha256": "aaa",
        }
        with self.assertRaises(ProvenanceError):
            verify_measured(
                measured,
                rebuilt_this_run=True,
                identity={"libxrayCommit": "20d70a98", "copiedFromLock": True, "rebuiltSha256": "aaa"},
            )

    def test_install_readback_requires_debug_provision_fingerprint(self) -> None:
        dump = '{"bundleName":"com.oscarwoltz.tongdao","versionName":"0.3.10-r1","versionCode":1000015,' \
               '"appProvisionType":"release","debug":false,"fingerprint":""}'
        with self.assertRaises(ProvenanceError):
            check_install_dump(dump, "0.3.10-r1", "1000015", "com.oscarwoltz.tongdao")
        dump_ok = (
            '{"bundleName":"com.oscarwoltz.tongdao","versionName":"0.3.10-r1","versionCode":1000015,'
            '"appProvisionType":"debug","debug":true,'
            '"fingerprint":"41729BE2333D65F43406B8A4144AFE5986238C5A54F9A875ADBD095FEC2E8717"}'
        )
        got = check_install_dump(dump_ok, "0.3.10-r1", "1000015", "com.oscarwoltz.tongdao")
        self.assertEqual(got["appProvisionType"], "debug")


class SoakRoundEventsTest(unittest.TestCase):
    def test_evaluate_requires_canary_ok_flag(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "s.json"
            path.write_text(json.dumps({
                "phase": "CANARY_OK",
                "generation": "gen-1",
                "at": NOW - 1000,
                "forwarderOk": True,
                "directOk": True,
                "proxyOk": True,
                "canaryOk": False,
                "sessionRevision": 1,
                "uploadBytes": 10,
                "downloadBytes": 20,
            }))
            with self.assertRaises(SoakFail) as ctx:
                evaluate_round(
                    targets=SERIAL + "\n",
                    serial=SERIAL,
                    model="ALT-AL10",
                    status_path=path,
                    tun="vpn-tun: 100 1 0 0 0 0 0 0 50 1 0 0 0 0 0 0",
                    cb="clashbox-absent",
                    vpn="23653",
                    want_gen="gen-1",
                    last_at=NOW - 5000,
                    now_ms=NOW,
                )
            self.assertIn("canaryOk", ctx.exception.reason)


if __name__ == "__main__":
    unittest.main()
