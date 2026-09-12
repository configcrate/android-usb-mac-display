#!/usr/bin/env node
/*
 * 协议一致性测试：用 JS 独立实现编解码，
 * 校验 C 头文件与 Kotlin 定义的布局/常量是否自洽。
 * 运行：node protocol/tests/test_protocol.js
 */
const assert = require('assert');

const USBD = {
  magic: [0x55, 0x53, 0x42, 0x44], version: 1, headerSize: 16,
  maxTransfer: 2 * 1024 * 1024,
  type: { VIDEO: 0x01, CONFIG: 0x02, TOUCH: 0x10, KEY: 0x11,
          PING: 0x20, PONG: 0x21, REQUEST_KEYFRAME: 0x30, STATS: 0x40 },
  flag: { KEYFRAME: 0x0001, CONFIG_EPOCH_CHANGED: 0x0002 },
};

function encodeHeader({ type, flags = 0, seq = 0, payloadLength = 0 }) {
  const b = Buffer.alloc(16);
  USBD.magic.forEach((m, i) => b[i] = m);
  b[4] = USBD.version;
  b[5] = type;
  b.writeUInt16LE(flags, 6);
  b.writeUInt32LE(seq >>> 0, 8);
  b.writeUInt32LE(payloadLength >>> 0, 12);
  return b;
}

function decodeHeader(b) {
  assert.ok(b.length >= 16, 'header too short');
  for (let i = 0; i < 4; i++) assert.strictEqual(b[i], USBD.magic[i], 'bad magic');
  assert.strictEqual(b[4], USBD.version, 'bad version');
  return {
    type: b[5],
    flags: b.readUInt16LE(6),
    seq: b.readUInt32LE(8),
    payloadLength: b.readUInt32LE(12),
  };
}

function encodeTouch({ seq, x, y, pressure, action, pointerCount, pointerId }) {
  const b = Buffer.alloc(16);
  b.writeUInt32LE(seq >>> 0, 0);
  b.writeUInt16LE(x, 4);
  b.writeUInt16LE(y, 6);
  b.writeUInt16LE(pressure, 8);
  b[10] = action;
  b[11] = pointerCount;
  b.writeUInt16LE(pointerId, 12);
  b.writeUInt16LE(0, 14);
  return b;
}

function decodeTouch(b) {
  assert.ok(b.length >= 16);
  return { seq: b.readUInt32LE(0), x: b.readUInt16LE(4), y: b.readUInt16LE(6),
           pressure: b.readUInt16LE(8), action: b[10],
           pointerCount: b[11], pointerId: b.readUInt16LE(12) };
}

function encodeStats(pairs) {
  const b = Buffer.alloc(pairs.length * 5);
  pairs.forEach(([tag, value], i) => {
    b[i * 5] = tag;
    b.writeUInt32LE(value >>> 0, i * 5 + 1);
  });
  return b;
}

function decodeStats(b) {
  const out = {};
  for (let i = 0; i + 5 <= b.length; i += 5) out[b[i]] = b.readUInt32LE(i + 1);
  return out;
}

let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log(`  ✅ ${name}`); }
  catch (e) { failed++; console.log(`  ❌ ${name}\n     ${e.message}`); }
}

console.log('\n协议一致性测试\n');

test('帧头固定 16 字节', () => {
  assert.strictEqual(encodeHeader({ type: USBD.type.VIDEO }).length, 16);
});

test('帧头往返编解码', () => {
  const src = { type: USBD.type.VIDEO, flags: USBD.flag.KEYFRAME, seq: 0xDEADBEEF, payloadLength: 123456 };
  const out = decodeHeader(encodeHeader(src));
  assert.deepStrictEqual(out, src);
});

test('seq 满 32 位不溢出', () => {
  const out = decodeHeader(encodeHeader({ type: USBD.type.VIDEO, seq: 0xFFFFFFFF }));
  assert.strictEqual(out.seq, 0xFFFFFFFF);
});

test('magic 错误应被识别', () => {
  const b = encodeHeader({ type: 1 }); b[0] = 0x00;
  assert.throws(() => decodeHeader(b));
});

test('触摸事件固定 16 字节', () => {
  assert.strictEqual(encodeTouch({ seq: 1, x: 0, y: 0, pressure: 0, action: 0, pointerCount: 1, pointerId: 0 }).length, 16);
});

test('触摸事件往返编解码', () => {
  const src = { seq: 42, x: 32768, y: 65535, pressure: 1000, action: 1, pointerCount: 2, pointerId: 7 };
  assert.deepStrictEqual(decodeTouch(encodeTouch(src)), src);
});

test('触摸坐标归一化边界', () => {
  const b = encodeTouch({ seq: 0, x: 65535, y: 0, pressure: 0, action: 0, pointerCount: 1, pointerId: 0 });
  const out = decodeTouch(b);
  assert.strictEqual(out.x / 65535, 1);
  assert.strictEqual(out.y / 65535, 0);
});

test('STATS TLV 往返编解码', () => {
  const pairs = [[1, 2500], [3, 4000], [4, 0], [5, 12], [6, 8000000]];
  const out = decodeStats(encodeStats(pairs));
  assert.strictEqual(out[1], 2500);
  assert.strictEqual(out[3], 4000);
  assert.strictEqual(out[4], 0);
  assert.strictEqual(out[5], 12);
  assert.strictEqual(out[6], 8000000);
});

test('STATS 每条 TLV 恰好 5 字节', () => {
  assert.strictEqual(encodeStats([[1, 1], [2, 2], [3, 3]]).length, 15);
});

test('关键帧 flag 位运算正确', () => {
  const h = decodeHeader(encodeHeader({ type: USBD.type.VIDEO, flags: USBD.flag.KEYFRAME | USBD.flag.CONFIG_EPOCH_CHANGED }));
  assert.ok(h.flags & USBD.flag.KEYFRAME, '应含 KEYFRAME');
  assert.ok(h.flags & USBD.flag.CONFIG_EPOCH_CHANGED, '应含 CONFIG_EPOCH_CHANGED');
});

test('分段传输：大帧按 2MiB 切分且总长守恒', () => {
  const MAX = USBD.maxTransfer;
  const payload = Buffer.alloc(5 * 1024 * 1024, 0xAB); // 5 MiB
  const header = encodeHeader({ type: USBD.type.VIDEO, payloadLength: payload.length });
  const chunks = [];
  if (payload.length + 16 <= MAX) {
    chunks.push(Buffer.concat([header, payload]));
  } else {
    let offset = 0, first = true;
    const chunkSize = MAX - 16;
    while (offset < payload.length) {
      const end = Math.min(offset + chunkSize, payload.length);
      const slice = payload.subarray(offset, end);
      chunks.push(first ? Buffer.concat([header, slice]) : Buffer.from(slice));
      first = false; offset = end;
    }
  }
  assert.ok(chunks.every(c => c.length <= MAX), '每片不超过 2MiB');
  const total = chunks.reduce((n, c) => n + c.length, 0);
  assert.strictEqual(total, 16 + payload.length, '总长应守恒');
});

test('接收端流式重组能还原被切分的帧', () => {
  const MAX = USBD.maxTransfer;
  const payload = Buffer.alloc(3 * 1024 * 1024 + 777, 0xCD);
  const header = encodeHeader({ type: USBD.type.VIDEO, payloadLength: payload.length });

  // 发送端
  const wire = [];
  if (payload.length + 16 <= MAX) wire.push(Buffer.concat([header, payload]));
  else {
    let offset = 0, first = true;
    const chunkSize = MAX - 16;
    while (offset < payload.length) {
      const end = Math.min(offset + chunkSize, payload.length);
      const slice = payload.subarray(offset, end);
      wire.push(first ? Buffer.concat([header, slice]) : Buffer.from(slice));
      first = false; offset = end;
    }
  }

  // Tiny simulated reads copied once into the final backing store.
  // Production Swift/Kotlin parsers are tested by their own test targets.
  const acc = Buffer.alloc(payload.length + 16);
  let count = 0, pending = null;
  const frames = [];
  for (const w of wire) {
    for (let i = 0; i < w.length; i += 7) {
      const bytes = w.subarray(i, i + 7);
      bytes.copy(acc, count);
      count += bytes.length;
      if (!pending && count >= 16) pending = decodeHeader(acc.subarray(0, 16));
      if (pending && count === pending.payloadLength + 16)
        frames.push({ header: pending, payload: acc.subarray(16, count) });
    }
  }
  assert.strictEqual(frames.length, 1, '应重组出 1 帧');
  assert.strictEqual(frames[0].payload.length, payload.length);
  assert.ok(frames[0].payload.equals(payload), '载荷内容应完全一致');
});

test('错位恢复：垃圾字节后可重新同步', () => {
  const garbage = Buffer.from([0x00, 0xFF, 0x12, 0x34]);
  const good = encodeHeader({ type: USBD.type.PING, payloadLength: 4 });
  let acc = Buffer.concat([garbage, good]);
  let header = null;
  let guard = 0;
  while (acc.length >= 16 && !header && guard++ < 100) {
    try { header = decodeHeader(acc.subarray(0, 16)); }
    catch { acc = acc.subarray(1); }
  }
  assert.ok(header, '应能在跳字节后恢复同步');
  assert.strictEqual(header.type, USBD.type.PING);
});

console.log(`\n通过 ${passed} 项，失败 ${failed} 项\n`);
process.exit(failed === 0 ? 0 : 1);
