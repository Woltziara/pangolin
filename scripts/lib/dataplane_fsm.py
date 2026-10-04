"""Host-side model of VPN session/revision/cancellation. Mirrors TunnelVpnAbility."""
from __future__ import annotations

import json
from dataclasses import dataclass, field

from lib.live_evidence import (
    PHASE_CANARY_OK,
    PHASE_DEGRADED_UNPROVEN,
    PHASE_UNPROVEN,
    PlaneSnapshot,
    advance_sample,
    has_fresh_plane_evidence,
    phase_from_evidence,
)

PHASE_IDLE = "IDLE"
PHASE_DEGRADED = "DEGRADED"
PHASE_RECONNECTING = "RECONNECTING"
PHASE_ERROR = "ERROR"
PHASE_STOPPED = "STOPPED"
PHASE_FORWARDER_RUNNING = "FORWARDER_RUNNING"

CORE_RESTART_LIMIT = 2
STOP_TIMEOUT_MS = 4000


def parse_status_blob(raw: str) -> str:
    if not raw or not str(raw).strip():
        return PHASE_ERROR
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return PHASE_ERROR
    if not isinstance(data, dict):
        return PHASE_ERROR
    phase = str(data.get("phase") or "")
    if not phase or (not data.get("phase") and data == {}):
        return PHASE_ERROR
    return phase


@dataclass
class Plane:
    generation: str = ""
    session_revision: int = 0
    phase: str = PHASE_IDLE
    cancelled: bool = False
    cleaning_up: bool = False
    recover_in_flight: bool = False
    start_in_flight: bool = False
    core_restarts: int = 0
    xray_running: bool = False
    tun_running: bool = False
    vpn_created: bool = False
    tun_fd_valid: bool = False
    last_error: str = ""
    writes: list[str] = field(default_factory=list)
    socks_port: int = 0
    tun_bytes: int = 0
    hev_bytes: int = 0
    tun_rx: int = 0
    tun_tx: int = 0
    hev_up: int = 0
    hev_down: int = 0
    last_tun: int = 0
    last_hev: int = 0
    last_tun_rx: int = 0
    last_tun_tx: int = 0
    last_hev_up: int = 0
    last_hev_down: int = 0
    bound_rid: str = ""
    access_proxy: bool = False
    access_direct: bool = False
    access_udp: bool = False
    evidence_at: int = 0
    ever_proven: bool = False
    socks_direct_ok: bool = False
    socks_proxy_ok: bool = False
    canary_ok: bool = False
    destroyed: bool = False
    protect_ok: bool = False
    direct_ok: bool = False
    proxy_ok: bool = False
    node_tcp_ok: bool = False
    tun_fd: int = -1
    create_in_flight: bool = False
    late_tun: int = -1
    now_ms: int = 0
    vpn_connection: object | None = "conn"
    dns_ok: bool = False
    tun_receiving: bool = False
    pending_start: str = ""
    native_poisoned: bool = False
    desired_running: bool = False
    command_epoch: int = 0
    start_flight_epoch: int = 0
    last_proven_rid: str = ""
    circuit_open: bool = False
    circuit_until: int = 0
    circuit_count: int = 0
    circuit_reason: str = ""
    destroy_bounded_ms: int = 4000
    status_write_ok: bool = True
    latest: dict | None = None
    committed_token: int = 0
    destroy_in_flight: bool = False
    breaker_file: str = ""

    def snapshot(self) -> PlaneSnapshot:
        return PlaneSnapshot(
            generation=self.generation,
            session_id=self.generation,
            session_revision=self.session_revision,
            tun_fd_valid=self.tun_fd_valid,
            xray_running=self.xray_running,
            tun_running=self.tun_running,
            tun_rx=self.tun_rx,
            tun_tx=self.tun_tx,
            hev_up=self.hev_up,
            hev_down=self.hev_down,
            last_tun_rx=self.last_tun_rx,
            last_tun_tx=self.last_tun_tx,
            last_hev_up=self.last_hev_up,
            last_hev_down=self.last_hev_down,
            bound_rid=self.bound_rid,
            access_offset=0 if self.bound_rid else -1,
            access_proxy=self.access_proxy,
            access_direct=self.access_direct,
            access_udp=self.access_udp,
            socks_direct_ok=self.socks_direct_ok,
            socks_proxy_ok=self.socks_proxy_ok,
            evidence_at=self.evidence_at,
            now_ms=self.now_ms,
            ever_proven=self.ever_proven,
        )

    def publish(self, label: str, force: bool = False) -> None:
        if self.cancelled and not self.cleaning_up and not force:
            self.writes.append(f"drop-stale:{label}")
            return
        self.writes.append(label)

    def force_publish(self, label: str) -> None:
        self.publish(label, force=True)

    def emit(self, label: str) -> None:
        if self.cancelled and not self.cleaning_up:
            self.writes.append(f"drop-stale-emit:{label}")
            return
        self.writes.append(f"emit:{label}")

    def guard(self, gen: str, rev: int, socks_port: int) -> bool:
        if self.cancelled or self.cleaning_up:
            return False
        if self.generation != gen or self.session_revision != rev:
            return False
        if self.socks_port != socks_port:
            return False
        return True

    def start(self, generation: str, socks_port: int = 18082, token: int | None = None) -> None:
        captured = token if token is not None else self.command_epoch
        if token is not None and token > self.command_epoch:
            self.command_epoch = token
        if self.breaker_blocks():
            self.park_stop(generation)
            self.phase = PHASE_ERROR
            self.last_error = "circuit-open"
            self.writes.append("circuit-block")
            return
        if self.start_in_flight or (self.vpn_created and not self.cancelled and self.generation == generation):
            self.writes.append("drop-duplicate-start")
            return
        self.start_in_flight = True
        self.start_flight_epoch = captured
        self.desired_running = True
        self.cancelled = False
        self.cleaning_up = False
        self.destroyed = False
        self.generation = generation
        self.session_revision = 1
        self.core_restarts = 0
        self.xray_running = True
        self.tun_running = True
        self.vpn_created = True
        self.tun_fd_valid = True
        self.tun_fd = 7
        self.protect_ok = True
        self.socks_port = socks_port
        self.tun_bytes = 0
        self.hev_bytes = 0
        self.last_tun = 0
        self.last_hev = 0
        self.evidence_at = 0
        self.ever_proven = False
        self.canary_ok = False
        self.direct_ok = False
        self.proxy_ok = False
        self.node_tcp_ok = False
        self.phase = PHASE_FORWARDER_RUNNING
        self.publish("start")
        if self.start_flight_epoch == captured:
            self.start_in_flight = False
            self.dispatch_latest()

    def fail_start_catch(self, captured_token: int) -> None:
        latest = self.latest
        if latest is not None and int(latest.get("token") or 0) != captured_token:
            self.writes.append(f"stale-catch-latest:{latest.get('token')}")
            return
        self.park_stop(self.generation)
        self.teardown(True, True, True)

    def enqueue(self, kind: str, generation: str) -> str:
        self.command_epoch += 1
        self.latest = {"token": self.command_epoch, "kind": kind, "generation": generation}
        return self.dispatch_latest()

    def dispatch_latest(self) -> str:
        cmd = self.latest
        if not cmd:
            return "none"
        if self.start_in_flight or self.cleaning_up or self.recover_in_flight or self.destroy_in_flight:
            self.writes.append("queue start until in-flight command finishes")
            return "held"
        return self.commit(cmd)

    def commit(self, cmd: dict) -> str:
        if not self.latest or self.latest.get("token") != cmd.get("token"):
            return "superseded"
        self.committed_token = int(cmd["token"])
        if cmd["kind"] == "stop":
            if cmd.get("generation") and self.generation and cmd["generation"] != self.generation:
                self.writes.append("stop-ignored-gen")
                return "ignored"
            already = (
                not self.vpn_created
                and self.tun_fd < 0
                and self.phase in (PHASE_STOPPED, PHASE_ERROR)
                and not self.xray_running
            )
            self.desired_running = False
            self.pending_start = ""
            if already:
                self.writes.append("stop-already-applied")
                return "already-stopped"
            self.teardown(True, True, True)
            return "stop"
        self.desired_running = True
        if self.vpn_created and self.tun_fd >= 0 and self.generation == cmd["generation"]:
            self.writes.append("onRequest-ignore-duplicate-start")
            return "ignore"
        if self.vpn_created and self.tun_fd >= 0 and self.generation != cmd["generation"]:
            self.pending_start = cmd["generation"]
            self.writes.append("switch-session")
            self.teardown(True, True, True)
            return "switch"
        self.start(cmd["generation"], token=int(cmd["token"]))
        return "started"

    def park_stop(self, generation: str) -> None:
        self.command_epoch += 1
        self.latest = {"token": self.command_epoch, "kind": "stop", "generation": generation}
        self.desired_running = False
        self.pending_start = ""

    def breaker_blocks(self) -> bool:
        if self.breaker_file == "corrupt" or self.breaker_file == "{}":
            return True
        if self.circuit_open and self.now_ms < self.circuit_until:
            return True
        return False

    def request_start(self, generation: str) -> str:
        return self.enqueue("start", generation)

    def request_stop(self, generation: str = "") -> str:
        return self.enqueue("stop", generation or self.generation)

    def bind_probe(self, rid: str) -> None:
        self.bound_rid = rid
        self.last_tun_rx = self.tun_rx
        self.last_tun_tx = self.tun_tx
        self.last_hev_up = self.hev_up
        self.last_hev_down = self.hev_down
        self.access_proxy = True
        self.access_direct = True
        self.access_udp = True

    def grow(self, tun: int = 1, hev: int = 1) -> None:
        self.tun_rx += tun
        self.tun_tx += tun
        self.hev_up += hev
        self.hev_down += hev
        self.tun_bytes = self.tun_rx + self.tun_tx
        self.hev_bytes = self.hev_up + self.hev_down
        self.apply_live()

    def grow_unidirectional(self, tun: int = 8, hev: int = 8) -> None:
        self.tun_rx += tun
        self.hev_up += hev
        self.apply_live()

    def tick_frozen(self) -> None:
        self.apply_live()

    def apply_live(self) -> None:
        snap = self.snapshot()
        fresh = has_fresh_plane_evidence(snap)
        self.canary_ok = fresh
        self.phase = phase_from_evidence(snap, self.phase)
        if fresh:
            advance_sample(snap, now_ms=self.now_ms)
            self.last_tun_rx = snap.last_tun_rx
            self.last_tun_tx = snap.last_tun_tx
            self.last_hev_up = snap.last_hev_up
            self.last_hev_down = snap.last_hev_down
            self.ever_proven = True
            self.evidence_at = snap.evidence_at or self.now_ms
            self.core_restarts = 0

    def socks_canary(self, direct_ok: bool = True, proxy_ok: bool = True) -> None:
        if self.cancelled:
            self.publish("canary-ignored")
            return
        self.socks_direct_ok = direct_ok
        self.socks_proxy_ok = proxy_ok
        self.direct_ok = direct_ok
        self.proxy_ok = proxy_ok
        self.apply_live()
        self.publish("socks-diag")

    def mark_canary_diag(self) -> None:
        self.socks_canary(True, True)

    def stale_recover(self, gen: str, rev: int) -> bool:
        return self.cancelled or self.cleaning_up or self.generation != gen or self.session_revision != rev

    def recover(
        self,
        stop_ok: bool = True,
        hev_stop_ok: bool | None = None,
        xray_stop_ok: bool | None = None,
        huks_ok: bool = True,
        already_running: bool = False,
        config_error: bool = False,
        stop_timeout: bool = False,
    ) -> str:
        if self.cancelled or self.cleaning_up or self.recover_in_flight:
            return "skip"
        hev_ok = stop_ok if hev_stop_ok is None else hev_stop_ok
        xray_ok = stop_ok if xray_stop_ok is None else xray_stop_ok
        idle_unproven = self.phase in (PHASE_UNPROVEN, PHASE_DEGRADED_UNPROVEN)
        if (
            idle_unproven
            and self.xray_running
            and self.tun_running
            and hev_ok
            and xray_ok
            and not already_running
            and not stop_timeout
            and not config_error
        ):
            return "skip-idle-no-restart"
        self.recover_in_flight = True
        gen = self.generation
        rev = self.session_revision
        socks = self.socks_port
        try:
            self.phase = PHASE_RECONNECTING
            self.canary_ok = False
            self.publish("recover-begin")
            if self.core_restarts >= CORE_RESTART_LIMIT:
                self.phase = PHASE_ERROR
                self.last_error = "recover-limit"
                self.publish("recover-limit")
                self.trip_circuit("recover-limit")
                self.park_stop(gen)
                self._destroy_tun("recover-limit")
                return "limit"
            self.core_restarts += 1
            if stop_timeout or not hev_ok or not xray_ok:
                self.last_error = "stop-timeout" if stop_timeout else "stop-failed"
                self._destroy_tun(self.last_error)
                return "cleanup"
            if self.stale_recover(gen, rev) or self.socks_port != socks:
                self.publish("recover-cancelled")
                if self.generation == gen:
                    self._destroy_tun("stale")
                else:
                    self.writes.append(f"stale-recover-ignored-new-gen:{self.generation}")
                return "cancelled"
            if not huks_ok or config_error:
                self.last_error = "huks-or-config"
                self._destroy_tun("huks-or-config")
                return "cleanup"
            if already_running:
                self.last_error = "already-running-mismatch"
                self._destroy_tun("already-running")
                return "cleanup"
            self.socks_port = socks + 1
            self.session_revision += 1
            self.last_tun = self.tun_bytes
            self.last_hev = self.hev_bytes
            self.ever_proven = False
            self.evidence_at = 0
            self.phase = PHASE_FORWARDER_RUNNING
            self.publish("recover-end")
            return "ok"
        except Exception as exc:  # noqa: BLE001
            self.last_error = str(exc)
            self._destroy_tun("recover-exception")
            return "cleanup"
        finally:
            self.recover_in_flight = False
            self.dispatch_latest()

    def finish_create(
        self,
        gen: str,
        fd: int = 9,
        conn_handle: object | None = "conn",
        destroy_ok: bool = True,
    ) -> str:
        self.create_in_flight = False
        local = conn_handle
        if fd < 0:
            self.tun_fd = -1
            self.tun_fd_valid = False
            self.vpn_created = False
            self.phase = PHASE_ERROR
            self.last_error = "create-fd-invalid"
            self.writes.append("create-fd-invalid")
            self._destroy_tun("create-fd-invalid")
            return "create-fd-invalid"
        if self.cancelled or self.cleaning_up or self.generation != gen:
            self.late_tun = fd
            self.vpn_connection = None
            if not destroy_ok:
                self.phase = PHASE_ERROR
                self.last_error = "orphan-destroy-failed"
                self.force_publish("orphan-destroy-failed")
                return "orphan-destroy-failed"
            if local is not None:
                self.writes.append("orphan-tun-destroyed-local-handle")
            self._destroy_tun("late-create")
            return "orphan-destroyed"
        self.tun_fd = fd
        self.tun_fd_valid = True
        self.vpn_created = True
        return "ok"

    def _reset_plane_truth(self) -> None:
        self.tun_fd = -1
        self.tun_fd_valid = False
        self.vpn_created = False
        self.protect_ok = False
        self.direct_ok = False
        self.proxy_ok = False
        self.node_tcp_ok = False
        self.canary_ok = False
        self.socks_direct_ok = False
        self.socks_proxy_ok = False
        self.socks_port = 0
        self.ever_proven = False
        self.evidence_at = 0
        self.dns_ok = False
        self.tun_receiving = False
        self.bound_rid = ""

    def _destroy_tun(self, reason: str) -> None:
        self.vpn_created = False
        self.tun_fd_valid = False
        self.tun_running = False
        self.xray_running = False
        self.destroyed = True
        self._reset_plane_truth()
        self.phase = PHASE_ERROR
        self.publish(f"cleanup:{reason}")

    def supervise(self) -> str:
        if self.cancelled or self.cleaning_up:
            return "skip"
        if not self.xray_running or not self.tun_running:
            return self.recover()
        self.apply_live()
        self.publish("supervise")
        return "ok"

    def net_lost(self) -> None:
        if self.cancelled or self.cleaning_up:
            return
        self.phase = PHASE_DEGRADED
        self.publish("net-lost")

    def net_available(self) -> str:
        if self.cancelled or self.cleaning_up:
            return "skip"
        self.publish("net-available")
        if self.phase == PHASE_DEGRADED:
            return self.recover()
        return "noop"

    def async_stale_write(self, old_gen: str, label: str) -> None:
        if old_gen != self.generation or self.cancelled:
            self.writes.append(f"drop-stale:{label}")
            return
        self.publish(label)

    def after_await(self, gen: str, rev: int, socks_port: int, label: str) -> bool:
        if not self.guard(gen, rev, socks_port):
            self.writes.append(f"stale-after-await:{label}")
            self._destroy_tun(f"stale-await-{label}")
            return False
        self.publish(f"await-ok:{label}")
        return True

    def wait_phase(self, started_gen: str, observed_gen: str, phase: str, timeout: bool) -> str:
        if timeout and observed_gen != started_gen:
            return "timeout-mismatch"
        if timeout and phase != PHASE_CANARY_OK:
            return "timeout-unproven"
        if observed_gen != started_gen:
            return "skip-old-generation"
        return phase

    def teardown(self, stop_xray_ok: bool, stop_hev_ok: bool, destroy_ok: bool, stop_timeout: bool = False) -> None:
        self.cleaning_up = True
        self.cancelled = True
        stop_failed = not (stop_xray_ok and stop_hev_ok) or stop_timeout
        destroy_failed = not destroy_ok
        self.xray_running = False
        self.tun_running = False
        self._reset_plane_truth()
        self.destroyed = True
        if stop_failed or destroy_failed:
            self.phase = PHASE_ERROR
            self.last_error = "teardown-failed"
            self.publish("teardown-error")
        else:
            self.phase = PHASE_STOPPED
            self.publish("teardown-stopped")
        self.cleaning_up = False
        if destroy_failed:
            self.destroy_in_flight = True
            self.desired_running = False
            self.park_stop(self.generation)
            self.writes.append("destroy-timeout-no-restart")
            return
        self.dispatch_latest()

    def on_destroy(self) -> None:
        self.enqueue("stop", self.generation)

    def trip_circuit(self, reason: str) -> None:
        self.circuit_count += 1
        self.circuit_open = True
        self.circuit_reason = reason
        self.circuit_until = self.now_ms + 300_000 * max(1, self.circuit_count)
        self.writes.append(f"circuit-open:{reason}")

    def write_status(self, label: str) -> None:
        if not self.status_write_ok:
            self.phase = PHASE_ERROR
            self.canary_ok = False
            self.last_error = "status-write-failed"
            self.writes.append(f"status-write-fail-closed:{label}")
            return
        self.publish(label)
