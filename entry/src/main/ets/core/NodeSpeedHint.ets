export class NodeSpeedEntry {
  id: string = '';
  label: string = '';
  milliseconds: number = -1;
}
export class NodeSpeedView {
  current: string = '当前节点待测';
  tip: string = '';
  recommendedId: string = '';
}

/** Compare only samples supplied from this run, never cached catalog latencies. */
export function nodeSpeedHint(selectedId: string, region: string, samples: NodeSpeedEntry[],
  complete: boolean, outcome: string): NodeSpeedView {
  const result = new NodeSpeedView();
  const selected = samples.find((sample: NodeSpeedEntry) => sample.id === selectedId);
  if (selected !== undefined) {
    result.current = Number.isFinite(selected.milliseconds) && selected.milliseconds >= 0 ?
      `TCP 可达 · ${selected.milliseconds} ms` : '本轮 TCP 未连通';
  }
  if (!complete) { result.tip = `正在比较${region || '当前'}节点…`; return result; }
  if (outcome !== 'measured') {
    result.current = '测试未完成，请重测';
    result.tip = '连接状态或测试任务已变化，本轮不推荐节点。';
    return result;
  }
  if (selected === undefined) { result.current = '当前节点未取得结果，请重测'; return result; }
  const reachable = samples.filter((sample: NodeSpeedEntry) => Number.isFinite(sample.milliseconds) && sample.milliseconds >= 0);
  if (reachable.length === 0) { result.tip = '本轮没有测到可达节点，请稍后重试。'; return result; }
  result.tip = '这里只测节点端口。端口能连仍可能无法代理上网；请以当前线路的访问检测为准。';
  return result;
}
