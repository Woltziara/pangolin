// Generate credential-free UI states for the disposable Mate XTs emulator.
// Never send these records to a physical phone: they deliberately describe a
// synthetic owner and non-routable example.invalid nodes.
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const scenario = process.argv[2] || 'healthy';
const output = resolve(process.argv[3] || '.runtime/multiscreen/fixture');
if (!['healthy', 'connecting', 'failed', 'stuck'].includes(scenario)) {
  throw new Error(`unknown preview scenario: ${scenario}`);
}
mkdirSync(output, { recursive: true });
const at = Date.now();
const generation = 'visual-preview-generation';
const ownerInstance = 'visual-preview-owner';
const payloadDigest = 'visual-preview-policy';
const phase = scenario === 'healthy' ? 'FORWARDER_RUNNING' :
  scenario === 'connecting' ? 'STARTING' : scenario === 'failed' ? 'ERROR' : 'STOP_UNCONFIRMED';
const live = scenario === 'healthy' || scenario === 'stuck';
const desiredRunning = scenario !== 'failed';
const status = {
  phase, honestLabel: phase, generation, sessionId: generation, ownerInstance,
  sessionRevision: 1, networkEpoch: 1, payloadDigest, networkState: 'available',
  routeMode: 'rule', channelMode: 'single', desiredRunning,
  vpnCreated: live, tunFdValid: live, xrayRunning: live, forwarderOk: live,
  cleanupPending: false, nativePoisoned: false, nodeName: '美国 · 预览节点 US1',
  nodeRegion: '美国', at, downloadBytes: 1847296, uploadBytes: 594944,
  lastReachableAt: scenario === 'healthy' ? at : 0,
  healthCheckedAt: scenario === 'healthy' ? at : 0,
  healthLastOutcome: scenario === 'healthy' ? 'success' : '',
  healthGeneration: generation, healthRevision: 1, healthOwnerInstance: ownerInstance,
  healthNetworkEpoch: 1, healthPolicyDigest: payloadDigest,
};
const receipt = {
  schema: 2, rid: 'visual-preview-rid', generation, revision: 1, ownerInstance,
  networkEpoch: 1, policyDigest: payloadDigest, scope: 'pangolin-ui-path',
  source: 'entry-background', bundle: 'com.oscarwoltz.tongdao', at,
  googleHttp: 204, cloudflareHttp: 204, directHttp: 200, chatgptHttp: 403, dnsOk: true,
};
const nodes = Array.from({ length: 26 }, (_unused, i) => {
  const number = String(i + 1).padStart(2, '0');
  const server = `node${number}.preview.invalid`;
  return {
    id: `visual-node-${number}`, name: `美国 · 预览节点 US${number}`,
    region: '美国', server, port: 443, protocol: 'trojan',
    outbound: {
      protocol: 'trojan', settings: { servers: [{ address: server, port: 443, password: 'VISUAL_FIXTURE_ONLY' }] },
      streamSettings: { network: 'tcp', security: 'tls', tlsSettings: { serverName: server, allowInsecure: false } },
    },
    rawLink: '', sourceId: 'visual-preview', favorite: i === 0, group: '预览',
    customName: '', addedAt: at, updatedAt: at, latencyMs: i === 0 ? 144 : -1,
    latencyAt: i === 0 ? at : 0, latencyText: '',
  };
});
const traffic = {
  schema: 1, generation, ownerInstance, revision: 1, at,
  uploadBytes: 594944, downloadBytes: 1847296,
};
for (const [name, value] of Object.entries({
  'dataplane-status.json': status,
  'probe-fetch.json': receipt,
  'nodes.json': { v: 2, nodes },
  'traffic-sample.json': traffic,
})) {
  writeFileSync(resolve(output, name), JSON.stringify(value));
}
console.log(JSON.stringify({ scenario, at, output, nodes: nodes.length }));
