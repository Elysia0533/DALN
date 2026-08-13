const fs = require('fs');
const path = require('path');
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {
  addDoc,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
} = require('firebase/firestore');
const assert = require('assert');

const PROJECT_ID = 'demo-vbook-sec-004b';
const rules = fs.readFileSync(
  path.join(__dirname, '..', 'firestore.rules'),
  'utf8',
);

let testEnv;

function authedDb(uid, token = {}) {
  return testEnv.authenticatedContext(uid, token).firestore();
}

function guestDb() {
  return testEnv.unauthenticatedContext().firestore();
}

const aliceToken = { email: 'alice@example.com', email_verified: true };
const bobToken = { email: 'bob@example.com', email_verified: true };
const unverifiedToken = {
  email: 'new-user@example.com',
  email_verified: false,
};
const adminToken = {
  email: 'moderator@example.com',
  email_verified: true,
  admin: true,
};
const emailOnlyAdminToken = {
  email: 'legacy-moderator@example.test',
  email_verified: true,
};

function ts(offset = 0) {
  return Timestamp.fromMillis(1700000000000 + offset);
}

function userData(uid, overrides = {}) {
  return {
    uid,
    email: `${uid}@example.com`,
    displayName: uid,
    avatarUrl: '',
    role: 'user',
    emailVerified: true,
    createdAt: ts(1),
    updatedAt: ts(2),
    ...overrides,
  };
}

function userCreateData(uid, overrides = {}) {
  return {
    uid,
    email: `${uid}@example.com`,
    displayName: uid,
    avatarUrl: '',
    role: 'user',
    emailVerified: true,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

function libraryData(storyId, overrides = {}) {
  return {
    storyId,
    story: {
      id: storyId,
      title: 'Story',
      content: '',
      titleEng: '',
      contentEng: '',
      description: '',
      author: '',
      genres: [],
      totalChapters: 10,
      currentChapter: 1,
      savedChapterIndex: 0,
      iconUrl: '',
      localPath: '',
      isLocal: false,
      driveFileId: '',
      isFromDrive: false,
      fileType: 'epub',
      pluginId: '',
      storyUrl: '',
    },
    savedChapterIndex: 0,
    totalChapters: 10,
    scrollOffset: 0,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

function seededLibraryData(storyId, overrides = {}) {
  return {
    ...libraryData(storyId, {
      createdAt: ts(1),
      updatedAt: ts(2),
    }),
    ...overrides,
  };
}

function bookmarkData(bookmarkId, overrides = {}) {
  return {
    id: bookmarkId,
    storyId: 'story-1',
    storyTitle: 'Story',
    chapterTitle: 'Chapter 1',
    iconUrl: '',
    driveFileId: '',
    fileType: 'epub',
    localPath: 'private/local/path.epub',
    chapterIndex: 0,
    paragraphIndex: 0,
    snippet: 'Marked text',
    scrollOffset: 0,
    createdAt: '2026-08-12T00:00:00.000Z',
    updatedAt: '2026-08-12T00:00:00.000Z',
    ...overrides,
  };
}

function communityData(uid, overrides = {}) {
  return {
    userId: uid,
    displayName: uid,
    avatarUrl: '',
    text: 'Hello community',
    createdAt: serverTimestamp(),
    ...overrides,
  };
}

async function seed(pathSegments, data) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), ...pathSegments), data);
  });
}

describe('firestore.rules', () => {
  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: PROJECT_ID,
      firestore: { rules },
    });
  });

  beforeEach(async () => {
    await testEnv.clearFirestore();
  });

  after(async () => {
    await testEnv.cleanup();
  });

  describe('users/{uid}', () => {
    beforeEach(async () => {
      await seed(['users', 'alice'], userData('alice'));
    });

    it('denies guest and other-user reads, allows owner and admin reads', async () => {
      await assertFails(getDoc(doc(guestDb(), 'users/alice')));
      await assertSucceeds(getDoc(doc(authedDb('alice', aliceToken), 'users/alice')));
      await assertFails(getDoc(doc(authedDb('bob', bobToken), 'users/alice')));
      await assertSucceeds(getDoc(doc(authedDb('admin', adminToken), 'users/alice')));
    });

    it('allows valid owner profile create', async () => {
      await assertSucceeds(
        setDoc(
          doc(authedDb('charlie', {
            email: 'charlie@example.com',
            email_verified: true,
          }), 'users/charlie'),
          userCreateData('charlie'),
        ),
      );
    });

    it('denies uid mismatch and client-created admin role', async () => {
      await assertFails(
        setDoc(
          doc(authedDb('alice', aliceToken), 'users/bob'),
          userCreateData('bob'),
        ),
      );
      await assertFails(
        setDoc(
          doc(authedDb('dana', {
            email: 'dana@example.com',
            email_verified: true,
          }), 'users/dana'),
          userCreateData('dana', { role: 'admin' }),
        ),
      );
    });

    it('allows owner profile display fields update', async () => {
      await assertSucceeds(
        updateDoc(doc(authedDb('alice', aliceToken), 'users/alice'), {
          displayName: 'Alice New',
          avatarUrl: 'https://example.com/avatar.png',
          updatedAt: serverTimestamp(),
        }),
      );
    });

    it('denies owner changing role, email, uid, or createdAt', async () => {
      const db = authedDb('alice', aliceToken);
      await assertFails(updateDoc(doc(db, 'users/alice'), { role: 'admin' }));
      await assertFails(updateDoc(doc(db, 'users/alice'), { email: 'x@example.com' }));
      await assertFails(updateDoc(doc(db, 'users/alice'), { uid: 'bob' }));
      await assertFails(updateDoc(doc(db, 'users/alice'), { createdAt: serverTimestamp() }));
    });

    it('denies owner delete and allows custom-claim admin delete', async () => {
      await assertFails(deleteDoc(doc(authedDb('alice', aliceToken), 'users/alice')));
      await assertSucceeds(deleteDoc(doc(authedDb('admin', adminToken), 'users/alice')));
    });
  });

  describe('users/{uid}/library/{storyId}', () => {
    beforeEach(async () => {
      await seed(['users', 'alice'], userData('alice'));
      await seed(
        ['users', 'alice', 'library', 'story-1'],
        seededLibraryData('story-1'),
      );
    });

    it('allows owner CRUD', async () => {
      const db = authedDb('alice', aliceToken);
      await assertSucceeds(getDoc(doc(db, 'users/alice/library/story-1')));
      await assertSucceeds(
        setDoc(doc(db, 'users/alice/library/story-2'), libraryData('story-2')),
      );
      await assertSucceeds(
        updateDoc(doc(db, 'users/alice/library/story-1'), {
          savedChapterIndex: 2,
          updatedAt: serverTimestamp(),
          lastReadAt: serverTimestamp(),
        }),
      );
      await assertSucceeds(deleteDoc(doc(db, 'users/alice/library/story-1')));
    });

    it('denies other-user CRUD', async () => {
      const db = authedDb('bob', bobToken);
      await assertFails(getDoc(doc(db, 'users/alice/library/story-1')));
      await assertFails(
        setDoc(doc(db, 'users/alice/library/story-2'), libraryData('story-2')),
      );
      await assertFails(
        updateDoc(doc(db, 'users/alice/library/story-1'), {
          savedChapterIndex: 3,
          updatedAt: serverTimestamp(),
        }),
      );
      await assertFails(deleteDoc(doc(db, 'users/alice/library/story-1')));
    });

    it('denies mismatched storyId, negative values, wrong types, and extra fields', async () => {
      const db = authedDb('alice', aliceToken);
      await assertFails(
        setDoc(doc(db, 'users/alice/library/story-x'), libraryData('story-y')),
      );
      await assertFails(
        setDoc(
          doc(db, 'users/alice/library/story-neg'),
          libraryData('story-neg', { savedChapterIndex: -1 }),
        ),
      );
      await assertFails(
        setDoc(
          doc(db, 'users/alice/library/story-scroll'),
          libraryData('story-scroll', { scrollOffset: -0.1 }),
        ),
      );
      await assertFails(
        setDoc(
          doc(db, 'users/alice/library/story-type'),
          libraryData('story-type', { totalChapters: '10' }),
        ),
      );
      await assertFails(
        setDoc(
          doc(db, 'users/alice/library/story-extra'),
          libraryData('story-extra', { unexpected: true }),
        ),
      );
    });
  });

  describe('users/{uid}/bookmarks/{bookmarkId}', () => {
    beforeEach(async () => {
      await seed(['users', 'alice'], userData('alice'));
      await seed(
        ['users', 'alice', 'bookmarks', 'bookmark-1'],
        bookmarkData('bookmark-1'),
      );
    });

    it('allows owner CRUD', async () => {
      const db = authedDb('alice', aliceToken);
      await assertSucceeds(getDoc(doc(db, 'users/alice/bookmarks/bookmark-1')));
      await assertSucceeds(
        setDoc(
          doc(db, 'users/alice/bookmarks/bookmark-2'),
          bookmarkData('bookmark-2'),
        ),
      );
      await assertSucceeds(
        updateDoc(doc(db, 'users/alice/bookmarks/bookmark-1'), {
          snippet: 'Updated',
          updatedAt: '2026-08-12T00:01:00.000Z',
        }),
      );
      await assertSucceeds(deleteDoc(doc(db, 'users/alice/bookmarks/bookmark-1')));
    });

    it('denies other-user CRUD', async () => {
      const db = authedDb('bob', bobToken);
      await assertFails(getDoc(doc(db, 'users/alice/bookmarks/bookmark-1')));
      await assertFails(
        setDoc(
          doc(db, 'users/alice/bookmarks/bookmark-2'),
          bookmarkData('bookmark-2'),
        ),
      );
      await assertFails(
        updateDoc(doc(db, 'users/alice/bookmarks/bookmark-1'), {
          snippet: 'Nope',
        }),
      );
      await assertFails(deleteDoc(doc(db, 'users/alice/bookmarks/bookmark-1')));
    });

    it('denies id mismatch, timestamp objects, extra fields, and wrong types', async () => {
      const db = authedDb('alice', aliceToken);
      await assertFails(
        setDoc(
          doc(db, 'users/alice/bookmarks/bookmark-x'),
          bookmarkData('bookmark-y'),
        ),
      );
      await assertFails(
        setDoc(
          doc(db, 'users/alice/bookmarks/bookmark-ts'),
          bookmarkData('bookmark-ts', { createdAt: Timestamp.now() }),
        ),
      );
      await assertFails(
        setDoc(
          doc(db, 'users/alice/bookmarks/bookmark-extra'),
          bookmarkData('bookmark-extra', { unexpected: true }),
        ),
      );
      await assertFails(
        setDoc(
          doc(db, 'users/alice/bookmarks/bookmark-type'),
          bookmarkData('bookmark-type', { paragraphIndex: '0' }),
        ),
      );
    });
  });

  describe('community_messages/{messageId}', () => {
    beforeEach(async () => {
      await seed(['community_messages', 'message-1'], {
        userId: 'alice',
        displayName: 'alice',
        avatarUrl: '',
        text: 'Seeded',
        createdAt: ts(1),
      });
    });

    it('allows guest and authenticated read query compatibility', async () => {
      const guestQuery = query(
        collection(guestDb(), 'community_messages'),
        orderBy('createdAt', 'desc'),
        limit(50),
      );
      const authQuery = query(
        collection(authedDb('alice', aliceToken), 'community_messages'),
        orderBy('createdAt', 'desc'),
        limit(50),
      );

      await assertSucceeds(getDocs(guestQuery));
      const authSnapshot = await assertSucceeds(getDocs(authQuery));
      assert.strictEqual(authSnapshot.docs.length, 1);
    });

    it('allows verified users to create valid server-timestamp text messages', async () => {
      await assertSucceeds(
        addDoc(
          collection(authedDb('alice', aliceToken), 'community_messages'),
          communityData('alice'),
        ),
      );
    });

    it('denies unverified users, forged userId, blank/whitespace/long text, and long profile fields', async () => {
      await assertFails(
        addDoc(
          collection(authedDb('new-user', unverifiedToken), 'community_messages'),
          communityData('new-user'),
        ),
      );
      await assertFails(
        addDoc(
          collection(authedDb('alice', aliceToken), 'community_messages'),
          communityData('bob'),
        ),
      );
      await assertFails(
        addDoc(
          collection(authedDb('alice', aliceToken), 'community_messages'),
          communityData('alice', { text: '' }),
        ),
      );
      await assertFails(
        addDoc(
          collection(authedDb('alice', aliceToken), 'community_messages'),
          communityData('alice', { text: '   \n\t   ' }),
        ),
      );
      await assertFails(
        addDoc(
          collection(authedDb('alice', aliceToken), 'community_messages'),
          communityData('alice', { text: 'x'.repeat(1001) }),
        ),
      );
      await assertFails(
        addDoc(
          collection(authedDb('alice', aliceToken), 'community_messages'),
          communityData('alice', { displayName: 'x'.repeat(31) }),
        ),
      );
      await assertFails(
        addDoc(
          collection(authedDb('alice', aliceToken), 'community_messages'),
          communityData('alice', { avatarUrl: 'x'.repeat(501) }),
        ),
      );
    });

    it('denies client-created timestamps, extra fields, attachments, and attachment-only messages', async () => {
      const db = authedDb('alice', aliceToken);
      await assertFails(
        addDoc(
          collection(db, 'community_messages'),
          communityData('alice', { createdAt: Timestamp.now() }),
        ),
      );
      await assertFails(
        addDoc(
          collection(db, 'community_messages'),
          communityData('alice', { unexpected: true }),
        ),
      );
      await assertFails(
        addDoc(
          collection(db, 'community_messages'),
          communityData('alice', {
            attachmentType: 'image',
            attachmentPath: 'C:\\Users\\alice\\photo.png',
          }),
        ),
      );
      await assertFails(
        addDoc(
          collection(db, 'community_messages'),
          communityData('alice', {
            text: '',
            attachmentType: 'image',
            attachmentPath: 'C:\\Users\\alice\\photo.png',
          }),
        ),
      );
    });

    it('denies all updates, including admin updates', async () => {
      await assertFails(
        updateDoc(doc(authedDb('alice', aliceToken), 'community_messages/message-1'), {
          text: 'Edited',
        }),
      );
      await assertFails(
        updateDoc(doc(authedDb('admin', adminToken), 'community_messages/message-1'), {
          text: 'Edited by admin',
        }),
      );
    });

    it('allows only custom-claim admin deletes', async () => {
      await assertFails(
        deleteDoc(doc(authedDb('alice', aliceToken), 'community_messages/message-1')),
      );
      await assertFails(
        deleteDoc(doc(authedDb('bob', bobToken), 'community_messages/message-1')),
      );
      await assertFails(
        deleteDoc(
          doc(
            authedDb('email-admin', emailOnlyAdminToken),
            'community_messages/message-1',
          ),
        ),
      );
      await assertSucceeds(
        deleteDoc(doc(authedDb('admin', adminToken), 'community_messages/message-1')),
      );
    });
  });
});
