import { createHmac } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { readFileSync } from 'node:fs';
import { Socket } from 'node:net';

export function getSafeNetworkError(error) {
  const codes = new Set([
    'ENOTFOUND', 'EAI_AGAIN', 'ETIMEDOUT', 'ECONNREFUSED',
    'ECONNRESET', 'ENETUNREACH', 'EHOSTUNREACH'
  ]);
  const code = error?.code ?? error?.cause?.code;
  if (codes.has(code)) return code;
  if (error?.name === 'TimeoutError') return 'ETIMEDOUT';
  return 'TransportError';
}

export function redactMountInfo(value) {
  return value.replace(/(?:username|user|domain|password|pass|key|secret)=[^,\s]*/gi, '[redacted]');
}

export function createShareAuthorization(accountName, key, date) {
  if (typeof key !== 'string' || !/^[A-Za-z0-9+/]{86}==$/.test(key)) {
    throw new Error('The storage key is not a resolved account key.');
  }
  const toSign = [
    'GET', ...Array(11).fill(''),
    `x-ms-date:${date}\nx-ms-version:2023-11-03\n/${accountName}/foundryvttdata\nrestype:share`
  ].join('\n');
  const signature = createHmac('sha256', Buffer.from(key, 'base64')).update(toSign).digest('base64');
  return `SharedKey ${accountName}:${signature}`;
}

export async function collectWebAppAccessEvidence(accountName, expectedPrivateIps, phase) {
  const result = {
    phase, privateDnsMatches: false, dnsError: '',
    smbTcpConnected: false, smbTcpError: '',
    keyResolved: false, fileRestStatus: null, fileRestError: '', mountInfo: ''
  };
  try {
    const addresses = await Promise.race([
      lookup(`${accountName}.file.core.windows.net`, { all: true }),
      new Promise((_, reject) => {
        setTimeout(() => reject(Object.assign(new Error(), { code: 'ETIMEDOUT' })), 15000).unref();
      })
    ]);
    result.privateDnsMatches = addresses.length > 0 &&
      addresses.every(address => expectedPrivateIps.includes(address.address));
  } catch (error) {
    result.dnsError = getSafeNetworkError(error);
  }
  const connection = await new Promise(resolve => {
    const socket = new Socket();
    const finish = (connected, error = '') => {
      socket.destroy();
      resolve({ connected, error });
    };
    socket.setTimeout(10000, () => finish(false, 'ETIMEDOUT'));
    socket.once('error', error => finish(false, getSafeNetworkError(error)));
    socket.connect(445, `${accountName}.file.core.windows.net`, () => finish(true));
  });
  result.smbTcpConnected = connection.connected;
  result.smbTcpError = connection.error;
  const key = process.env.STORAGE_ACCOUNT_KEY;
  result.keyResolved = typeof key === 'string' && /^[A-Za-z0-9+/]{86}==$/.test(key);
  if (result.keyResolved) {
    try {
      const date = new Date().toUTCString();
      const response = await fetch(`https://${accountName}.file.core.windows.net/foundryvttdata?restype=share`, {
        headers: {
          'x-ms-date': date, 'x-ms-version': '2023-11-03',
          Authorization: createShareAuthorization(accountName, key, date)
        },
        redirect: 'error', signal: AbortSignal.timeout(15000)
      });
      result.fileRestStatus = response.status;
      const code = response.headers.get('x-ms-error-code') ?? '';
      const supported = new Set([
        '', 'AuthenticationFailed', 'AuthorizationFailure', 'AuthorizationPermissionMismatch',
        'KeyBasedAuthenticationNotPermitted', 'ShareNotFound', 'AccountIsDisabled', 'InvalidHeaderValue'
      ]);
      result.fileRestError = supported.has(code) ? code : 'UnclassifiedStorageError';
      await response.body?.cancel();
    } catch (error) {
      result.fileRestError = getSafeNetworkError(error);
    }
  } else {
    result.fileRestError = 'StorageKeyNotResolved';
  }
  result.mountInfo = redactMountInfo(readFileSync('/proc/self/mountinfo', 'utf8')
    .split('\n').filter(line => line.split(' ')[4] === '/data').join('\n'));
  console.error(`FVTT_ACCESSINFO:${Buffer.from(JSON.stringify(result)).toString('base64')}`);
}
