export function buildHevTunConfigYaml(mtu: number, socksHost: string, socksPort: number,
  socksUser: string, socksPass: string): string {
  const lines: string[] = [
    'tunnel:',
    `  mtu: ${mtu}`,
    "  ipv4: '10.7.0.1'",
    "  ipv6: 'fd00:7::1'",
    'socks5:',
    `  address: ${socksHost}`,
    `  port: ${socksPort}`,
    "  udp: 'udp'"
  ];
  if (socksUser.length > 0 && socksPass.length > 0) {
    lines.push(`  username: '${socksUser}'`);
    lines.push(`  password: '${socksPass}'`);
  }
  lines.push('misc:');
  lines.push('  log-level: warn');
  lines.push('  tcp-read-write-timeout: 300000');
  lines.push('  udp-read-write-timeout: 60000');
  lines.push('');
  return lines.join('\n');
}
