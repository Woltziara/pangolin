import assert from 'node:assert/strict';
import { uiMethods } from './helpers/ui-methods.mjs';

const page = uiMethods('Index', 'Index', [
  'narrow', 'medium', 'triple', 'landscape', 'combined', 'panelVisible',
  'panelSpan', 'panelHeight', 'horizontalControl',
], {});
Object.assign(page, { foldable: true, foldStatus: 1, activeTab: 0, mainWindow: null,
  connectionContentHeight: 350 });

Object.assign(page, { viewWidth: 350, viewHeight: 776 });
assert.equal(page.narrow(), true);
assert.equal(page.triple(), false);
assert.deepEqual([0, 1, 2].map(i => page.panelSpan(i)), [24, 0, 0]);
assert.equal(page.horizontalControl(), false);

Object.assign(page, { viewWidth: 712, viewHeight: 776 });
assert.equal(page.medium(), true);
assert.equal(page.triple(), false);
assert.deepEqual([0, 1, 2].map(i => page.panelSpan(i)), [10, 14, 0]);
assert.equal(page.panelHeight(0), 776);
assert.equal(page.panelHeight(1), 776);
assert.equal(page.horizontalControl(), false, 'two-pane connection must use its own scrollable compact layout');
page.activeTab = 2;
assert.deepEqual([0, 1, 2].map(i => page.panelSpan(i)), [0, 0, 24]);

Object.assign(page, { viewWidth: 1107, viewHeight: 776, activeTab: 0, foldStatus: 11 });
assert.equal(page.triple(), true);
assert.deepEqual([0, 1, 2].map(i => page.panelSpan(i)), [7, 9, 8]);
assert.deepEqual([0, 1, 2].map(i => page.panelHeight(i)), [776, 776, 776]);
assert.equal(page.horizontalControl(), false);
page.foldStatus = 1;
assert.equal(page.triple(), true, 'window breakpoint, not a transient fold enum, owns the three-pane layout');
page.foldable = false;
assert.equal(page.triple(), false, 'a non-foldable wide window is not forced into XTs triple mode');

console.log('PASS Mate XTs 350/712/1107 vp F/M/G panes, scroll heights and breakpoint ownership');
