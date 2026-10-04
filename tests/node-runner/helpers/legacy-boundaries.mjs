import {makeLoader} from './ets-loader.mjs';
const actual=makeLoader();
// Old regression subjects retain explicit boundaries for new collaborators.
// The gpt-* suites exercise these new production modules without these stubs.
let uuid=0;
export function legacyBoundary(name) {
 if(name.endsWith('/BuildIdentity')) return {BuildIdentity:{source:()=>''}};
 if(name.endsWith('/CoreInfo')) return actual('core/CoreInfo.ets');
 if(name.endsWith('/TunnelNative')) return {systemBootId:()=>'',monotonicMillis:()=>0};
 if(name==='@kit.ArkTS') return {util:{generateRandomUUID:()=>`legacy-${++uuid}`}};
 if(name.endsWith('/LifecycleGate')) return actual('services/LifecycleGate.ets');
 if(name.endsWith('/ProbeResult')) return actual('net/ProbeResult.ets');
 // Isolated legacy decision subjects don't exercise the ledger. Full controller fixtures do.
 if(name.endsWith('/PlatformOperations')) return {PLATFORM_OPERATIONS_FILE:'platform-operations-v2.json',PlatformOperations:class {
   instance='legacy'; unresolvedStop(){return false;} inFlight(){return 0;} async run(_c,_k,_g,work){return work();}
 }};
 if(name.endsWith('/Revocations')) return {Revocations:{keys:()=>[],revision:()=>0,revoke(){}}};
 if (name.endsWith('/AsyncDeadline')) return actual('services/AsyncDeadline.ets');
 if (name.endsWith('/LayerEvidence')) return actual('net/LayerEvidence.ets');
 if (name.endsWith('/OwnerTerminal')) return actual('net/OwnerTerminal.ets');
 if (name.endsWith('/RunningSnapshot')) return {RunningSnapshot:{assertAuthorized(){},async record(){},async read(){throw Error('snapshot not supplied in legacy fixture');}}};
 if (name.endsWith('/OwnerExitRecovery')) return {OwnerExitRecovery:{async recover(){throw Error('owner-exit recovery is covered by its production fixture');}}};
 if (name.endsWith('/AppRouteCapability')) return {AppRouteCapability:{async current(){},async check(){},async forConfig(){},async forPayload(){}}};
 if (name.endsWith('/BackgroundProbeHost')) return {BACKGROUND_PROBE_HOST:{start(){},stop(){}}};
 return undefined;
}
