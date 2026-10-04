// Copies the PURE core .ets files (no @kit/@ohos imports) to .ts and compiles
// them with the local tsc so parser.test.mjs can run them under Node.
import { copyFileSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const coreDir = join(here, '../../entry/src/main/ets/core');
const srcDir = join(here, 'src');

const PURE_FILES = [
  'Encoding.ets',
  'IdnUrl.ets',
  'RegionGuess.ets',
  'ShareLinkParser.ets',
  'NodeDedupe.ets',
  'SubscriptionParser.ets',
  'UserRuleMap.ets',
  'OutboundReady.ets',
  'UserFacingCopy.ets',
  'ChannelPolicy.ets',
  'OutboundCommit.ets',
  'LineHealth.ets',
  'BackupSelection.ets',
  'AppRouteModel.ets',
  'AppRoutePayload.ets',
  'NodeSpeedHint.ets'
];

rmSync(srcDir, { recursive: true, force: true });
mkdirSync(srcDir, { recursive: true });
for (const file of PURE_FILES) {
  const source = join(coreDir, file);
  copyFileSync(source, join(srcDir, file.replace(/\.ets$/, '.ts')));
}

const tsc = join(here, 'node_modules', 'typescript', 'bin', 'tsc');
execFileSync(process.execPath, [tsc, '-p', join(here, 'tsconfig.json')], { stdio: 'inherit' });
console.log('node-runner build ok');
