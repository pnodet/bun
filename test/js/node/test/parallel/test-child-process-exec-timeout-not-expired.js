'use strict';

// Test exec() when a timeout is set, but not expired.

const common = require('../common');
const assert = require('assert');
const cp = require('child_process');

const {
  cleanupStaleProcess,
  logAfterTime
} = require('../common/child_process');

const kTimeoutNotSupposedToExpire = 2 ** 30;
const childRunTime = common.platformTimeout(100);

// The time spent in the child should be smaller than the timeout below.
assert(childRunTime < kTimeoutNotSupposedToExpire);

if (process.argv[2] === 'child') {
  logAfterTime(childRunTime);
  return;
}

const cmd = `"${process.execPath}" "${__filename}" child`;

cp.exec(cmd, {
  timeout: kTimeoutNotSupposedToExpire
}, common.mustSucceed((stdout, stderr) => {
  assert.strict(stdout.trim().includes('child stdout'));
  assert.strict(stderr.trim().includes('child stderr'));
}));

cleanupStaleProcess(__filename);
