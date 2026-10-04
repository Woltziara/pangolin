/** Sprite choreography only. The caller supplies actual connection state. */
export class PangolinFrame {
  pose: string;
  duration: number;
  constructor(pose: string, duration: number) { this.pose = pose; this.duration = duration; }
}
export function pangolinFinalPose(state: string): string {
  if (state === 'connected') { return 'ready'; }
  if (state === 'attention') { return 'alert'; }
  if (state === 'connecting' || state === 'welcome') { return 'wait'; }
  return 'rest';
}
export function pangolinFrames(state: string, reduced: boolean = false): PangolinFrame[] {
  if (reduced) { return []; }
  if (state === 'connecting') {
    return [new PangolinFrame('rest', 100), new PangolinFrame('wake', 260),
      new PangolinFrame('walk_a', 150), new PangolinFrame('walk_b', 150),
      new PangolinFrame('walk_a', 150), new PangolinFrame('walk_b', 150), new PangolinFrame('wait', 180)];
  }
  if (state === 'connected') { return [new PangolinFrame('plant', 280), new PangolinFrame('ready', 240)]; }
  // Errors immediately use the concerned animal-paw pose, never a smiling intermediary.
  if (state === 'attention') { return []; }
  if (state === 'welcome') { return [new PangolinFrame('wake', 300), new PangolinFrame('wait', 260)]; }
  if (state === 'idle') { return [new PangolinFrame('wait', 100), new PangolinFrame('rest', 260)]; }
  return [];
}
export const PANGOLIN_SATURATION: number = 0.82;

/** Lifecycle only: failed web checks must not play a disconnected animal. */
export function pangolinState(established: boolean, phase: string, busy: boolean, error: boolean): string {
  if (error || phase === 'ERROR' || phase === 'POISONED') { return 'attention'; }
  if (established) { return 'connected'; }
  if (busy || phase === 'STARTING' || phase === 'VPN_CREATED' || phase === 'CORE_RUNNING' ||
    phase === 'FORWARDER_RUNNING' || phase === 'RECONNECTING') { return 'connecting'; }
  return 'idle';
}
