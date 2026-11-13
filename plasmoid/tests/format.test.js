const test = require("node:test");
const assert = require("node:assert/strict");
const Format = require("../contents/ui/format.js");

test("truncate keeps short text and adds an ellipsis", () => {
  assert.equal(Format.truncate("abc", 5), "abc");
  assert.equal(Format.truncate("abcdef", 5), "abcd…");
  assert.equal(Format.truncate("", 5), "");
});

test("formatTime renders mm:ss", () => {
  assert.equal(Format.formatTime(0), "0:00");
  assert.equal(Format.formatTime(65000), "1:05");
  assert.equal(Format.formatTime(125000), "2:05");
});

test("qualityLabel maps known values", () => {
  assert.equal(Format.qualityLabel("lossless"), "FLAC");
  assert.equal(Format.qualityLabel("hq"), "AAC 256");
  assert.equal(Format.qualityLabel("nq"), "AAC 192");
  assert.equal(Format.qualityLabel("lq"), "AAC 64");
  assert.equal(Format.qualityLabel("other"), "other");
});

test("qualityNext cycles lossless -> hq -> nq -> lq -> lossless", () => {
  assert.equal(Format.qualityNext("lossless"), "hq");
  assert.equal(Format.qualityNext("hq"), "nq");
  assert.equal(Format.qualityNext("nq"), "lq");
  assert.equal(Format.qualityNext("lq"), "lossless");
  assert.equal(Format.qualityNext("unknown"), "lossless");
});

test("repeatNext cycles off -> all -> one -> off", () => {
  assert.equal(Format.repeatNext("off"), "all");
  assert.equal(Format.repeatNext("all"), "one");
  assert.equal(Format.repeatNext("one"), "off");
});

test("trackLine marks cached and includes the first artist", () => {
  assert.equal(
    Format.trackLine({ title: "Song", artists: ["Artist"], cached: true }),
    "✓ Song · Artist"
  );
  assert.equal(Format.trackLine({ title: "Song", artists: [], cached: false }), "Song");
  assert.equal(Format.trackLine(null), "");
});
