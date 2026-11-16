// Minimal protobuf wire handling for the messages the proxy must not pass
// through verbatim. Reading one varint and re-framing a handful of
// length-delimited fields is cheaper than a codec plus generated descriptors
// in the Worker, but it is still a wire implementation: anything malformed
// throws, and the caller fails closed instead of serving what it could not
// parse.
//
// Field numbers come from Backrest v1.14.1's proto/v1/config.proto and
// service.proto, and the test fixture is a real GetConfig response.

type Field = {
	number: number;
	wire: number;
	// Tag and value exactly as they appeared, so an untouched field is copied
	// byte for byte.
	raw: Uint8Array;
	varint?: bigint;
	payload?: Uint8Array;
};

function readVarint(bytes: Uint8Array, cursor: { at: number }): bigint {
	let shift = 0n;
	let value = 0n;
	for (;;) {
		if (cursor.at >= bytes.length) throw new Error("truncated varint");
		const byte = bytes[cursor.at++];
		value |= BigInt(byte & 0x7f) << shift;
		if ((byte & 0x80) === 0) return value;
		shift += 7n;
		if (shift > 63n) throw new Error("varint is too long");
	}
}

function readFields(bytes: Uint8Array): Field[] {
	const cursor = { at: 0 };
	const fields: Field[] = [];
	while (cursor.at < bytes.length) {
		const start = cursor.at;
		const tag = readVarint(bytes, cursor);
		const number = Number(tag >> 3n);
		const wire = Number(tag & 7n);
		let varint: bigint | undefined;
		let payload: Uint8Array | undefined;
		if (wire === 0) {
			varint = readVarint(bytes, cursor);
		} else if (wire === 1) {
			cursor.at += 8;
		} else if (wire === 2) {
			const length = Number(readVarint(bytes, cursor));
			payload = bytes.subarray(cursor.at, cursor.at + length);
			cursor.at += length;
		} else if (wire === 5) {
			cursor.at += 4;
		} else {
			throw new Error(`unsupported wire type ${wire}`);
		}
		if (cursor.at > bytes.length) throw new Error("truncated field");
		fields.push({ number, wire, raw: bytes.subarray(start, cursor.at), varint, payload });
	}
	return fields;
}

function varintBytes(value: number): number[] {
	const out: number[] = [];
	let rest = value;
	do {
		let byte = rest % 0x80;
		rest = Math.floor(rest / 0x80);
		if (rest > 0) byte |= 0x80;
		out.push(byte);
	} while (rest > 0);
	return out;
}

function lengthDelimited(field: number, payload: Uint8Array): Uint8Array {
	const tag = varintBytes((field << 3) | 2);
	const length = varintBytes(payload.length);
	const out = new Uint8Array(tag.length + length.length + payload.length);
	out.set(tag, 0);
	out.set(length, tag.length);
	out.set(payload, tag.length + length.length);
	return out;
}

function concat(parts: Uint8Array[]): Uint8Array {
	const total = parts.reduce((sum, part) => sum + part.length, 0);
	const out = new Uint8Array(total);
	let at = 0;
	for (const part of parts) {
		out.set(part, at);
		at += part.length;
	}
	return out;
}

// GetDownloadURLRequest.op_id is int64 field 1, and protobuf JSON renders it as
// a decimal string, so this returns the same text isVerified() already compares.
export function readUint64Field(bytes: Uint8Array, wanted: number): string | undefined {
	try {
		for (const field of readFields(bytes)) {
			if (field.number === wanted && field.varint !== undefined) {
				return BigInt.asUintN(64, field.varint).toString();
			}
		}
	} catch {
		return undefined;
	}
	return undefined;
}

// Config.repos = 3, Repo.password = 3, Repo.env = 4. Backrest's own
// SanitizeForNetwork keeps both, and the Web UI asks in protobuf, so the
// credentials are only removed if they are removed here.
export function redactConfigProto(bytes: Uint8Array): Uint8Array {
	const parts = readFields(bytes).map((field) => {
		if (field.number !== 3 || field.wire !== 2 || field.payload === undefined) {
			return field.raw;
		}
		const repo = readFields(field.payload)
			.filter((inner) => inner.number !== 3 && inner.number !== 4)
			.map((inner) => inner.raw);
		return lengthDelimited(3, concat(repo));
	});
	return concat(parts);
}
