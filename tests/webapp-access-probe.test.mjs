import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createShareAuthorization, getSafeNetworkError, redactMountInfo } from '../scripts/webapp-access-probe.mjs';

test('signs the Azure Files share request with all required empty headers', () => {
  const key = Buffer.alloc(64, 1);
  const date = 'Mon, 01 Jul 2024 00:00:00 GMT';
  const canonical = 'GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:Mon, 01 Jul 2024 00:00:00 GMT\nx-ms-version:2023-11-03\n/testaccount/foundryvttdata\nrestype:share';
  const expected = createHmac('sha256', key).update(canonical).digest('base64');
  assert.equal(createShareAuthorization('testaccount', key.toString('base64'), date), `SharedKey testaccount:${expected}`);
  assert.throws(() => createShareAuthorization('testaccount', '@Microsoft.KeyVault(SecretUri=secret)', date), /not a resolved/);
});

test('reports only safe network codes, not error messages or unknown codes', () => {
  assert.equal(getSafeNetworkError({ code: 'ECONNREFUSED', message: 'private credential' }), 'ECONNREFUSED');
  assert.equal(getSafeNetworkError({ code: 'private credential', message: 'private credential' }), 'TransportError');
});

test('removes credentials without removing the CIFS source', () => {
  const source = '1 2 0:1 / /data rw,user=account,password=private,key=private,domain=private - cifs //testaccount.file.core.windows.net/foundryvttdata rw';
  const result = redactMountInfo(source);
  assert.doesNotMatch(result, /private|user=account/);
  assert.match(result, / - cifs \/\/testaccount\.file\.core\.windows\.net\/foundryvttdata/);
});
