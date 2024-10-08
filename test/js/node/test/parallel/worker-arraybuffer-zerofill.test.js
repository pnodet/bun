//#FILE: test-worker-arraybuffer-zerofill.js
//#SHA1: 3fd8cc412e658cb491c61d2323ff3a45af4d6dd1
//-----------------
"use strict";

const { Worker } = require("worker_threads");

// Make sure that allocating uninitialized ArrayBuffers in one thread does not
// affect the zero-initialization in other threads.

test("zero-initialization in other threads", done => {
  const w = new Worker(
    `
  const { parentPort } = require('worker_threads');

  function post() {
    const uint32array = new Uint32Array(64);
    parentPort.postMessage(uint32array.reduce((a, b) => a + b));
  }

  setInterval(post, 0);
  `,
    { eval: true },
  );

  function allocBuffers() {
    Buffer.allocUnsafe(32 * 1024 * 1024);
  }

  const interval = setInterval(allocBuffers, 0);

  let messages = 0;
  w.on("message", sum => {
    expect(sum).toBe(0);
    if (messages++ === 100) {
      clearInterval(interval);
      w.terminate();
      done();
    }
  });
});

//<#END_FILE: test-worker-arraybuffer-zerofill.js
