#!/usr/bin/env node
/*
 * 跨语言协议常量一致性检查。
 *
 * 协议定义散落在三个文件里，这是真实的维护风险：
 *   protocol/frame.h                                  (C，权威定义)
 *   macos/Sources/USBDisplayCore/FrameProtocol.swift  (Swift)
 *   android/.../transport/FrameProtocol.kt            (Kotlin)
 * 任何一处改了常量而另一处没改，就会出现"能编译、能跑、但连不通"的玄学 bug。
 * 本脚本在 CI 中卡住这种不一致。
 *
 * 三端命名风格不同（C 用 USBD_TYPE_VIDEO / Swift 用 typeVideo / Kotlin 用 TYPE_VIDEO），
 * 因此统一归一化：去掉前缀与下划线，转大写后比较。
 *
 * 运行：node protocol/tests/check_consistency.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');

function read(rel) {
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) {
    console.error(`❌ 文件不存在: ${rel}`);
    process.exit(2);
  }
  return fs.readFileSync(p, 'utf8');
}

/** 归一化标识符：去掉前缀/下划线，统一大写。VIDEO == _video == typeVideo */
function norm(name, ...prefixes) {
  let n = name;
  for (const p of prefixes) {
    if (!p) continue; // 空前缀表示不裁剪
    const re = new RegExp(`^${p}_?`, 'i');
    n = n.replace(re, '');
  }
  return n.replace(/_/g, '').toUpperCase();
}

/** 从 C 提取：enum 成员（无显式值则按顺序累加）与 #define */
function parseC(src) {
  const out = {};

  // enum usbd_frame_type { USBD_TYPE_VIDEO = 0x01, ... };
  const enumRe = /enum\s+\w+\s*\{([^}]*)\}/g;
  let em;
  while ((em = enumRe.exec(src))) {
    let counter = 0;
    for (const raw of em[1].split(',')) {
      const line = raw.replace(/\/\/.*/, '').trim();
      if (!line) continue;
      const m = /^(\w+)\s*(?:=\s*(0x[0-9a-fA-F]+|\d+))?/.exec(line);
      if (!m) continue;
      const value = m[2] !== undefined
        ? parseInt(m[2], m[2].startsWith('0x') ? 16 : 10)
        : counter;
      out[m[1]] = value;
      counter = value + 1;
    }
  }

  // #define
  const defRe = /#define\s+(\w+)\s+(0x[0-9a-fA-F]+|[0-9]+)(?:u|U|UL|L)?\s*$/gm;
  let dm;
  while ((dm = defRe.exec(src))) {
    out[dm[1]] = parseInt(dm[2], dm[2].startsWith('0x') ? 16 : 10);
  }

  return out;
}

/** 从 Swift 提取 `static let name: Type = 0xNN` 与 enum `case name = 0xNN` */
function parseSwift(src) {
  const out = {};
  const letRe = /(?:static\s+)?let\s+(\w+)\s*(?::\s*\w+)?\s*=\s*(0x[0-9a-fA-F]+|\d+)/g;
  let m;
  while ((m = letRe.exec(src))) {
    out[m[1]] = parseInt(m[2], m[2].startsWith('0x') ? 16 : 10);
  }
  // 支持 `case down = 0` 与 `case down = 0, move = 1` 两种写法
  const caseRe = /(?:case\s+|,\s*)(\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+)/g;
  while ((m = caseRe.exec(src))) {
    out[m[1]] = parseInt(m[2], m[2].startsWith('0x') ? 16 : 10);
  }
  return out;
}

/** 从 Kotlin 提取 `const val NAME: Type = 0xNN` 与 enum `NAME(0xNN)` */
function parseKotlin(src) {
  const out = {};
  const constRe = /const\s+val\s+(\w+)\s*(?::\s*\w+)?\s*=\s*(0x[0-9a-fA-F]+|\d+)/g;
  let m;
  while ((m = constRe.exec(src))) {
    out[m[1]] = parseInt(m[2], m[2].startsWith('0x') ? 16 : 10);
  }
  // 枚举成员：可同行多个，如 `DOWN(0), MOVE(1), UP(2), CANCEL(3);`
  // 限定在 enum class 块内、且排除 fun/val 声明，避免把 `value == b` 之类误抓
  const enumBodyRe = /enum\s+class\s+\w+[^{]*\{([^}]*)\}/g;
  let eb;
  while ((eb = enumBodyRe.exec(src))) {
    const body = eb[1].split(';')[0]; // 分号前是成员区
    const memRe = /(\w+)\s*\(\s*(0x[0-9a-fA-F]+|\d+)\s*\)/g;
    let mm;
    while ((mm = memRe.exec(body))) {
      out[mm[1]] = parseInt(mm[2], mm[2].startsWith('0x') ? 16 : 10);
    }
  }
  return out;
}

let failures = 0;
let passes = 0;

/** 从 C 源码中截取某个 enum 块 */
function cEnum(src, name) {
  const re = new RegExp(`enum\\s+${name}\\s*\\{([^}]*)\\}`, 'g');
  const m = re.exec(src);
  if (!m) return {};
  const out = {};
  let counter = 0;
  for (const raw of m[1].split(',')) {
    const line = raw.replace(/\/\/.*/, '').trim();
    if (!line) continue;
    const mm = /^(\w+)\s*(?:=\s*(0x[0-9a-fA-F]+|\d+))?/.exec(line);
    if (!mm) continue;
    const value = mm[2] !== undefined
      ? parseInt(mm[2], mm[2].startsWith('0x') ? 16 : 10)
      : counter;
    out[norm(mm[1])] = value;
    counter = value + 1;
  }
  return out;
}

/** 从 C 源码中取一组 #define，按名称前缀筛选 */
function cDefines(src, prefix) {
  const out = {};
  const re = new RegExp(`#define\\s+(${prefix}\\w*)\\s+(0x[0-9a-fA-F]+|\\d+)(?:u|U|UL|L)?\\s*$`, 'gm');
  let m;
  while ((m = re.exec(src))) {
    out[norm(m[1], prefix)] = parseInt(m[2], m[2].startsWith('0x') ? 16 : 10);
  }
  return out;
}

/** 从 Swift 中取某个 enum 块的 case */
function swiftEnum(src, name) {
  const idx = src.indexOf(`enum ${name}`);
  if (idx < 0) return {};
  const block = src.slice(idx);
  const body = block.slice(block.indexOf('{') + 1, block.indexOf('}'));
  const out = {};
  const re = /(?:case\s+|,\s*)(\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+)/g;
  let m;
  while ((m = re.exec(body))) {
    out[norm(m[1])] = parseInt(m[2], m[2].startsWith('0x') ? 16 : 10);
  }
  return out;
}

/** 从 Swift 中取 object 块的 static let，按名称前缀筛选 */
function swiftStatics(src, objectName, prefix) {
  const idx = src.indexOf(`enum ${objectName}`);
  if (idx < 0) return {};
  const block = src.slice(idx);
  const body = block.slice(block.indexOf('{') + 1, block.indexOf('\n}'));
  const out = {};
  const re = /static\s+let\s+(\w+)\s*(?::\s*\w+)?\s*=\s*(0x[0-9a-fA-F]+|\d+)/g;
  let m;
  while ((m = re.exec(body))) {
    if (prefix && !new RegExp(`^${prefix}`, 'i').test(m[1])) continue;
    out[norm(m[1], prefix)] = parseInt(m[2], m[2].startsWith('0x') ? 16 : 10);
  }
  return out;
}

/** 从 Kotlin 中取某个 enum class 的成员 */
function kotlinEnum(src, name) {
  const idx = src.indexOf(`enum class ${name}`);
  if (idx < 0) return {};
  const block = src.slice(idx);
  const body = block.slice(block.indexOf('{') + 1, block.indexOf('}')).split(';')[0];
  const out = {};
  const re = /(\w+)\s*\(\s*(0x[0-9a-fA-F]+|\d+)\s*\)/g;
  let m;
  while ((m = re.exec(body))) {
    out[norm(m[1])] = parseInt(m[2], m[2].startsWith('0x') ? 16 : 10);
  }
  return out;
}

/** 从 Kotlin 中取 object 块的 const val，按名称前缀筛选 */
function kotlinConsts(src, objectName, prefix) {
  const idx = src.indexOf(`object ${objectName}`);
  if (idx < 0) return {};
  const block = src.slice(idx);
  // object 体到下一个顶层 `}`；用 `\n}` 近似
  const endIdx = block.indexOf('\n}');
  const body = block.slice(block.indexOf('{') + 1, endIdx > 0 ? endIdx : block.length);
  const out = {};
  const re = /const\s+val\s+(\w+)\s*(?::\s*\w+)?\s*=\s*(0x[0-9a-fA-F]+|\d+)/g;
  let m;
  while ((m = re.exec(body))) {
    if (prefix && !new RegExp(`^${prefix}`, 'i').test(m[1])) continue;
    out[norm(m[1], prefix)] = parseInt(m[2], m[2].startsWith('0x') ? 16 : 10);
  }
  return out;
}

function compareMaps(label, cm, sm, km) {
  const keys = [...new Set([...Object.keys(cm), ...Object.keys(sm), ...Object.keys(km)])].sort();
  if (!keys.length) {
    console.log(`  ⚠️  ${label}: 未解析到任何常量，请检查解析器`);
    failures++;
    return;
  }
  let bad = 0;
  for (const k of keys) {
    const cv = cm[k], sv = sm[k], kv = km[k];
    const missing = [];
    if (cv === undefined) missing.push('C');
    if (sv === undefined) missing.push('Swift');
    if (kv === undefined) missing.push('Kotlin');
    if (missing.length) {
      console.log(`  ❌ ${label}.${k}: 缺少 ${missing.join('/')} 定义`);
      bad++; failures++;
    } else if (cv !== sv || cv !== kv) {
      console.log(`  ❌ ${label}.${k}: C=${cv} Swift=${sv} Kotlin=${kv}`);
      bad++; failures++;
    }
  }
  if (!bad) {
    console.log(`  ✅ ${label}: ${keys.length} 项一致 (${keys.join(', ')})`);
    passes += keys.length;
  }
}

function compareValue(label, cVal, sVal, kVal) {
  if (cVal === undefined || sVal === undefined || kVal === undefined) {
    console.log(`  ❌ ${label}: C=${cVal} Swift=${sVal} Kotlin=${kVal}（某项缺失）`);
    failures++;
    return;
  }
  if (cVal === sVal && cVal === kVal) {
    console.log(`  ✅ ${label} = ${cVal}`);
    passes++;
  } else {
    console.log(`  ❌ ${label}: C=${cVal} Swift=${sVal} Kotlin=${kVal}`);
    failures++;
  }
}

console.log('\n跨语言协议常量一致性检查\n');

const cSrc = read('protocol/frame.h');
const swiftSrc = read('macos/Sources/USBDisplayCore/FrameProtocol.swift');
const kotlinSrc = read('android/app/src/main/java/dev/configcrate/usbdisplay/transport/FrameProtocol.kt');

// --- 帧类型 ---
// C: enum usbd_frame_type { USBD_TYPE_VIDEO = 0x01, ... }
// Swift: enum USBD { static let typeVideo: UInt8 = 0x01 }
// Kotlin: object USBD { const val TYPE_VIDEO: Byte = 0x01 }
// C 侧枚举成员带 USBD_TYPE_ 前缀，需裁掉后才能和 Swift(typeVideo)/Kotlin(TYPE_VIDEO) 对齐
const cFrameTypes = {};
for (const [k, v] of Object.entries(cEnum(cSrc, 'usbd_frame_type'))) {
  cFrameTypes[norm(k, 'USBDTYPE')] = v;
}
compareMaps(
  'frame.type',
  cFrameTypes,
  swiftStatics(swiftSrc, 'USBD', 'type'),
  kotlinConsts(kotlinSrc, 'USBD', 'TYPE_'),
);

// --- flags ---
compareMaps(
  'frame.flag',
  cDefines(cSrc, 'USBD_FLAG_'),
  swiftStatics(swiftSrc, 'USBD', 'flag'),
  kotlinConsts(kotlinSrc, 'USBD', 'FLAG_'),
);

// --- 触摸动作 ---
// C: enum usbd_touch_action { USBD_TOUCH_DOWN = 0, ... }（前缀需裁掉）
// Swift / Kotlin: enum TouchAction { DOWN = 0 / DOWN(0) }
{
  const cTouch = {};
  for (const [k, v] of Object.entries(cEnum(cSrc, 'usbd_touch_action'))) {
    cTouch[norm(k, 'USBDTOUCH')] = v;
  }
  compareMaps('touch.action', cTouch, swiftEnum(swiftSrc, 'TouchAction'), kotlinEnum(kotlinSrc, 'TouchAction'));
}

// --- 关键尺寸常量 ---
console.log('');
compareValue(
  'HEADER_SIZE',
  (() => { const m = /#define\s+USBD_HEADER_SIZE\s+(\d+)/.exec(cSrc); return m ? +m[1] : undefined; })(),
  (() => { const m = /headerSize\s*=\s*(\d+)/.exec(swiftSrc); return m ? +m[1] : undefined; })(),
  (() => { const m = /HEADER_SIZE\s*=\s*(\d+)/.exec(kotlinSrc); return m ? +m[1] : undefined; })(),
);

compareValue(
  'VERSION',
  (() => { const m = /#define\s+USBD_VERSION\s+(\d+)/.exec(cSrc); return m ? +m[1] : undefined; })(),
  (() => { const m = /version\s*:\s*UInt8\s*=\s*(\d+)/.exec(swiftSrc); return m ? +m[1] : undefined; })(),
  (() => { const m = /VERSION\s*:\s*Byte\s*=\s*(\d+)/.exec(kotlinSrc); return m ? +m[1] : undefined; })(),
);

compareValue(
  'MAX_TRANSFER',
  (() => {
    const m = /#define\s+USBD_MAX_TRANSFER\s+\(([^)]*)\)/.exec(cSrc);
    return m ? m[1].split('*').reduce((a, t) => a * parseInt(t.trim(), 10), 1) : undefined;
  })(),
  (() => {
    const m = /maxTransfer\s*=\s*(\d+)\s*\*\s*(\d+)\s*\*\s*(\d+)/.exec(swiftSrc);
    return m ? +m[1] * +m[2] * +m[3] : undefined;
  })(),
  (() => {
    const m = /MAX_TRANSFER\s*=\s*(\d+)\s*\*\s*(\d+)\s*\*\s*(\d+)/.exec(kotlinSrc);
    return m ? +m[1] * +m[2] * +m[3] : undefined;
  })(),
);

console.log(failures === 0
  ? `\n✅ 三端协议定义一致（${passes} 项检查通过）\n`
  : `\n❌ 发现 ${failures} 处不一致，请修正后重试\n`);
process.exit(failures === 0 ? 0 : 1);
