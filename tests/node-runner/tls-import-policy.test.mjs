import assert from 'node:assert/strict';
import {requireCertificateVerification,outboundRunError} from './build/OutboundReady.js';
const node={protocol:'trojan',settings:{servers:[{address:'node.example.com',port:443,password:'fixture-only'}]},
 streamSettings:{security:'tls',tlsSettings:{serverName:'node.example.com',allowInsecure:true}}};
const raw=JSON.stringify(node);
assert.match(outboundRunError(raw),/拒绝关闭证书校验/);
const strict=requireCertificateVerification(raw),parsed=JSON.parse(strict);
assert.equal(parsed.streamSettings.tlsSettings.allowInsecure,false);
assert.deepEqual(parsed.settings,node.settings);
assert.equal(parsed.streamSettings.tlsSettings.serverName,node.streamSettings.tlsSettings.serverName);
assert.equal(outboundRunError(strict),'');assert.equal(node.streamSettings.tlsSettings.allowInsecure,true);
assert.equal(requireCertificateVerification(strict),strict);
const noTls={...node,streamSettings:{security:'none'}};
assert.match(outboundRunError(requireCertificateVerification(JSON.stringify(noTls))),/需要 TLS/);
const invalidName=JSON.parse(raw);invalidName.streamSettings.tlsSettings.serverName='203.0.113.1';
assert.match(outboundRunError(requireCertificateVerification(JSON.stringify(invalidName))),/SNI/);
console.log('PASS execution copy strengthens TLS policy without rewriting server/SNI or source data; unsafe raw configs and missing TLS/SNI remain rejected');
