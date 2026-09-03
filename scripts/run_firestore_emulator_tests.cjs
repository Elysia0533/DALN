'use strict';

const { spawnSync } = require('node:child_process');
const path = require('node:path');

const firestorePort = 8080;

function findWindowsListenerPid(port) {
  if (process.platform !== 'win32') return null;

  const result = spawnSync('netstat', ['-ano', '-p', 'TCP'], {
    encoding: 'utf8',
    windowsHide: true,
  });
  if (result.status !== 0) return null;

  for (const line of result.stdout.split(/\r?\n/)) {
    const fields = line.trim().split(/\s+/);
    if (
      fields.length >= 5 &&
      fields[0] === 'TCP' &&
      fields[1].endsWith(`:${port}`) &&
      fields[3] === 'LISTENING'
    ) {
      const pid = Number.parseInt(fields[4], 10);
      return Number.isInteger(pid) ? pid : null;
    }
  }
  return null;
}

const suites = {
  attachments: {
    projectId: 'demo-vbook-sec-004c-audit',
    command: 'npm run test:audit-community-attachments:unit',
  },
  rules: {
    projectId: 'demo-vbook-sec-004b',
    command: 'npm run test:rules',
  },
  'sec-004c': {
    projectId: 'demo-vbook-sec-004c',
    command:
      'npm run test:rules && npm run test:audit-community-attachments:unit',
  },
};

const suite = suites[process.argv[2]];
if (!suite) {
  console.error('Unknown Firestore emulator test suite.');
  process.exitCode = 2;
} else {
  const environment = { ...process.env };
  delete environment.DEBUG;
  const listenerBefore = findWindowsListenerPid(firestorePort);

  const firebaseCli = require.resolve('firebase-tools/lib/bin/firebase.js');
  const result = spawnSync(
    process.execPath,
    [
      firebaseCli,
      'emulators:exec',
      '--project',
      suite.projectId,
      '--only',
      'firestore',
      suite.command,
    ],
    {
      cwd: path.resolve(__dirname, '..'),
      env: environment,
      stdio: 'inherit',
      windowsHide: true,
    },
  );

  let cleanupFailed = false;
  if (listenerBefore === null) {
    const listenerAfter = findWindowsListenerPid(firestorePort);
    if (listenerAfter !== null) {
      try {
        process.kill(listenerAfter);
      } catch (error) {
        if (error.code !== 'ESRCH') {
          console.error('Unable to stop the Firestore emulator process.');
          cleanupFailed = true;
        }
      }
    }
  }

  if (result.error) {
    console.error('Unable to run the Firestore emulator test suite.');
    process.exitCode = 1;
  } else if (cleanupFailed) {
    process.exitCode = 1;
  } else {
    process.exitCode = result.status ?? 1;
  }
}
