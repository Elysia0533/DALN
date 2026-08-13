const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {
  collection,
  doc,
  getDocs,
  query,
  setDoc,
} = require('firebase/firestore');

const {
  auditCommunityAttachments,
  parseArgs,
  pathKind,
  validateOptions,
} = require('../scripts/audit_community_attachments.cjs');

const projectId = 'demo-vbook-sec-004c-audit';

describe('community attachment audit script', () => {
  let testEnv;

  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId,
      firestore: {
        rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
      },
    });
  });

  after(async () => {
    await testEnv.cleanup();
  });

  beforeEach(async () => {
    await testEnv.clearFirestore();
  });

  it('counts legacy attachment shapes without printing sensitive values', async () => {
    const rawPath = '/storage/emulated/0/DCIM/private-photo.jpg';
    const rawText = 'private text should not be printed';
    const rawUserId = 'user-secret';
    const rawDisplayName = 'Sensitive Name';

    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      const ref = collection(db, 'community_messages');
      await setDoc(doc(ref, '01-text'), {
        userId: rawUserId,
        displayName: rawDisplayName,
        text: rawText,
      });
      await setDoc(doc(ref, '02-android-local'), {
        userId: rawUserId,
        displayName: rawDisplayName,
        text: rawText,
        attachmentPath: rawPath,
      });
      await setDoc(doc(ref, '03-file'), {
        text: rawText,
        attachmentPath: 'file:///data/user/0/app/cache/a.png',
      });
      await setDoc(doc(ref, '04-content'), {
        text: rawText,
        attachmentPath: 'content://media/external/images/1',
      });
      await setDoc(doc(ref, '05-http'), {
        text: rawText,
        attachmentPath: 'https://example.test/legacy.png',
      });
      await setDoc(doc(ref, '06-attachment-only'), {
        attachmentType: 'image',
        attachmentPath: 'C:\\Users\\OS\\secret.png',
      });
      await setDoc(doc(ref, '07-text-attachment'), {
        text: rawText,
        attachmentType: 'image',
        attachmentPath: '',
      });
    });

    const stats = await auditCommunityAttachments({ projectId, batchSize: 2 });
    assert.deepEqual(stats, {
      scanned: 7,
      withAttachmentType: 2,
      withAttachmentPath: 6,
      emptyPath: 1,
      localOrFilePath: 4,
      httpPath: 1,
      attachmentOnly: 1,
      textAndAttachment: 5,
    });

    const output = JSON.stringify(stats);
    assert.equal(output.includes(rawPath), false);
    assert.equal(output.includes(rawText), false);
    assert.equal(output.includes(rawUserId), false);
    assert.equal(output.includes(rawDisplayName), false);

    const db = testEnv.unauthenticatedContext().firestore();
    const snapshot = await getDocs(query(collection(db, 'community_messages')));
    assert.equal(snapshot.size, 7);
  });

  it('classifies local, file, content, and http paths', () => {
    assert.equal(pathKind('/storage/emulated/0/a.png'), 'local');
    assert.equal(pathKind('file:///tmp/a.png'), 'local');
    assert.equal(pathKind('content://media/a.png'), 'local');
    assert.equal(pathKind('C:\\Users\\OS\\a.png'), 'local');
    assert.equal(pathKind('https://example.test/a.png'), 'http');
    assert.equal(pathKind(''), 'empty');
  });

  it('rejects production mode without explicit confirmation', () => {
    assert.throws(
      () =>
        validateOptions(
          parseArgs(['--production', '--project', 'real-project-id']),
        ),
      /Production audit requires/,
    );
  });

  it('exits non-zero for invalid production CLI configuration', () => {
    const script = path.join(
      __dirname,
      '..',
      'scripts',
      'audit_community_attachments.cjs',
    );
    const result = spawnSync(
      process.execPath,
      [script, '--production', '--project', 'real-project-id'],
      { encoding: 'utf8' },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Production audit requires/);
  });
});
