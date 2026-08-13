#!/usr/bin/env node

const { initializeApp, deleteApp } = require('firebase/app');
const {
  collection,
  connectFirestoreEmulator,
  documentId,
  getDocs,
  getFirestore,
  limit,
  orderBy,
  query,
  startAfter,
} = require('firebase/firestore');

function parseArgs(argv) {
  const options = {
    projectId: 'demo-vbook-community-audit',
    batchSize: 100,
    production: false,
    confirmProduction: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project') {
      options.projectId = argv[++i] || '';
    } else if (arg === '--batch-size') {
      options.batchSize = Number.parseInt(argv[++i] || '', 10);
    } else if (arg === '--production') {
      options.production = true;
    } else if (arg === '--confirm-production-audit') {
      options.confirmProduction = true;
    } else if (arg === '--help') {
      options.help = true;
    } else {
      throw new Error(`Unsupported argument: ${arg}`);
    }
  }

  return options;
}

function validateOptions(options) {
  if (!options.projectId || typeof options.projectId !== 'string') {
    throw new Error('Missing --project value.');
  }
  if (!Number.isInteger(options.batchSize) || options.batchSize < 1) {
    throw new Error('--batch-size must be a positive integer.');
  }
  if (options.production && !options.confirmProduction) {
    throw new Error(
      'Production audit requires --confirm-production-audit and an explicit --project.',
    );
  }
  if (!options.production && !process.env.FIRESTORE_EMULATOR_HOST) {
    throw new Error(
      'FIRESTORE_EMULATOR_HOST is required. Run this script through Firebase Emulator.',
    );
  }
}

function emptyStats() {
  return {
    scanned: 0,
    withAttachmentType: 0,
    withAttachmentPath: 0,
    emptyPath: 0,
    localOrFilePath: 0,
    httpPath: 0,
    attachmentOnly: 0,
    textAndAttachment: 0,
  };
}

function hasText(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function pathKind(value) {
  if (typeof value !== 'string' || value.trim().length === 0) return 'empty';
  const path = value.trim().toLowerCase();
  if (path.startsWith('http://') || path.startsWith('https://')) return 'http';
  if (
    path.startsWith('file://') ||
    path.startsWith('content://') ||
    path.startsWith('/') ||
    /^[a-z]:[\\/]/i.test(value) ||
    value.includes('\\')
  ) {
    return 'local';
  }
  return 'other';
}

function updateStats(stats, data) {
  const attachmentType = data.attachmentType;
  const attachmentPath = data.attachmentPath;
  const hasAttachmentType = hasText(attachmentType);
  const hasAttachmentPathField = Object.prototype.hasOwnProperty.call(
    data,
    'attachmentPath',
  );
  const hasAttachmentPath = hasText(attachmentPath);
  const hasAttachment = hasAttachmentType || hasAttachmentPathField;
  const textPresent = hasText(data.text);

  stats.scanned += 1;
  if (hasAttachmentType) stats.withAttachmentType += 1;
  if (hasAttachmentPathField) stats.withAttachmentPath += 1;
  if (hasAttachmentPathField && !hasAttachmentPath) stats.emptyPath += 1;

  if (hasAttachmentPath) {
    const kind = pathKind(attachmentPath);
    if (kind === 'local') stats.localOrFilePath += 1;
    if (kind === 'http') stats.httpPath += 1;
  }

  if (hasAttachment && !textPresent) stats.attachmentOnly += 1;
  if (hasAttachment && textPresent) stats.textAndAttachment += 1;
}

async function auditCommunityAttachments(options) {
  validateOptions(options);

  if (options.production) {
    throw new Error(
      'Production audit is not executed by this read-only task. Use a separate approved runbook.',
    );
  }

  const [host, portText] = process.env.FIRESTORE_EMULATOR_HOST.split(':');
  const app = initializeApp({
    projectId: options.projectId,
    apiKey: 'emulator-only',
    appId: `demo-${options.projectId}`,
  });
  const db = getFirestore(app);
  connectFirestoreEmulator(db, host, Number.parseInt(portText, 10));

  const stats = emptyStats();
  let lastDoc = null;

  try {
    for (;;) {
      const base = [
        collection(db, 'community_messages'),
        orderBy(documentId()),
        limit(options.batchSize),
      ];
      const pageQuery = lastDoc
        ? query(...base, startAfter(lastDoc))
        : query(...base);
      const snapshot = await getDocs(pageQuery);
      if (snapshot.empty) break;

      for (const doc of snapshot.docs) {
        updateStats(stats, doc.data());
      }

      lastDoc = snapshot.docs[snapshot.docs.length - 1];
      if (snapshot.size < options.batchSize) break;
    }
  } finally {
    await deleteApp(app);
  }

  return stats;
}

function printStats(stats) {
  console.log(JSON.stringify(stats, null, 2));
}

function printHelp() {
  console.log(
    [
      'Usage: npm run audit:community-attachments -- [--project demo-id] [--batch-size 100]',
      'Default mode requires FIRESTORE_EMULATOR_HOST and never writes data.',
      'Production audit is intentionally blocked in SEC-004C.',
    ].join('\n'),
  );
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printHelp();
    return;
  }
  const stats = await auditCommunityAttachments(options);
  printStats(stats);
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}

module.exports = {
  auditCommunityAttachments,
  emptyStats,
  parseArgs,
  pathKind,
  updateStats,
  validateOptions,
};
