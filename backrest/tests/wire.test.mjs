import assert from "node:assert/strict";
import { test } from "node:test";

import { readUint64Field, redactConfigProto } from "../src/wire.ts";

// A real GetConfig response from the pinned Backrest v1.14.1 image, requested
// with Content-Type: application/proto, whose repo carries the restic password
// and the R2 key pair. Regenerate it by POSTing an empty body with that content
// type to /v1.Backrest/GetConfig on the container.
const CONFIG = Buffer.from(
  "1204746573741a8b020a027232123773333a68747470733a2f2f6578616d706c652e72322e636c6f7564666c61726573" +
    "746f726167652e636f6d2f6275636b65742f706174681a13535550455253454352455450415353574f5244221d415753" +
    "5f4143434553535f4b45595f49443d414b49414558414d504c4522174157535f44454641554c545f524547494f4e3d61" +
    "75746f22264157535f5345435245545f4143434553535f4b45593d5345435245544b45594558414d504c452a092d2d6e" +
    "6f2d6c6f636b2a0a2d2d6e6f2d63616368655a4030313233343536373839616263646566303132333435363738396162" +
    "6364656630313233343536373839616263646566303132333435363738396162636465662a02080130063a370a350a33" +
    "656432353531392e5f58464c76526e57744c66376c653978437a584e6d61647a5f46475133532d683546346170666452" +
    "777838",
  "hex",
);

const latin1 = (bytes) => Buffer.from(bytes).toString("latin1");

test("protobuf GetConfig loses the repository password and R2 credentials", () => {
  const redacted = redactConfigProto(new Uint8Array(CONFIG));
  const text = latin1(redacted);

  assert.ok(!text.includes("SUPERSECRETPASSWORD"), "password survived redaction");
  assert.ok(!text.includes("AWS_ACCESS_KEY_ID"), "access key id survived redaction");
  assert.ok(!text.includes("AWS_SECRET_ACCESS_KEY"), "secret key survived redaction");
});

test("protobuf GetConfig keeps every other field", () => {
  const text = latin1(redactConfigProto(new Uint8Array(CONFIG)));

  assert.ok(text.includes("test"), "instance");
  assert.ok(text.includes("s3:https://example.r2.cloudflarestorage.com/bucket/path"), "uri");
  assert.ok(text.includes("--no-lock"), "flags");
  assert.ok(text.includes("0123456789abcdef"), "guid");
  assert.ok(text.includes("ed25519._XFLvRnWtLf7le9xCzXNmadz_FGQ3S-h5F4apfdRwx8"), "sync key");
  // 339-byte fixture; dropping the two credential fields must shrink it.
  assert.ok(redactConfigProto(new Uint8Array(CONFIG)).length < CONFIG.length);
});

test("protobuf GetConfig redaction is idempotent", () => {
  const once = redactConfigProto(new Uint8Array(CONFIG));
  assert.deepEqual(Buffer.from(redactConfigProto(once)), Buffer.from(once));
});

test("readUint64Field keeps full int64 precision for op_id", () => {
  const varint = (value) => {
    const out = [];
    let rest = value;
    do {
      let byte = Number(rest & 0x7fn);
      rest >>= 7n;
      if (rest > 0n) byte |= 0x80;
      out.push(byte);
    } while (rest > 0n);
    return out;
  };
  const opId = 1763361234567890123n;
  // op_id = field 1 varint, then file_path = field 2 string, to prove skipping.
  const body = Uint8Array.from([...varint(1n << 3n), ...varint(opId), 0x12, 0x01, 0x2f]);

  assert.equal(readUint64Field(body, 1), opId.toString());
  assert.equal(readUint64Field(body, 2), undefined);
  assert.equal(readUint64Field(new Uint8Array(), 1), undefined);
  assert.equal(readUint64Field(Uint8Array.from([0x08, 0x80]), 1), undefined);
  assert.equal(readUint64Field(new TextEncoder().encode("{}"), 1), undefined);
});
