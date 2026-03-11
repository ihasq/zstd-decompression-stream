#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
TMPDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  if [ -n "${2:-}" ]; then
    echo "        $2"
  fi
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label" "expected=$(echo "$expected" | head -c 200) actual=$(echo "$actual" | head -c 200)"
  fi
}

# ============================================================
# Generate test fixtures with zstd CLI
# ============================================================
echo "=== Generating test fixtures ==="

# 1. Simple short text
echo -n "Hello, World!" > "$TMPDIR/short.txt"
zstd -f "$TMPDIR/short.txt" -o "$TMPDIR/short.txt.zst"

# 2. Empty file
: > "$TMPDIR/empty.txt"
zstd -f "$TMPDIR/empty.txt" -o "$TMPDIR/empty.txt.zst"

# 3. Larger text (repeated pattern)
python3 -c "print('abcdefghij' * 10000, end='')" > "$TMPDIR/large.txt"
zstd -f "$TMPDIR/large.txt" -o "$TMPDIR/large.txt.zst"

# 4. Binary data
dd if=/dev/urandom of="$TMPDIR/binary.bin" bs=1024 count=64 2>/dev/null
zstd -f "$TMPDIR/binary.bin" -o "$TMPDIR/binary.bin.zst"

# 5. Multi-line text with unicode
cat > "$TMPDIR/unicode.txt" << 'HEREDOC'
こんにちは世界
Hello World
Привет мир
🎉🚀✨
HEREDOC
zstd -f "$TMPDIR/unicode.txt" -o "$TMPDIR/unicode.txt.zst"

# 6. Single byte
echo -n "X" > "$TMPDIR/single.txt"
zstd -f "$TMPDIR/single.txt" -o "$TMPDIR/single.txt.zst"

# 7. High compression level
python3 -c "print('A' * 100000, end='')" > "$TMPDIR/repetitive.txt"
zstd -f -19 "$TMPDIR/repetitive.txt" -o "$TMPDIR/repetitive.txt.zst"

# 8. Low compression level
zstd -f -1 "$TMPDIR/large.txt" -o "$TMPDIR/large_fast.txt.zst"

echo "=== Fixtures generated ==="
echo ""

# ============================================================
# Run Node.js tests
# ============================================================
echo "=== Running tests ==="

node --input-type=module << TESTSCRIPT
import { ZstdDecompressionStream } from "./src/mod.js";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

const TMPDIR = "$TMPDIR";
let pass = 0;
let fail = 0;

function log_pass(label) {
  pass++;
  console.log("  PASS: " + label);
}

function log_fail(label, detail) {
  fail++;
  console.log("  FAIL: " + label);
  if (detail) console.log("        " + detail);
}

function md5(buf) {
  return createHash("md5").update(buf).digest("hex");
}

async function decompress(zstdData) {
  const stream = new ZstdDecompressionStream();
  const reader = stream.readable.getReader();
  const writer = stream.writable.getWriter();

  const writePromise = (async () => {
    await writer.write(zstdData);
    await writer.close();
  })();

  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }

  await writePromise;

  const totalLen = chunks.reduce((s, c) => s + c.length, 0);
  const result = new Uint8Array(totalLen);
  let offset = 0;
  for (const c of chunks) {
    result.set(c, offset);
    offset += c.length;
  }
  return result;
}

async function decompressChunked(zstdData, chunkSize) {
  const stream = new ZstdDecompressionStream();
  const reader = stream.readable.getReader();
  const writer = stream.writable.getWriter();

  const writePromise = (async () => {
    for (let i = 0; i < zstdData.length; i += chunkSize) {
      const end = Math.min(i + chunkSize, zstdData.length);
      await writer.write(zstdData.slice(i, end));
    }
    await writer.close();
  })();

  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }

  await writePromise;

  const totalLen = chunks.reduce((s, c) => s + c.length, 0);
  const result = new Uint8Array(totalLen);
  let offset = 0;
  for (const c of chunks) {
    result.set(c, offset);
    offset += c.length;
  }
  return result;
}

// ---- Test 1: Short text ----
try {
  const compressed = readFileSync(TMPDIR + "/short.txt.zst");
  const result = await decompress(new Uint8Array(compressed));
  const text = new TextDecoder().decode(result);
  if (text === "Hello, World!") {
    log_pass("Short text decompression");
  } else {
    log_fail("Short text decompression", "got: " + text);
  }
} catch (e) {
  log_fail("Short text decompression", e.message);
}

// ---- Test 2: Empty file ----
try {
  const compressed = readFileSync(TMPDIR + "/empty.txt.zst");
  const result = await decompress(new Uint8Array(compressed));
  if (result.length === 0) {
    log_pass("Empty file decompression");
  } else {
    log_fail("Empty file decompression", "expected 0 bytes, got " + result.length);
  }
} catch (e) {
  log_fail("Empty file decompression", e.message);
}

// ---- Test 3: Large text ----
try {
  const compressed = readFileSync(TMPDIR + "/large.txt.zst");
  const original = readFileSync(TMPDIR + "/large.txt");
  const result = await decompress(new Uint8Array(compressed));
  if (md5(result) === md5(original)) {
    log_pass("Large text decompression (100KB)");
  } else {
    log_fail("Large text decompression (100KB)", "MD5 mismatch");
  }
} catch (e) {
  log_fail("Large text decompression (100KB)", e.message);
}

// ---- Test 4: Binary data ----
try {
  const compressed = readFileSync(TMPDIR + "/binary.bin.zst");
  const original = readFileSync(TMPDIR + "/binary.bin");
  const result = await decompress(new Uint8Array(compressed));
  if (md5(result) === md5(original)) {
    log_pass("Binary data decompression (64KB)");
  } else {
    log_fail("Binary data decompression (64KB)", "MD5 mismatch");
  }
} catch (e) {
  log_fail("Binary data decompression (64KB)", e.message);
}

// ---- Test 5: Unicode text ----
try {
  const compressed = readFileSync(TMPDIR + "/unicode.txt.zst");
  const original = readFileSync(TMPDIR + "/unicode.txt", "utf-8");
  const result = await decompress(new Uint8Array(compressed));
  const text = new TextDecoder().decode(result);
  if (text === original) {
    log_pass("Unicode text decompression");
  } else {
    log_fail("Unicode text decompression", "content mismatch");
  }
} catch (e) {
  log_fail("Unicode text decompression", e.message);
}

// ---- Test 6: Single byte ----
try {
  const compressed = readFileSync(TMPDIR + "/single.txt.zst");
  const result = await decompress(new Uint8Array(compressed));
  const text = new TextDecoder().decode(result);
  if (text === "X") {
    log_pass("Single byte decompression");
  } else {
    log_fail("Single byte decompression", "got: " + text);
  }
} catch (e) {
  log_fail("Single byte decompression", e.message);
}

// ---- Test 7: High compression level ----
try {
  const compressed = readFileSync(TMPDIR + "/repetitive.txt.zst");
  const original = readFileSync(TMPDIR + "/repetitive.txt");
  const result = await decompress(new Uint8Array(compressed));
  if (md5(result) === md5(original)) {
    log_pass("High compression level (-19) decompression");
  } else {
    log_fail("High compression level (-19) decompression", "MD5 mismatch");
  }
} catch (e) {
  log_fail("High compression level (-19) decompression", e.message);
}

// ---- Test 8: Low compression level ----
try {
  const compressed = readFileSync(TMPDIR + "/large_fast.txt.zst");
  const original = readFileSync(TMPDIR + "/large.txt");
  const result = await decompress(new Uint8Array(compressed));
  if (md5(result) === md5(original)) {
    log_pass("Low compression level (-1) decompression");
  } else {
    log_fail("Low compression level (-1) decompression", "MD5 mismatch");
  }
} catch (e) {
  log_fail("Low compression level (-1) decompression", e.message);
}

// ---- Test 9: Chunked input (simulate streaming, 16-byte chunks) ----
try {
  const compressed = readFileSync(TMPDIR + "/large.txt.zst");
  const original = readFileSync(TMPDIR + "/large.txt");
  const result = await decompressChunked(new Uint8Array(compressed), 16);
  if (md5(result) === md5(original)) {
    log_pass("Chunked input (16-byte chunks)");
  } else {
    log_fail("Chunked input (16-byte chunks)", "MD5 mismatch");
  }
} catch (e) {
  log_fail("Chunked input (16-byte chunks)", e.message);
}

// ---- Test 10: Chunked input (1-byte chunks) ----
try {
  const compressed = readFileSync(TMPDIR + "/short.txt.zst");
  const original = "Hello, World!";
  const result = await decompressChunked(new Uint8Array(compressed), 1);
  const text = new TextDecoder().decode(result);
  if (text === original) {
    log_pass("Chunked input (1-byte chunks)");
  } else {
    log_fail("Chunked input (1-byte chunks)", "got: " + text);
  }
} catch (e) {
  log_fail("Chunked input (1-byte chunks)", e.message);
}

// ---- Test 11: Chunked input (large chunks) ----
try {
  const compressed = readFileSync(TMPDIR + "/binary.bin.zst");
  const original = readFileSync(TMPDIR + "/binary.bin");
  const result = await decompressChunked(new Uint8Array(compressed), 4096);
  if (md5(result) === md5(original)) {
    log_pass("Chunked input (4096-byte chunks)");
  } else {
    log_fail("Chunked input (4096-byte chunks)", "MD5 mismatch");
  }
} catch (e) {
  log_fail("Chunked input (4096-byte chunks)", e.message);
}

// ---- Test 12: ArrayBuffer input ----
try {
  const compressed = readFileSync(TMPDIR + "/short.txt.zst");
  const stream = new ZstdDecompressionStream();
  const reader = stream.readable.getReader();
  const writer = stream.writable.getWriter();

  const buf = new Uint8Array(compressed);
  const arrayBuffer = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);

  const writePromise = (async () => {
    await writer.write(arrayBuffer);
    await writer.close();
  })();

  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  await writePromise;

  const totalLen = chunks.reduce((s, c) => s + c.length, 0);
  const result = new Uint8Array(totalLen);
  let offset = 0;
  for (const c of chunks) {
    result.set(c, offset);
    offset += c.length;
  }
  const text = new TextDecoder().decode(result);
  if (text === "Hello, World!") {
    log_pass("ArrayBuffer input");
  } else {
    log_fail("ArrayBuffer input", "got: " + text);
  }
} catch (e) {
  log_fail("ArrayBuffer input", e.message);
}

// ---- Test 13: TypedArray (Uint16Array view) input ----
try {
  const compressed = readFileSync(TMPDIR + "/short.txt.zst");
  const u8 = new Uint8Array(compressed);
  // Create a properly aligned copy for Uint16Array
  const evenLen = u8.length - (u8.length % 2);
  const alignedBuf = new ArrayBuffer(evenLen);
  new Uint8Array(alignedBuf).set(u8.slice(0, evenLen));
  const u16 = new Uint16Array(alignedBuf);

  const stream = new ZstdDecompressionStream();
  const reader = stream.readable.getReader();
  const writer = stream.writable.getWriter();

  const writePromise = (async () => {
    await writer.write(u16);
    await writer.close();
  })();

  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  await writePromise;

  // If we get here without error, TypedArray handling works
  log_pass("TypedArray (Uint16Array) input accepted");
} catch (e) {
  log_fail("TypedArray (Uint16Array) input accepted", e.message);
}

// ---- Test 14: Multiple independent streams ----
try {
  const compressed1 = readFileSync(TMPDIR + "/short.txt.zst");
  const compressed2 = readFileSync(TMPDIR + "/unicode.txt.zst");
  const original2 = readFileSync(TMPDIR + "/unicode.txt", "utf-8");

  const [result1, result2] = await Promise.all([
    decompress(new Uint8Array(compressed1)),
    decompress(new Uint8Array(compressed2)),
  ]);

  const text1 = new TextDecoder().decode(result1);
  const text2 = new TextDecoder().decode(result2);

  if (text1 === "Hello, World!" && text2 === original2) {
    log_pass("Multiple independent streams in parallel");
  } else {
    log_fail("Multiple independent streams in parallel", "content mismatch");
  }
} catch (e) {
  log_fail("Multiple independent streams in parallel", e.message);
}

// ---- Test 15: Stream is a TransformStream ----
try {
  const stream = new ZstdDecompressionStream();
  if (
    stream instanceof TransformStream &&
    stream.readable instanceof ReadableStream &&
    stream.writable instanceof WritableStream
  ) {
    log_pass("Instance is TransformStream with readable/writable");
  } else {
    log_fail("Instance is TransformStream with readable/writable", "type check failed");
  }
} catch (e) {
  log_fail("Instance is TransformStream with readable/writable", e.message);
}

// ---- Test 16: pipeThrough pattern ----
try {
  const compressed = readFileSync(TMPDIR + "/short.txt.zst");
  const inputStream = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(compressed));
      controller.close();
    }
  });

  const decompressedStream = inputStream.pipeThrough(new ZstdDecompressionStream());
  const reader = decompressedStream.getReader();
  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }

  const totalLen = chunks.reduce((s, c) => s + c.length, 0);
  const result = new Uint8Array(totalLen);
  let offset = 0;
  for (const c of chunks) {
    result.set(c, offset);
    offset += c.length;
  }
  const text = new TextDecoder().decode(result);
  if (text === "Hello, World!") {
    log_pass("pipeThrough pattern");
  } else {
    log_fail("pipeThrough pattern", "got: " + text);
  }
} catch (e) {
  log_fail("pipeThrough pattern", e.message);
}

// ---- Test 17: Verify decompression output size matches original ----
try {
  const compressed = readFileSync(TMPDIR + "/repetitive.txt.zst");
  const original = readFileSync(TMPDIR + "/repetitive.txt");
  const result = await decompress(new Uint8Array(compressed));
  if (result.length === original.length) {
    log_pass("Output size matches original (" + original.length + " bytes)");
  } else {
    log_fail("Output size matches original", "expected " + original.length + " got " + result.length);
  }
} catch (e) {
  log_fail("Output size matches original", e.message);
}

// ---- Test 18: Stream can be used with Response-like pattern ----
try {
  const compressed = readFileSync(TMPDIR + "/short.txt.zst");

  const response = new Response(new Blob([compressed]));
  const decompressedStream = response.body.pipeThrough(new ZstdDecompressionStream());
  const reader = decompressedStream.getReader();
  const chunks = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }

  const totalLen = chunks.reduce((s, c) => s + c.length, 0);
  const result = new Uint8Array(totalLen);
  let offset = 0;
  for (const c of chunks) {
    result.set(c, offset);
    offset += c.length;
  }
  const text = new TextDecoder().decode(result);
  if (text === "Hello, World!") {
    log_pass("Response.body.pipeThrough pattern");
  } else {
    log_fail("Response.body.pipeThrough pattern", "got: " + text);
  }
} catch (e) {
  log_fail("Response.body.pipeThrough pattern", e.message);
}

// ---- Summary ----
console.log("");
console.log("=== Results: " + pass + " passed, " + fail + " failed, " + (pass + fail) + " total ===");

if (fail > 0) {
  process.exit(1);
}
TESTSCRIPT

echo ""
echo "=== All tests completed ==="
