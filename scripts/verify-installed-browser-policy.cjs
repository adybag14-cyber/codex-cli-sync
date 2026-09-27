const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');

const servicePath = process.argv[2];
assert(servicePath, 'Usage: node verify-installed-browser-policy.cjs <browser-service.mjs>');
const sourceBytes = fs.readFileSync(servicePath);
const source = sourceBytes.toString('utf8');
// Minified symbol names are version-specific. Never report an unknown bundle as verified.
assert.equal(crypto.createHash('sha256').update(sourceBytes).digest('hex'),
  'b40b10c44f2397b3137c40060ace432cc2487e6075b07551a6944f81bea3bb91',
  'Unknown browser-service bundle; review source anchors and the policy contract before updating this verifier');
function section(start, end) {
  const begin = source.indexOf(start);
  const finish = source.indexOf(end, begin + start.length);
  assert(begin >= 0 && finish > begin, `Missing source anchors: ${start}, ${end}`);
  assert.equal(source.indexOf(start, begin + start.length), -1, `Ambiguous source anchor: ${start}`);
  return source.slice(begin, finish);
}

// Execute only the unmodified, pure policy functions from the installed bundle.
// The VM receives no file, browser, network, process, or module capabilities.
const context = vm.createContext({URL});
const extracted = [
  'const u = () => {}; const le = (factory) => factory;',
  section('function $x(', 'function Wx('),
  section('function mS(', 'var _g='),
  section('function PS(', 'var IS='),
  section('function xM(', 'var BM='),
  'gg(); this.api = {navigation: $x, parsePattern: bS, policy: xM, policyDecision: RZ};',
].join('\n');
vm.runInContext(extracted, context, {timeout: 1000});
const api = context.api;
const results = [];
function check(name, operation) {
  operation();
  results.push({name, passed: true});
}
async function checkAsync(name, operation) {
  await operation();
  results.push({name, passed: true});
}

(async () => {
  for (const scheme of ['http', 'https']) {
    check(`${scheme}: origin pattern accepted`, () => assert(api.parsePattern(`${scheme}://example.com`)));
    check(`${scheme}: URL accepted by navigation gate`, () => assert.equal(api.navigation(`${scheme}://example.com/`).allowed, true));
    check(`${scheme}: explicit allow overrides user default deny`, () => {
      const policy = api.policy(null, {
        default_origin_policy: {access: 'deny'},
        origins: {[`${scheme}://example.com`]: {access: 'allow'}},
      }, `${scheme}://example.com/`);
      assert.equal(policy.access, 'allow');
    });
    check(`${scheme}: managed deny still wins over user allow`, () => {
      const policy = api.policy({defaultOriginPolicy: {access: 'deny'}}, {
        origins: {[`${scheme}://example.com`]: {access: 'allow'}},
      }, `${scheme}://example.com/`);
      assert.equal(policy.access, 'deny');
    });
  }
  for (const [pattern, url] of [
    ['file://*', 'file:///C:/scheme-probe.html'],
    ['data:*', 'data:text/plain,CODEX_SCHEME_PROBE'],
    ['chrome://*', 'chrome://version'],
    ['edge://*', 'edge://version'],
  ]) {
    check(`${pattern}: origin pattern rejected`, () => assert.equal(api.parsePattern(pattern), null));
    check(`${pattern}: navigation rejected independently of origin policy`, () => {
      assert.equal(api.policy(null, {default_origin_policy: {access: 'allow'}, origins: {[pattern]: {access: 'allow'}}}, url).access, 'allow');
      assert.equal(api.navigation(url).allowed, false);
      assert.equal(api.navigation(url).reason, 'unsupported_protocol');
    });
  }
  check('access allow preserves upload/download/CDP denies', () => {
    const policy = api.policy(null, {origins: {'https://example.com': {
      access: 'allow', uploads: 'deny', downloads: 'deny', full_cdp_access: 'deny',
    }}}, 'https://example.com/');
    assert.equal(policy.access, 'allow');
    assert.equal(policy.uploads, 'deny');
    assert.equal(policy.downloads, 'deny');
    assert.equal(policy.fullCdpAccess, 'deny');
  });
  check('unset access already defaults to allow', () => assert.equal(api.policy(null, null, 'https://example.com/').access, 'allow'));
  check('about:blank is an exact navigation exception', () => {
    assert.equal(api.navigation('about:blank').allowed, true);
    assert.equal(api.navigation('about:blank#probe').allowed, false);
  });
  await checkAsync('access allow does not bypass managed network deny', async () => {
    assert.equal(await api.policyDecision('https://example.com/', {
      readRequirements: async () => ({requirements: {network: {deniedDomains: ['example.com']}}}),
      readAll: async () => ({config: {browser_use: {default_origin_policy: {access: 'allow'}}}}),
    }), 'deny');
  });
  await checkAsync('unavailable requirements fail closed even with access allow', async () => {
    assert.equal(await api.policyDecision('https://example.com/', {
      readRequirements: async () => {throw new Error('probe: requirements unavailable');},
      readAll: async () => ({config: {browser_use: {default_origin_policy: {access: 'allow'}}}}),
    }), 'unavailable');
  });
  console.log(JSON.stringify({
    servicePath,
    serviceSha256: crypto.createHash('sha256').update(sourceBytes).digest('hex'),
    testedFunctions: ['navigation', 'parsePattern', 'policy', 'policyDecision'],
    scope: 'Unmodified pure functions extracted from installed browser service; no live browser actions in this test',
    passed: results.length,
    results,
  }, null, 2));
})().catch(error => {console.error(error); process.exitCode = 1;});
