// Whitelist-only diagnostic export. Raw messages, addresses and unrelated
// destinations stay inside the application sandbox.
export function outboundTimingEvents(raw: string): Array<Record<string, Object>> {
  const events: Array<Record<string, Object>> = [];
  const allowed: string[] = [];
  const lines = raw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const header = line.match(/^(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?) \[Info\] \[(\d+)\]/);
    if (header === null) { continue; }
    let stage = '';
    let target = '';
    if (line.indexOf('transport/internet/tcp: dialing TCP to ') >= 0) {
      stage = 'node-dial-start';
    } else if (line.indexOf('proxy/trojan: tunneling request to ') >= 0) {
      const dest = line.match(/tunneling request to tcp:(www\.google\.com|chatgpt\.com):(80|443)(?:\s|$)/);
      if (dest === null) { continue; }
      target = dest[1] === 'chatgpt.com' ? 'chatgpt-https-head' :
        (dest[2] === '443' ? 'google-https' : 'google-http');
      stage = 'node-tls-ready';
      allowed.push(header[2]);
    } else { continue; }
    const event: Record<string, Object> = {};
    event['time'] = header[1];
    event['session'] = header[2];
    event['stage'] = stage;
    if (target.length > 0) { event['target'] = target; }
    events.push(event);
  }
  return events.filter((event: Record<string, Object>) => allowed.indexOf(event['session'] as string) >= 0);
}

// Temporary App diagnosis: metadata only; never export raw log messages,
// node addresses, URL paths, headers, credentials, or conversation content.
export function chatAppTimingEvents(raw: string): Array<Record<string, Object>> {
  const events: Array<Record<string, Object>> = [];
  const allowed: string[] = [];
  const lines = raw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const header = line.match(/^(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?) \[(Info|Warning|Error)\] \[(\d+)\]/);
    if (header === null) { continue; }
    const dest = line.match(/(?:tcp:|udp:|sniffed domain: )((?:[a-zA-Z0-9-]+\.)*(?:openai\.com|chatgpt\.com|oaistatic\.com|oaiusercontent\.com|auth0\.com|google\.com|googleapis\.com|gstatic\.com|googleusercontent\.com|statsigapi\.net|statsig\.com|featuregates\.org|cloudflare\.com))(?::(?:80|443))?(?=\s|\]|$)/);
    let stage = '';
    if (line.indexOf('dialing TCP to ') >= 0) { stage = 'node-dial-start'; }
    else if (line.indexOf('tunneling request to ') >= 0) { stage = 'node-tls-ready'; }
    else if (line.indexOf('sniffed domain: ') >= 0) { stage = 'domain-sniff'; }
    else if (line.indexOf('taking detour') >= 0 || line.indexOf('default route') >= 0) { stage = 'route'; }
    else if (/timeout|deadline exceeded/i.test(line)) { stage = 'timeout'; }
    else if (/failed|connection reset|connection refused|EOF/i.test(line)) { stage = 'connection-error'; }
    if (stage.length === 0) { continue; }
    const event: Record<string, Object> = {};
    event['time'] = header[1];
    event['session'] = header[3];
    event['stage'] = stage;
    if (dest !== null) {
      event['host'] = dest[1].toLowerCase();
      allowed.push(header[3]);
    }
    const route = line.match(/taking detour \[(proxy-yt|proxy|direct|block)\]/);
    if (stage === 'route' && route !== null) { event['route'] = route[1]; }
    events.push(event);
  }
  return events.filter((event: Record<string, Object>) => allowed.indexOf(event['session'] as string) >= 0).slice(-3000);
}
