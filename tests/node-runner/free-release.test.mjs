import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const root = new URL('../../entry/src/main/', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
for (const path of ['ets/core/CommerceFlow.ets', 'ets/core/AdvancedAccess.ets', 'ets/core/EditionCapability.ets',
  'ets/core/EditionId.ets', 'ets/pages/Purchase.ets', 'ets/commerce/CommerceRuntime.ets', 'ets/commerce/HuaweiPurchases.ets']) {
  assert.equal(existsSync(new URL(path, root)), false, path + ' was removed');
}
const pages = JSON.parse(read('resources/base/profile/main_pages.json')).src;
assert(!pages.includes('pages/Purchase'));
for (const path of ['ets/services/ConnectionPolicy.ets', 'ets/services/SplitRouter.ets', 'ets/services/AppliedPolicy.ets', 'ets/vpn/TunnelVpnAbility.ets']) {
  const source = read(path);
  assert(!/Commerce|Edition|Purchase/i.test(source), path + ' has no commercial dependency');
}
assert(read('ets/pages/Index.ets').includes("Text('连接通道')"));
assert(!read('ets/pages/Rules.ets').includes('以前保存的指定节点组规则保留但暂停'));
console.log('PASS self-use release: commercial runtime and routing are absent; configured advanced capabilities remain local');
