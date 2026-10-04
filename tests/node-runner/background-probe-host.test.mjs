import assert from 'node:assert/strict';
import {makeLoader,flush} from './helpers/ets-loader.mjs';
let desiredRunning=false,starts=0,stops=0,forced=0,legacyStops=0;
const load=makeLoader({
 '@kit.AbilityKit':{},
 '@kit.BackgroundTasksKit':{backgroundTaskManager:{
  startBackgroundRunning(){throw Error('A quiet VPN must not create a UI continuous task');},
  async stopBackgroundRunning(){legacyStops++;}
 }},
 'services/StatusStore.ets':{StatusStore:{readStatus:()=>({desiredRunning})}},
 'services/ProbeSelfCheck.ets':{PROBE_SELF_CHECK:{setForeground(){},startLoop(){starts++;},stopLoop(){stops++;},async tick(_c,force){if(force)forced++;}}}
});
const {BackgroundProbeHost}=load('services/BackgroundProbeHost.ets');
const host=new BackgroundProbeHost(),ctx={};
host.start(ctx,'EntryAbility.onCreate');await flush();
assert.equal(starts,0,'opening a stopped app does not probe');assert.equal(legacyStops,1);
host.start(ctx,'Controller.startTunnel');assert.equal(starts,1);
desiredRunning=true;host.start(ctx,'EntryAbility.onForeground');assert.equal(starts,2);assert.equal(forced,1);
host.start(ctx,'EntryAbility.onBackground');assert.equal(stops,1);
host.start(ctx,'EntryAbility.onNewWant');host.start(ctx,'Controller.startTunnel');
assert.equal(starts,2,'background callbacks cannot restart UI-path requests');
host.start(ctx,'EntryAbility.onForeground');assert.equal(starts,3);assert.equal(forced,2);
assert.equal(legacyStops,1,'migration cleanup runs once and never requests a task');
host.stop(ctx,'disconnect');assert.equal(stops,2);
console.log('PASS quiet probe host: no ongoing-task notification, foreground checks, background cancellation, immediate return check');
