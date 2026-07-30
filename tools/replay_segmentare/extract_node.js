#!/usr/bin/env node
// Extractor offline aliniat cu ReceiptExtractor.swift (v7).
// Ruleaza pe clusterele din segment() fara iPhone/Vision.

const RATE_VALUES = new Set([5, 9, 11, 19, 21]);

function amountsIn(line) {
  if (/RC\s*:|AUTOR|NR\.?\s*CARD|\bTRX\b|CNP|C\.?I\.?F|CUI|COD\s+FISCAL|TELEFON|TEL\.?\s*[:=]|IBAN|CAPITAL\s+SOCIAL|POS\b|EJTRZ|ID\s*UNIC|AUTORIZARE/i.test(line)
      && !/TOTAL|TVA|SUMA/i.test(line)) {
    return [];
  }
  const out = [];
  const re = /(?<![\p{L}\d%])(\d{1,5})\s?[.,]\s?(\d{2})(?![\p{L}\d])(?!\s*%)/gu;
  let m;
  while ((m = re.exec(line))) {
    const v = Number(`${m[1]}.${m[2]}`);
    if (!Number.isNaN(v)) out.push(v);
  }
  return out;
}

function ron2(v) {
  return Math.round(v * 100) / 100;
}

function isPlausibleTotal(v) {
  return v >= 0.5 && v <= 99999 && !RATE_VALUES.has(v);
}

function totalAmount(lines) {
  const rejected = /SUBTOTAL|TOTAL\s*TVA|TVA\s*TOTAL|IOTAL\s*TVA|SUMA\s*TVA|COTA\s*TVA|REST|RULAJ|TOTALTVA/i;
  const hasTotal = /(?<!SUB)\bTOTAL\b(?!\s*TVA)/i;
  const inline = /(?<!SUB)\bTOTAL\b(?!\s*TVA)\s*[:=]?\s*(\d{1,5})\s?[.,]\s?(\d{2})(?!\s*%)/i;

  for (const line of lines) {
    if (rejected.test(line)) continue;
    const m = line.match(inline);
    if (m) {
      const v = Number(`${m[1]}.${m[2]}`);
      if (isPlausibleTotal(v)) return v;
    }
  }
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (rejected.test(line) || !hasTotal.test(line)) continue;
    const onLine = amountsIn(line).filter(isPlausibleTotal);
    if (onLine.length) return Math.max(...onLine);
    for (const next of lines.slice(i + 1, i + 7)) {
      if (rejected.test(next)) continue;
      if (/%|COTA\s*TVA/i.test(next)) continue;
      const amts = amountsIn(next).filter(isPlausibleTotal);
      const big = amts.filter(v => v >= 30);
      if (big.length) return Math.max(...big);
      if (amts.length) return Math.max(...amts);
    }
  }
  // Total retiparit de 2+ ori pe bon (TOTAL/CARD/CASH)
  const freq = new Map();
  for (const line of lines) {
    if (/CUI|CIF|FISCAL|COD\s*FISC|CLIENT|CNP|RC\s*:|AUTOR|TRX|POS\b|EJTRZ|TELEFON|IBAN/i.test(line)
        && !/TOTAL|CARD|CASH/i.test(line)) continue;
    for (const v of amountsIn(line).filter(a => isPlausibleTotal(a) && a >= 10)) {
      const k = v.toFixed(2);
      freq.set(k, { v, n: (freq.get(k)?.n || 0) + 1 });
    }
  }
  let best = null;
  for (const { v, n } of freq.values()) {
    if (n >= 2 && (!best || v > best)) best = v;
  }
  return best;
}

function itemizedTotal(lines) {
  const full = lines.join(' ').toUpperCase();
  if (!/\bTOTAL\b|SUBTOTAL|TOTALTVA|\bBF\b|\b[A-E]\b/.test(full)) return null;
  const values = [];
  for (const line of lines) {
    if (/\bTOTAL\b|SUBTOTAL|\bTVA\b|CARD|CASH|NUMERAR|REST|RULAJ|COTA/i.test(line)) continue;
    const neg = /DISCOUNT|REDUCERE|RABAT|\d[.,]\d{2}\s*-\s*[A-E]|\d[.,]\d{2}-[A-E]/i.test(line);
    if (/(?:^|\s|-)\b[A-E]\b(?:\s+[A-E]\b)*\s*$/i.test(line)) {
      const amts = amountsIn(line);
      if (!amts.length) continue;
      const value = amts[amts.length - 1];
      if (RATE_VALUES.has(value)) continue;
      values.push(neg ? -value : value);
      continue;
    }
    const m = line.match(/(\d{1,5})[.,](\d{2})\s*-?\s*[A-E]\b/i);
    if (m) {
      const value = Number(`${m[1]}.${m[2]}`);
      if (!RATE_VALUES.has(value) && value >= 1) values.push(neg ? -value : value);
    }
  }
  if (!values.length) return null;
  // Collapse consecutive OCR duplicates: 443,443,243,243,-72.9,-72.9
  const collapsed = [];
  for (const v of values) {
    if (collapsed.length && Math.abs(collapsed[collapsed.length - 1] - v) < 0.001) continue;
    collapsed.push(v);
  }
  const t = ron2(collapsed.reduce((a, b) => a + b, 0));
  return t > 0 ? t : null;
}

function productLineTotal(lines) {
  const found = [];
  for (const line of lines) {
    if (/TOTAL|TVA|CARD|REST|COTA|SUBTOTAL/i.test(line)) continue;
    if (!/LITRU|\bL\b|GPL|MOTORINA|BENZINA|X\s*\d|BUC|\d\s*[Xx×]/i.test(line)
        && !/(\d{1,5})[.,](\d{2})\s*[A-G]\s*$/i.test(line)) continue;
    const m = line.match(/(\d{1,5})[.,](\d{2})\s*[A-G]\s*$/i);
    if (!m) continue;
    const v = Number(`${m[1]}.${m[2]}`);
    if (!RATE_VALUES.has(v) && v >= 1) found.push(v);
  }
  return found.length ? Math.max(...found) : null;
}

function vatInfo(lines) {
  const rates = [];
  const amounts = [];
  const pairs = [];
  const rateRx = /(?:COTA\s*)?(?:TOTAL\s*)?TVA\s*[A-E]?\s*[=:]?\s*(\d{1,2})(?:[.,]\d{1,2})?\s*[%X×x]/gi;
  const tvaAmt = /TOTAL\s*TVA|TVA\s*TOTAL|IOTAL\s*TVA|TOTALTVA|SUMA\s*TVA/i;

  for (const line of lines) {
    const lineRates = [...line.matchAll(rateRx)].map(m => Number(m[1])).filter(v => v > 0 && v < 100);
    const lineAmounts = amountsIn(line).filter(v => !RATE_VALUES.has(v));
    for (const v of lineRates) if (!rates.includes(v)) rates.push(v);
    if (lineRates.length >= 1 && lineAmounts.length >= 1) {
      if (lineRates.length === lineAmounts.length) {
        lineRates.forEach((v, i) => {
          if (!pairs.some(p => p.rate === v)) pairs.push({ rate: v, amount: lineAmounts[i] });
        });
      } else if (lineRates.length === 1) {
        const v = lineRates[0];
        const amt = lineAmounts[lineAmounts.length - 1];
        if (!pairs.some(p => p.rate === v)) pairs.push({ rate: v, amount: amt });
      }
    }
    if (tvaAmt.test(line)) {
      for (const v of amountsIn(line)) {
        if (!RATE_VALUES.has(v) && !amounts.includes(v)) amounts.push(v);
      }
    }
  }
  if (pairs.length >= 2) {
    return { rates: pairs.map(p => p.rate), amounts: pairs.map(p => p.amount) };
  }
  if (pairs.length === 1 && !amounts.length) {
    return { rates: rates.length ? rates : [pairs[0].rate], amounts: [pairs[0].amount] };
  }
  return { rates, amounts };
}

function fuel(lines) {
  let product = null;
  for (const line of lines) {
    const m = line.match(/MOTORINA[A-Z0-9 ]*|BENZINA[A-Z0-9 ]*|\bGPL\b|DIESEL|ADBLUE/i);
    if (m) { product = m[0].trim(); break; }
  }
  // Nu trata "443.00 x 243.00" (articole) ca litri×pret.
  const pairRx = /(\d{1,3}[.,]\d{1,3})\s*(?:L(?:ITRU)?\s*)?[Xx×]\s*(\d{1,3}[.,]\d{1,3})/;
  for (const line of lines) {
    const up = line.toUpperCase();
    const isFuel = product || /\bL(?:ITRU)?\b|MOTORINA|BENZINA|\bGPL\b|DIESEL|ADBLUE/.test(up);
    if (!isFuel) continue;
    const m = up.match(pairRx);
    if (!m) continue;
    const a = Number(m[1].replace(',', '.'));
    const b = Number(m[2].replace(',', '.'));
    const priceOk = v => v >= 2 && v <= 25;
    const litOk = v => v >= 0.5 && v <= 250;
    let liters, price;
    if (priceOk(a) && litOk(b) && !priceOk(b)) { liters = b; price = a; }
    else if (priceOk(b) && litOk(a) && !priceOk(a)) { liters = a; price = b; }
    else if (priceOk(a) && litOk(b)) { liters = b; price = a; }
    else if (priceOk(b) && litOk(a)) { liters = a; price = b; }
    else continue;
    if (liters * price > 50000) continue;
    return { liters, price, product };
  }
  return { liters: null, price: null, product };
}

function extractCui(lines) {
  const buyerRx = /CLIENT|CUMPARATOR|BENEF|CNP/i;
  const ctx = /(?:COD\s*FISC[A-Z]*|COD\s*IDENT[A-Z]{0,8}\s*FISC[A-Z]*|C\.?\s*[I1]\.?\s*F|\bC\.?\s*F\b|\bCUI\b)\s*[.:]?\s*(?:R(?:[O0Q]|[^A-Z0-9@]{0,3}))?\s*[.:]?\s*([A-Z0-9@]{4,12})|\bR[O0]\s?([0-9OQDILSZB@]{4,12})\b/gi;
  const raw = [];
  for (const line of lines) {
    if (buyerRx.test(line)) continue;
    let m;
    const re = new RegExp(ctx.source, 'gi');
    while ((m = re.exec(line.toUpperCase()))) {
      raw.push(m[1] || m[2]);
    }
  }
  function normalize(tok) {
    let t = tok || '';
    if (t.length > 2 && t[0] === 'R' && /[O0Q]/.test(t[1])) t = t.slice(2);
    const map = { O: '0', Q: '0', D: '0', P: '0', I: '1', L: '1', Z: '2', S: '5', B: '8', G: '6', '@': '0' };
    let d = [...t.toUpperCase()].map(c => map[c] || c).join('').replace(/\D/g, '');
    while (d.length > 4 && d[0] === '0') d = d.slice(1);
    return d;
  }
  function isValid(cui) {
    // Oficial RO: 2–10 cifre + checksum. ANAF + nume decid forma finala.
    if (!/^\d{2,10}$/.test(cui)) return false;
    const key = [...'753217532'].reverse();
    const digits = [...cui].reverse().map(Number);
    const control = digits[0];
    let sum = 0;
    for (let i = 1; i < digits.length && i - 1 < key.length; i++) sum += digits[i] * key[i - 1];
    let calc = (sum * 10) % 11;
    if (calc === 10) calc = 0;
    return calc === control;
  }
  const candidates = [];
  for (const c of raw) {
    let d = normalize(c);
    if (!d || d.length < 2) continue;
    // Mereu forma citita — ANAF + nume decid (checksum e doar semnal)
    candidates.push(d);
    if (isValid(d)) candidates.push(d);
    if (d.length > 2 && isValid(d.slice(1))) candidates.push(d.slice(1));
    // CUI trunchiat: +1 sau +2 cifre
    const before = candidates.length;
    if (d.length >= 4 && d.length <= 8 && !isValid(d)) {
      for (const x of '0123456789') {
        const s1 = d + x;
        if (isValid(s1)) candidates.push(s1);
        for (const y of '0123456789') {
          const s2 = s1 + y;
          if (isValid(s2)) candidates.push(s2);
        }
      }
    }
    // flip o cifra doar daca append n-a produs nimic
    if (candidates.length === before) {
      const chars = [...d];
      for (let i = 0; i < chars.length; i++) {
        for (const x of '0123456789') {
          if (chars[i] === x) continue;
          const v = [...chars]; v[i] = x;
          const s = v.join('');
          if (isValid(s)) candidates.push(s);
        }
      }
    }
  }
  const uniq = [...new Set(candidates)].filter(c => c.length >= 2 && c.length <= 10);
  const bases = raw.map(normalize).filter(b => b && b.length >= 2 && b.length <= 10);
  // Preferam forma citita de pe bon (R07745478 → 7745478), nu append-uri
  // de 1 cifra care trec checksum (77454781) sau flip-uri (8745478 = PF HAGIU).
  if (bases.length) {
    const exact = bases[0];
    return { cui: exact, ok: isValid(exact), candidates: uniq.length ? uniq : [exact] };
  }
  const grounded = uniq.filter(c => isValid(c)).sort((a, b) => a.length - b.length || a.localeCompare(b));
  if (grounded.length) return { cui: grounded[0], ok: true, candidates: uniq };
  if (uniq.length) return { cui: uniq[0], ok: isValid(uniq[0]), candidates: uniq };
  return { cui: null, ok: false, candidates: [] };
}

function parseDate(lines) {
  const preferred = [...lines.filter(l => /DATA/i.test(l)), ...lines];
  const rx = /\b(\d{1,2})[./-](\d{1,2})[./-](2[08]\d{2})\b/;
  function repaired(v, lo, hi) {
    if (v >= lo && v <= hi) return v;
    const s = String(v);
    for (let i = 0; i < s.length; i++) {
      if (s[i] !== '8') continue;
      const r = Number(s.slice(0, i) + '0' + s.slice(i + 1));
      if (r >= lo && r <= hi) return r;
    }
    return null;
  }
  for (const line of preferred) {
    const m = line.match(rx);
    if (!m) continue;
    const d = repaired(+m[1], 1, 31);
    const mo = repaired(+m[2], 1, 12);
    const y = repaired(+m[3], 2000, 2099);
    if (d && mo && y) return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
  }
  return null;
}

function extract(lines) {
  const allAmounts = lines.flatMap(amountsIn);
  let direct = totalAmount(lines);
  const articles = itemizedTotal(lines);
  const product = productLineTotal(lines);
  let total = direct ?? articles ?? product;
  let vat = vatInfo(lines);
  let rates = [...vat.rates];
  let vatAmounts = [...vat.amounts];

  if (!rates.length && vatAmounts.length) rates = [21];
  if (!rates.length && total != null) rates = [21];
  const mainRate = rates[0] || 21;

  if (total != null && vatAmounts[0] != null) {
    const expected = ron2(vatAmounts[0] * (100 + mainRate) / mainRate);
    if (Math.abs(total - expected) > 0.10) {
      if (product != null && Math.abs(product - expected) <= 0.10) total = product;
      else {
        const match = allAmounts.find(a => Math.abs(a - expected) <= 0.06);
        if (match != null) total = match;
      }
    }
  }
  if (articles != null) {
    const looksLikeRate = total == null || RATE_VALUES.has(total);
    if (looksLikeRate) total = articles;
  }

  let vatAmount = vatAmounts[0] ?? null;
  if (total != null && vatAmount != null) {
    const ok = Math.abs(vatAmount - total * mainRate / (100 + mainRate)) <= 0.06;
    if (!ok) {
      const tCalc = ron2(vatAmount * (100 + mainRate) / mainRate);
      if (allAmounts.some(a => Math.abs(a - tCalc) <= 0.06)) total = tCalc;
      else vatAmount = ron2(total * mainRate / (100 + mainRate));
    }
  } else if (total != null && vatAmount == null && rates.length) {
    vatAmount = ron2(total * mainRate / (100 + mainRate));
  }

  const f = fuel(lines);
  if (f.liters != null && f.price != null) {
    const fuelTotal = ron2(f.liters * f.price);
    if (total == null || (Math.abs(fuelTotal - total) > 0.5
        && (allAmounts.some(a => Math.abs(a - fuelTotal) <= 0.06)
            || (product != null && Math.abs(fuelTotal - product) <= 0.06)))) {
      total = fuelTotal;
      vatAmount = ron2(fuelTotal * mainRate / (100 + mainRate));
    }
  }

  const cui = extractCui(lines);
  const multi = rates.length > 1 && rates.length === vatAmounts.length;
  return {
    merchant: lines[0] || null,
    cui: cui.cui,
    cuiOk: cui.ok,
    date: parseDate(lines),
    total,
    vat: multi ? ron2(vatAmounts.reduce((a, b) => a + b, 0)) : vatAmount,
    rates: multi ? rates : (rates[0] != null ? [rates[0]] : []),
    vatLines: multi
      ? rates.map((rate, i) => ({ rate, amount: vatAmounts[i] }))
      : (vatAmount != null ? [{ rate: mainRate, amount: vatAmount }] : []),
    fuel: f,
  };
}

module.exports = { extract, amountsIn, totalAmount, itemizedTotal, productLineTotal, vatInfo, fuel, extractCui };
