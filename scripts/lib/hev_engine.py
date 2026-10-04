"""HEV start/stop TOCTOU model. already-running must not return ok=true."""
from __future__ import annotations

from dataclasses import dataclass


ENGINE_NONE = 0
ENGINE_HEV = 2


@dataclass
class HevEngine:
    running: bool = False
    thread_live: bool = False
    engine: int = ENGINE_NONE
    starting: bool = False
    life: int = 0
    main_rc: int = 0
    messages: list[str] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.messages is None:
            self.messages = []

    def start(self) -> tuple[bool, str]:
        if self.running or (self.thread_live and self.starting):
            return False, "tun data plane already running."
        self.thread_live = True
        self.starting = True
        self.engine = ENGINE_HEV
        self.starting = False
        self.running = True
        self.messages.append("started")
        return True, "hev tun engine started."

    def start_begin(self) -> int:
        if self.running or (self.thread_live and self.starting):
            raise RuntimeError("already running")
        self.life += 1
        life = self.life
        self.thread_live = True
        self.starting = True
        self.main_rc = -2
        self.engine = ENGINE_HEV
        return life

    def worker_exit(self, life: int) -> None:
        if self.life != life:
            return
        self.main_rc = 0
        self.running = False
        self.thread_live = False
        self.engine = ENGINE_NONE

    def start_commit(self, life: int | None = None) -> tuple[bool, str]:
        if life is not None and self.life != life:
            return False, "hev life epoch mismatch"
        if self.main_rc != -2 or not self.thread_live:
            self.running = False
            self.engine = ENGINE_NONE
            return False, "hev tun exited before running"
        self.starting = False
        self.running = True
        self.engine = ENGINE_HEV
        return True, "hev tun engine started."

    def stop(self) -> tuple[bool, str]:
        if not self.running and not self.thread_live:
            return True, "tun data plane already stopped."
        engine = self.engine
        if engine == ENGINE_HEV or (engine == ENGINE_NONE and self.thread_live):
            self.life += 1
            self.running = False
            self.thread_live = False
            self.starting = False
            self.engine = ENGINE_NONE
            self.messages.append("hev-stopped")
            return True, "hev tun stopped."
        self.running = False
        self.thread_live = False
        self.engine = ENGINE_NONE
        self.messages.append("other-stopped")
        return True, "tun2socks stopped."
