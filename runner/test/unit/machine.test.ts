import { test } from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import { DEFAULT_MAC_ICON, detectMachineIcon, iconForMachine } from '../../src/machine.ts';

test('a runner\'s icon is the kind of Mac it is on', () => {
  assert.equal(iconForMachine('MacBook Pro'), 'laptopcomputer');
  assert.equal(iconForMachine('MacBook Air'), 'laptopcomputer');
  assert.equal(iconForMachine('Mac mini'), 'macmini');
  assert.equal(iconForMachine('Mac Studio'), 'macstudio');
  assert.equal(iconForMachine('Mac Pro'), 'macpro.gen3');
  assert.equal(iconForMachine('iMac'), 'desktopcomputer');
  assert.equal(iconForMachine('Something new'), DEFAULT_MAC_ICON);
  assert.equal(iconForMachine(undefined), DEFAULT_MAC_ICON);
});

test('detecting it on this Mac gives one of the symbols', { skip: os.platform() !== 'darwin' }, async () => {
  assert.match(await detectMachineIcon(), /^(laptopcomputer|macmini|macstudio|macpro\.gen3|desktopcomputer)$/);
});
