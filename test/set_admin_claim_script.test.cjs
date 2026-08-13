const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  parseArgs,
  readCredentialProjectId,
  validateOptions,
} = require('../scripts/set_admin_claim.cjs');

describe('set admin claim script guards', () => {
  it('requires email and project id arguments', () => {
    assert.throws(() => validateOptions(parseArgs([])), /Missing required --email/);
    assert.throws(
      () => validateOptions(parseArgs(['--email', 'admin@example.test'])),
      /Missing required --project-id/,
    );
  });

  it('rejects malformed email and project id', () => {
    assert.throws(
      () =>
        validateOptions(
          parseArgs(['--email', 'not-email', '--project-id', 'demo-valid1']),
        ),
      /Invalid --email/,
    );
    assert.throws(
      () =>
        validateOptions(
          parseArgs(['--email', 'admin@example.test', '--project-id', 'Bad_Project']),
        ),
      /Invalid --project-id/,
    );
  });

  it('reads project id from a service account credential without printing secrets', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vbook-admin-claim-'));
    const credentialPath = path.join(dir, 'service-account.json');
    fs.writeFileSync(
      credentialPath,
      JSON.stringify({
        type: 'service_account',
        project_id: 'demo-vbook-test',
        private_key: 'redacted',
        client_email: 'redacted@example.test',
      }),
    );

    assert.equal(readCredentialProjectId(credentialPath), 'demo-vbook-test');
  });
});
