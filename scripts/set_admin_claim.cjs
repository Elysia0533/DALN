#!/usr/bin/env node

const { applicationDefault, cert, getApps, initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const fs = require('node:fs');

function parseArgs(argv) {
  const options = {
    email: '',
    projectId: '',
    credentialPath: process.env.GOOGLE_APPLICATION_CREDENTIALS || '',
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--email') {
      options.email = argv[++i] || '';
    } else if (arg === '--project-id') {
      options.projectId = argv[++i] || '';
    } else if (arg === '--credential') {
      options.credentialPath = argv[++i] || '';
    } else if (arg === '--help') {
      options.help = true;
    } else {
      throw new Error(`Unsupported argument: ${arg}`);
    }
  }

  return options;
}

function validateOptions(options) {
  if (!options.email || typeof options.email !== 'string') {
    throw new Error('Missing required --email.');
  }
  if (!options.projectId || typeof options.projectId !== 'string') {
    throw new Error('Missing required --project-id.');
  }
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(options.email)) {
    throw new Error('Invalid --email.');
  }
  if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(options.projectId)) {
    throw new Error('Invalid --project-id.');
  }
}

function readCredentialProjectId(credentialPath) {
  if (!credentialPath) return '';
  const raw = fs.readFileSync(credentialPath, 'utf8');
  const parsed = JSON.parse(raw);
  return typeof parsed.project_id === 'string' ? parsed.project_id : '';
}

function credentialFor(options) {
  if (!options.credentialPath) {
    return applicationDefault();
  }
  const raw = fs.readFileSync(options.credentialPath, 'utf8');
  return cert(JSON.parse(raw));
}

function initializeAdmin(options) {
  if (getApps().length > 0) return;
  initializeApp({
    credential: credentialFor(options),
    projectId: options.projectId,
  });
}

async function setAdminClaim(options) {
  validateOptions(options);

  const credentialProjectId = readCredentialProjectId(options.credentialPath);
  if (credentialProjectId && credentialProjectId !== options.projectId) {
    throw new Error('Credential project does not match --project-id.');
  }

  initializeAdmin(options);
  const auth = getAuth();
  const user = await auth.getUserByEmail(options.email);
  if (!user.emailVerified) {
    throw new Error('Refusing to set admin claim: email is not verified.');
  }

  const existingClaims = user.customClaims || {};
  await auth.setCustomUserClaims(user.uid, {
    ...existingClaims,
    admin: true,
  });

  const refreshedUser = await auth.getUserByEmail(options.email);
  if (refreshedUser.customClaims?.admin !== true) {
    throw new Error('Admin claim verification failed after write.');
  }
}

function printHelp() {
  console.log(
    [
      'Usage:',
      '  node scripts/set_admin_claim.cjs --email <admin-email> --project-id <firebase-project-id>',
      '',
      'Credentials:',
      '  Use Application Default Credentials or set GOOGLE_APPLICATION_CREDENTIALS.',
      '  You may also pass --credential <service-account-json> from a trusted machine.',
      '',
      'Safety:',
      '  The script reads Auth only, preserves existing custom claims, and writes only custom claims.',
      '  It does not print UID, tokens, or claim contents.',
    ].join('\n'),
  );
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printHelp();
    return;
  }
  await setAdminClaim(options);
  console.log('Admin custom claim is set and verified for the requested account.');
}

if (require.main === module) {
  main().catch((error) => {
    if (error.code === 'auth/user-not-found') {
      console.error('Refusing to set admin claim: account does not exist.');
    } else {
      console.error(error.message);
    }
    process.exitCode = 1;
  });
}

module.exports = {
  parseArgs,
  readCredentialProjectId,
  setAdminClaim,
  validateOptions,
};
