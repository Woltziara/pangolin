import assert from 'node:assert/strict';
import {uiMethods} from './helpers/ui-methods.mjs';
let now=1_800_000_000_000, source={id:'sub-original',lastUpdateAt:now-22*86400000,lastError:'https://secret.example/token-123'};
let applied={channelMode:'single',singleNodeId:'selected'};
const page=uiMethods('Index','Index',['currentSubscriptionHint'],{
  Date:{now:()=>now},
  AppliedPolicy:{current:()=>applied},
  SubscriptionStore:{findById:(_ctx,id)=>id===source.id?source:null}
});
page.configuredNodes=[{id:'selected',sourceId:'sub-original'}];page.repairFailed=false;
const issue=page.currentSubscriptionHint({}, {connectionHealth:'check-failed'});
assert.match(issue,/22 天未更新/);assert.match(issue,/上次更新失败/);assert(!issue.includes('token-123'));
assert.equal(page.currentSubscriptionHint({}, {connectionHealth:'reachable'}),'','healthy traffic is not interrupted for catalog age alone');
applied=null;assert.equal(page.currentSubscriptionHint({}, {connectionHealth:'check-failed'}),'','unattributed current owner cannot blame a saved subscription');
console.log('PASS active subscription failure is identified without showing URL credentials or alarming a healthy session');
