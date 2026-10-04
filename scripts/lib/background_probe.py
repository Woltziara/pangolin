"""Host model of official VPN background keep-alive vs frozen UI timers.

Huawei: UI timers freeze after the UIAbility goes to background unless a
continuous DATA_TRANSFER task is running. TaskPool is not a substitute.
Keep-alive must start before waiting for the first CANARY so STARTING in
the background is not a deadlock.
"""
from __future__ import annotations


class BackgroundKeepAliveModel:
    def __init__(self) -> None:
        self.running = False
        self.system_present = False
        self.notification_id = -1
        self.continuous_task_id = -1
        self.progress = 0
        self.last_event = ""
        self.last_error = ""
        self.listening = False
        self.events: list[str] = []

    def start(self, *, ok: bool = True, live_view: bool = True, already_applied: bool = False) -> bool:
        self.listening = True
        if not ok and not already_applied:
            self.running = False
            self.system_present = False
            self.last_error = "startBackgroundRunning failed"
            self.last_event = "dead"
            return False
        self.running = True
        self.system_present = True
        self.notification_id = 7
        self.continuous_task_id = 11
        self.progress = 1
        self.last_event = "start"
        self.last_error = "" if live_view else "LIVE_VIEW optional publish failed"
        return True

    def touch(self, *, ok: bool = True, system_present: bool = True, live_view: bool = True) -> bool:
        if not self.running:
            return False
        if not ok or not system_present or not live_view:
            self.running = False
            self.system_present = False
            self.last_error = "touch failed"
            self.last_event = "dead"
            return False
        self.progress += 1
        self.last_event = "progress"
        self.system_present = True
        return True

    def is_ok(self) -> bool:
        return self.running and self.system_present and self.last_event != "suspend" and self.notification_id >= 0

    def on_cancel(self) -> None:
        self.running = False
        self.system_present = False
        self.last_event = "cancel"
        self.events.append("cancel")

    def on_suspend(self) -> None:
        self.last_event = "suspend"
        self.events.append("suspend")

    def on_active(self) -> None:
        self.last_event = "active"
        self.events.append("active")

    def snapshot(self) -> dict[str, object]:
        return {
            "ok": self.is_ok(),
            "running": self.running,
            "systemPresent": self.system_present,
            "notificationId": self.notification_id,
            "continuousTaskId": self.continuous_task_id,
            "progress": self.progress,
            "lastEvent": self.last_event,
            "error": self.last_error,
        }


class ProbeSelfCheckModel:
    def __init__(self) -> None:
        self.last_ok_rid = ""
        self.fail_count = 0
        self.next_retry_at = 0
        self.acks: list[dict[str, object]] = []
        self.now = 0

    def tick(self, rid: str, *, google_http: int, direct_http: int, dns_ok: bool) -> dict[str, object]:
        if self.now < self.next_retry_at:
            return {"skipped": True, "reason": "backoff"}
        if rid == self.last_ok_rid:
            return {"skipped": True, "reason": "last-ok-rid"}
        ack_ok = google_http == 204 and 200 <= direct_http < 400 and dns_ok
        rec = {
            "rid": rid,
            "googleHttp": google_http,
            "directHttp": direct_http,
            "dnsOk": dns_ok,
            "ackOk": ack_ok,
            "failAck": not ack_ok,
            "source": "entry-background",
        }
        self.acks.append(rec)
        if ack_ok:
            self.last_ok_rid = rid
            self.fail_count = 0
            self.next_retry_at = 0
        else:
            self.last_ok_rid = ""
            self.fail_count += 1
            wait = min(2000 * (2 ** (self.fail_count - 1)), 120000)
            self.next_retry_at = self.now + wait
        return rec


class BackgroundProbeModel:
    def __init__(self) -> None:
        self.index_timer = False
        self.entry_loop = False
        self.keep = BackgroundKeepAliveModel()
        self.probe = ProbeSelfCheckModel()
        self.acks: list[tuple[str, str]] = []
        self.last_error = ""
        self.phase = "IDLE"
        self.desired_running = False
        self.waiting_first_canary = False

    def index_appear(self) -> None:
        self.index_timer = True

    def index_disappear(self) -> None:
        self.index_timer = False

    def start_tunnel(self, *, keep_alive_ok: bool = True) -> str:
        self.desired_running = True
        self.phase = "STARTING"
        if not self.keep.start(ok=keep_alive_ok):
            self.last_error = self.keep.last_error
            self.entry_loop = False
            return "keep-alive-failed"
        self.entry_loop = True
        self.waiting_first_canary = True
        return "keep-alive-then-wait-canary"

    def on_background(self, *, keep_alive_ok: bool) -> None:
        self.index_timer = False
        if keep_alive_ok:
            if not self.keep.running:
                self.keep.start(ok=True)
            self.entry_loop = True
            self.last_error = ""
        else:
            self.keep.running = False
            self.keep.system_present = False
            self.entry_loop = False
            self.last_error = "startBackgroundRunning failed"

    def pulse(self, rid: str, *, google_http: int = 204, direct_http: int = 200, dns_ok: bool = True) -> None:
        if self.index_timer:
            self.acks.append(("index", rid))
        if self.entry_loop and self.keep.running and self.keep.system_present:
            rec = self.probe.tick(rid, google_http=google_http, direct_http=direct_http, dns_ok=dns_ok)
            if not rec.get("skipped") and self.keep.is_ok():
                self.acks.append(("entry-background", rid))

    def owners_for(self, rid: str) -> list[str]:
        return [owner for owner, got in self.acks if got == rid]
