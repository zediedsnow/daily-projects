// Character sets over UTF-16 code units, stored as a sorted, merged list of
// inclusive ranges: [lo0, hi0, lo1, hi1, ...].

export type Ranges = number[];

export const MAX_CHAR = 0xffff;

export function normalize(r: Ranges): Ranges {
  const pairs: [number, number][] = [];
  for (let i = 0; i < r.length; i += 2) pairs.push([r[i], r[i + 1]]);
  pairs.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const out: Ranges = [];
  for (const [lo, hi] of pairs) {
    const n = out.length;
    if (n && lo <= out[n - 1] + 1) out[n - 1] = Math.max(out[n - 1], hi);
    else out.push(lo, hi);
  }
  return out;
}

export function complement(r: Ranges): Ranges {
  const out: Ranges = [];
  let next = 0;
  for (let i = 0; i < r.length; i += 2) {
    if (r[i] > next) out.push(next, r[i] - 1);
    next = r[i + 1] + 1;
  }
  if (next <= MAX_CHAR) out.push(next, MAX_CHAR);
  return out;
}

export function contains(r: Ranges, c: number): boolean {
  // binary search over range pairs
  let lo = 0, hi = (r.length >> 1) - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (c < r[2 * mid]) hi = mid - 1;
    else if (c > r[2 * mid + 1]) lo = mid + 1;
    else return true;
  }
  return false;
}

export const DIGIT: Ranges = [0x30, 0x39];
export const WORD: Ranges = normalize([0x30, 0x39, 0x41, 0x5a, 0x5f, 0x5f, 0x61, 0x7a]);
// ECMAScript WhiteSpace + LineTerminator
export const SPACE: Ranges = normalize([
  0x09, 0x0d, 0x20, 0x20, 0xa0, 0xa0, 0x1680, 0x1680, 0x2000, 0x200a,
  0x2028, 0x2029, 0x202f, 0x202f, 0x205f, 0x205f, 0x3000, 0x3000, 0xfeff, 0xfeff,
]);
export const LINE_TERM: Ranges = normalize([0x0a, 0x0a, 0x0d, 0x0d, 0x2028, 0x2029]);
export const DOT: Ranges = complement(LINE_TERM);
export const ANY: Ranges = [0, MAX_CHAR];

export function isWordChar(c: number): boolean {
  return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || c === 0x5f || (c >= 0x61 && c <= 0x7a);
}
export function isLineTerm(c: number): boolean {
  return c === 0x0a || c === 0x0d || c === 0x2028 || c === 0x2029;
}

// ECMAScript non-unicode Canonicalize(): toUpperCase, but never map a
// non-ASCII char to ASCII and never expand to multiple chars.
let canonTable: Uint16Array | null = null;
function canon(): Uint16Array {
  if (canonTable) return canonTable;
  const t = new Uint16Array(MAX_CHAR + 1);
  for (let c = 0; c <= MAX_CHAR; c++) {
    const u = String.fromCharCode(c).toUpperCase();
    if (u.length !== 1) { t[c] = c; continue; }
    const cu = u.charCodeAt(0);
    t[c] = c >= 128 && cu < 128 ? c : cu;
  }
  return (canonTable = t);
}

/** Close a set under case-insensitive equivalence (as the `i` flag defines it). */
export function caseFold(r: Ranges): Ranges {
  const t = canon();
  const canonMembers = new Uint8Array(MAX_CHAR + 1);
  for (let i = 0; i < r.length; i += 2)
    for (let c = r[i]; c <= r[i + 1]; c++) canonMembers[t[c]] = 1;
  const out: Ranges = [];
  for (let c = 0; c <= MAX_CHAR; c++) {
    if (!canonMembers[t[c]]) continue;
    const n = out.length;
    if (n && out[n - 1] === c - 1) out[n - 1] = c;
    else out.push(c, c);
  }
  return out;
}

export function describe(r: Ranges): string {
  if (r.length === 2 && r[0] === 0 && r[1] === MAX_CHAR) return 'ANY';
  const show = (c: number) => {
    if (c >= 0x21 && c <= 0x7e && !'[]\\-^'.includes(String.fromCharCode(c))) return String.fromCharCode(c);
    return c <= 0xff ? '\\x' + c.toString(16).padStart(2, '0') : '\\u' + c.toString(16).padStart(4, '0');
  };
  if (r.length === 2 && r[0] === r[1]) return `'${show(r[0])}'`;
  const comp = complement(r);
  const [set, neg] = comp.length < r.length ? [comp, '^'] : [r, ''];
  let s = '';
  for (let i = 0; i < set.length && i < 16; i += 2)
    s += set[i] === set[i + 1] ? show(set[i]) : show(set[i]) + '-' + show(set[i + 1]);
  if (set.length > 16) s += '…';
  return `[${neg}${s}]`;
}
