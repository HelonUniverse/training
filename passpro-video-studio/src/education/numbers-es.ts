// Finds numeric claims with units in Spanish (and simple English) text:
//   "40 preguntas", "cuarenta y dos preguntas", "diez preguntas de prueba",
//   "90 minutos", "dos horas", "una hora y media", "70 %", "setenta por ciento".
// Hours are converted to minutes so "dos horas" can be checked against a
// minutes lock.

export type NumericUnit = 'questions' | 'minutes' | 'percent';

export interface NumericMention {
  value: number;
  unit: NumericUnit;
  /** the matched words as written (normalized) */
  text: string;
  /** index range in the normalized text */
  start: number;
  end: number;
}

export function normalizeText(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

const UNITS: Record<string, number> = {
  cero: 0, un: 1, uno: 1, una: 1, dos: 2, tres: 3, cuatro: 4, cinco: 5, seis: 6, siete: 7, ocho: 8, nueve: 9,
  diez: 10, once: 11, doce: 12, trece: 13, catorce: 14, quince: 15, dieciseis: 16, diecisiete: 17,
  dieciocho: 18, diecinueve: 19, veinte: 20, veintiun: 21, veintiuno: 21, veintiuna: 21, veintidos: 22,
  veintitres: 23, veinticuatro: 24, veinticinco: 25, veintiseis: 26, veintisiete: 27, veintiocho: 28,
  veintinueve: 29,
};
const TENS: Record<string, number> = {
  treinta: 30, cuarenta: 40, cincuenta: 50, sesenta: 60, setenta: 70, ochenta: 80, noventa: 90,
};
const HUNDREDS: Record<string, number> = {
  cien: 100, ciento: 100, doscientos: 200, doscientas: 200, trescientos: 300, trescientas: 300,
  cuatrocientos: 400, cuatrocientas: 400, quinientos: 500, quinientas: 500, seiscientos: 600,
  seiscientas: 600, setecientos: 700, setecientas: 700, ochocientos: 800, ochocientas: 800,
  novecientos: 900, novecientas: 900,
};
const EN: Record<string, number> = {
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90, hundred: 100,
};

const UNIT_WORDS: [RegExp, NumericUnit, number][] = [
  [/^(preguntas?|questions?|items?|reactivos?)$/, 'questions', 1],
  [/^(minutos?|minutes?|mins?)$/, 'minutes', 1],
  [/^(horas?|hours?|hrs?)$/, 'minutes', 60],
  [/^(%|porciento)$/, 'percent', 1],
];
const FILLERS = new Set(['de', 'del', 'las', 'los', 'mas', 'más', 'completas', 'completos', 'exactas', 'exactos']);

interface Tok { w: string; start: number; end: number }

function tokenize(norm: string): Tok[] {
  const out: Tok[] = [];
  const re = /\d+(?:[.,]\d+)?|%|[a-zñ]+/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(norm))) out.push({ w: m[0], start: m.index, end: m.index + m[0].length });
  return out;
}

/** Parses a number starting at token i. Returns value and tokens consumed. */
function parseNumber(t: Tok[], i: number): { value: number; used: number } | null {
  const w = t[i]?.w;
  if (!w) return null;
  if (/^\d/.test(w)) return { value: Number(w.replace(',', '.')), used: 1 };
  if (w in EN) {
    let v = EN[w];
    let used = 1;
    if (v >= 20 && v < 100 && t[i + 1] && EN[t[i + 1].w] && EN[t[i + 1].w] < 10) {
      v += EN[t[i + 1].w];
      used = 2;
    }
    return { value: v, used };
  }
  let value = 0;
  let used = 0;
  let any = false;
  if (t[i + used] && t[i + used].w in HUNDREDS) {
    value += HUNDREDS[t[i + used].w];
    used += 1;
    any = true;
  }
  if (t[i + used] && t[i + used].w in TENS) {
    value += TENS[t[i + used].w];
    used += 1;
    any = true;
    if (t[i + used]?.w === 'y' && t[i + used + 1] && UNITS[t[i + used + 1].w] !== undefined && UNITS[t[i + used + 1].w] < 10) {
      value += UNITS[t[i + used + 1].w];
      used += 2;
    }
  } else if (t[i + used] && UNITS[t[i + used].w] !== undefined) {
    value += UNITS[t[i + used].w];
    used += 1;
    any = true;
  }
  if (t[i + used]?.w === 'mil' && any) {
    value *= 1000;
    used += 1;
  }
  return any ? { value, used } : null;
}

export function findNumericMentions(text: string): NumericMention[] {
  const norm = normalizeText(text).replace(/por\s+ciento/g, 'porciento');
  const toks = tokenize(norm);
  const out: NumericMention[] = [];
  for (let i = 0; i < toks.length; i++) {
    const n = parseNumber(toks, i);
    if (!n) continue;
    let j = i + n.used;
    // "una hora y media"
    let value = n.value;
    let k = j;
    while (k < toks.length && FILLERS.has(toks[k].w) && k - j < 2) k++;
    const unitTok = toks[k];
    const unit = unitTok && UNIT_WORDS.find(([re]) => re.test(unitTok.w));
    // "un/una" is usually an article ("te hago una pregunta"); count it only for time ("una hora")
    const isArticle = ['un', 'una', 'uno'].includes(toks[i].w);
    if (!unit || (isArticle && (k !== j || unit[1] !== 'minutes'))) {
      i += n.used - 1;
      continue;
    }
    let end = unitTok.end;
    if (unit[2] === 60 && toks[k + 1]?.w === 'y' && toks[k + 2]?.w === 'media') {
      value += 0.5;
      end = toks[k + 2].end;
    }
    out.push({ value: value * unit[2], unit: unit[1], text: norm.slice(toks[i].start, end), start: toks[i].start, end });
    i = k;
  }
  return out;
}
