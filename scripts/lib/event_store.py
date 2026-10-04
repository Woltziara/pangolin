"""Session-isolated event snapshot. One atomic JSON, crash-recoverable.

JSONL+head two-write is not used as the source of truth. A generation change
starts a new ledger instead of splicing into the previous session.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from lib.atomic_file import recover_canonical, write_atomic_ohos


class EventGap(Exception):
    pass


MAX_EVENTS = 400
REQUIRED_EVENT_FIELDS = ("seq", "kind", "generation", "sessionRevision", "at", "phase")


@dataclass
class EventSnapshot:
    generation: str = ""
    session_revision: int = 0
    seq: int = 0
    window_start_seq: int = 0
    events: list[dict] = field(default_factory=list)

    def append(self, kind: str, generation: str, revision: int) -> dict:
        if self.seq < 0:
            raise EventGap("event snapshot corrupt; refuse seq reuse")
        if self.generation and generation != self.generation:
            self.generation = generation
            self.session_revision = revision
            self.seq = 0
            self.window_start_seq = 0
            self.events = []
        if not self.generation:
            self.generation = generation
        if not generation or not self.generation:
            raise EventGap("event generation missing")
        if revision < 1:
            raise EventGap("event revision missing")
        at_now = 1
        if self.events:
            prev_at = int(self.events[-1].get("at") or 0)
            at_now = prev_at + 1
            if at_now < prev_at:
                raise EventGap("event at rewind")
        self.session_revision = revision
        self.seq += 1
        rec = {
            "seq": self.seq,
            "kind": kind,
            "generation": generation,
            "sessionRevision": revision,
            "at": at_now,
            "phase": kind,
        }
        self.events.append(rec)
        if len(self.events) > MAX_EVENTS:
            self.events = self.events[-MAX_EVENTS:]
        self.window_start_seq = int(self.events[0]["seq"])
        if int(self.events[-1]["seq"]) != self.seq:
            raise EventGap("event window seq discontinuity")
        if self.window_start_seq + len(self.events) - 1 != self.seq:
            raise EventGap("event rolling window gap")
        return rec

    def to_json(self) -> str:
        return json.dumps(
            {
                "generation": self.generation,
                "sessionRevision": self.session_revision,
                "seq": self.seq,
                "windowStartSeq": self.window_start_seq,
                "events": self.events,
            },
            ensure_ascii=False,
        )

    @classmethod
    def from_json(cls, raw: str) -> "EventSnapshot":
        if not raw or len(raw) < 8:
            return cls()
        try:
            doc = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise EventGap(f"snapshot_parse {exc}") from exc
        events = list(doc.get("events") or [])
        seq = int(doc.get("seq") or 0)
        if seq > 0 and not events:
            raise EventGap("empty events with seq")
        for rec in events:
            if not isinstance(rec, dict):
                raise EventGap("event not object")
            for field in REQUIRED_EVENT_FIELDS:
                if field not in rec:
                    raise EventGap(f"snapshot_event_missing_{field}")
        seqs = [int(e["seq"]) for e in events]
        if events and len(seqs) != len(events):
            raise EventGap("snapshot_event_missing_seq")
        for i in range(1, len(seqs)):
            if seqs[i] != seqs[i - 1] + 1:
                raise EventGap(f"snapshot_seq_gap {seqs[i - 1]} -> {seqs[i]}")
        window_start = int(doc.get("windowStartSeq") or 0)
        snap = cls(
            generation=str(doc.get("generation") or ""),
            session_revision=int(doc.get("sessionRevision") or 0),
            seq=seq,
            window_start_seq=window_start,
            events=events,
        )
        if snap.seq > 0 and not snap.generation:
            raise EventGap("seq without generation")
        if snap.seq and seqs and snap.seq != seqs[-1]:
            raise EventGap(f"snapshot_seq_mismatch head={snap.seq} last={seqs[-1]}")
        if seqs:
            if window_start != seqs[0]:
                raise EventGap(f"windowStartSeq {window_start} != first {seqs[0]}")
            if window_start + len(seqs) - 1 != seqs[-1]:
                raise EventGap("event rolling window gap")
        gens = {str(e.get("generation") or "") for e in events}
        gens.discard("")
        if len(gens) > 1:
            raise EventGap(f"snapshot_mixed_generation {gens}")
        if snap.generation and gens and gens != {snap.generation}:
            raise EventGap(f"snapshot_generation_mismatch {gens} != {snap.generation}")
        prev_rev = -1
        for i, rec in enumerate(events):
            want_seq = window_start + i
            if int(rec.get("seq") or 0) != want_seq:
                raise EventGap(f"window_seq_discontinuity want={want_seq}")
            rec_gen = str(rec.get("generation") or "")
            if snap.generation and rec_gen and rec_gen != snap.generation:
                raise EventGap(f"event_generation_mismatch {rec_gen}")
            rec_rev = int(rec.get("sessionRevision") or 0)
            if rec_rev < 1:
                raise EventGap("event_revision_missing")
            if int(rec.get("at") or 0) < 1:
                raise EventGap("event_at_missing")
            if not str(rec.get("phase") or ""):
                raise EventGap("event_phase_missing")
            if i > 0 and int(rec.get("seq") or 0) != int(events[i - 1]["seq"]) + 1:
                raise EventGap("event_seq_not_consecutive")
            if prev_rev >= 0 and rec_rev < prev_rev:
                raise EventGap(f"event_revision_rewind {prev_rev} -> {rec_rev}")
            prev_rev = rec_rev
        if events:
            snap.session_revision = int(events[-1]["sessionRevision"])
        return snap

    def save(self, path: Path) -> None:
        write_atomic_ohos(path, self.to_json())

    @classmethod
    def load(cls, path: Path) -> "EventSnapshot":
        path = Path(path)
        raw = recover_canonical(path)
        if not raw:
            if path.is_file() and path.stat().st_size >= 2:
                snap = cls()
                snap.seq = -1
                return snap
            return cls()
        try:
            return cls.from_json(raw)
        except EventGap:
            snap = cls()
            snap.seq = -1
            return snap


# Back-compat name used by older tests.
class EventLog(EventSnapshot):
    @property
    def lines(self) -> list[str]:
        return [json.dumps(e) for e in self.events]

    def consume_head(self, last_seq: int) -> int:
        if not self.events:
            return last_seq
        seq = int(self.events[-1]["seq"])
        if last_seq > 0 and seq <= last_seq:
            raise EventGap(f"rewind {seq} < {last_seq}")
        if last_seq > 0 and seq != last_seq + 1:
            raise EventGap(f"jump {last_seq} -> {seq}")
        return seq
