// Publishes firestore.rules through the Firebase Rules API.
// Needs only the permissions the default Firebase Admin SDK service account already has.
const { GoogleAuth } = require('google-auth-library');
const fs = require('fs');

(async () => {
  const pid = process.env.PROJECT_ID;
  const auth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });
  const client = await auth.getClient();
  const base = 'https://firebaserules.googleapis.com/v1';
  const source = fs.readFileSync(__dirname + '/firestore.rules', 'utf8');

  const rs = await client.request({
    url: `${base}/projects/${pid}/rulesets`,
    method: 'POST',
    data: { source: { files: [{ name: 'firestore.rules', content: source }] } },
  });
  const rulesetName = rs.data.name;
  const release = `projects/${pid}/releases/cloud.firestore`;
  try {
    await client.request({ url: `${base}/${release}`, method: 'PATCH', data: { release: { name: release, rulesetName } } });
  } catch (e) {
    if (e.response && e.response.status === 404) {
      await client.request({ url: `${base}/projects/${pid}/releases`, method: 'POST', data: { name: release, rulesetName } });
    } else {
      throw e;
    }
  }
  console.log('Firestore rules published:', rulesetName);
})().catch((e) => {
  const detail = e.response ? JSON.stringify(e.response.data) : e.message;
  console.log('::error::Rules deploy failed: ' + detail.slice(0, 900));
  process.exit(1);
});
