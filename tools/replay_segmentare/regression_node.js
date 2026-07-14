#!/usr/bin/env node
// Regresii rapide, fara macOS/Vision: geometrie + contractele critice ale extractorului.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { normalizeOrientation, segment, groupLines, looksLikeSingleChitanta } = require('./replay_node');

const root = path.resolve(__dirname, '..', '..');
const bonuri = JSON.parse(fs.readFileSync(path.join(__dirname, 'cases', 'bonuri.txt'), 'utf8'));
assert.equal(segment(normalizeOrientation(bonuri)).length, 6,
  'plansa 3x2 trebuie separata in 6 documente');

const bonClusters = segment(normalizeOrientation(bonuri));
const douglas = bonClusters.find(c => groupLines(c).join(' ').toUpperCase().includes('DOUGLAS'));
assert.ok(douglas, 'bonul Douglas trebuie pastrat ca document distinct');
const itemRows = groupLines(douglas).filter(line => /(?:\s|-)\b[A-E]\b\s*$/i.test(line)
  && !/TOTAL|SUBTOTAL|TVA|CARD|CASH|NUMERAR|REST/i.test(line));
const itemTotal = itemRows.reduce((sum, line) => {
  const values = [...line.matchAll(/(?<![\p{L}\d%])(\d{1,5})\s?[.,]\s?(\d{2})(?![\p{L}\d])/gu)]
    .map(m => Number(`${m[1]}.${m[2]}`));
  const value = values.at(-1) || 0;
  return sum + (/DISCOUNT|REDUCERE|RABAT|\d[.,]\d{2}\s*-\s*[A-E]\s*$/i.test(line) ? -value : value);
}, 0);
assert.equal(Math.round(itemTotal * 100) / 100, 613.10,
  'totalul lipsa poate fi reconstruit din articole fara a dubla pretul unitar');

const chitante = JSON.parse(fs.readFileSync(path.join(__dirname, 'cases', 'chitante.txt'), 'utf8'));
assert.equal(segment(normalizeOrientation(chitante.slice(0, 233))).length, 3,
  'prima pagina PDF trebuie sa contina 3 documente');
assert.equal(segment(normalizeOrientation(chitante.slice(233))).length, 3,
  'a doua pagina PDF trebuie sa contina Ameris, FAN si DONA');

const chitantaWords = [
  { text: 'CHITANTA', x: 10, y: 10, w: 100, h: 20 },
  { text: 'CUI emitent 17827267', x: 10, y: 45, w: 180, h: 20 },
  { text: 'Primit de la CUI 18518510', x: 10, y: 80, w: 220, h: 20 },
  { text: 'Suma de 344,77 lei', x: 10, y: 115, w: 180, h: 20 },
];
assert.equal(looksLikeSingleChitanta(chitantaWords), true,
  'CUI-ul emitentului si al platitorului apartin aceleiasi chitante');

const money = /(?<![\p{L}\d%])(\d{1,5})\s?[.,]\s?(\d{2})(?![\p{L}\d])(?!\s*%)/gu;
assert.deepEqual('TOTAL 420,45'.match(money), ['420,45']);
assert.equal('COTA TVA 21,00%'.match(money), null,
  'procentul TVA nu este suma de bani');
assert.equal('Suma de 6d7,00'.match(money), null,
  'o coada numerica dintr-un token OCR corupt nu devine 7,00');

function samePhysical(a, b) {
  const x1 = Math.max(a.x, b.x), y1 = Math.max(a.y, b.y);
  const x2 = Math.min(a.x + a.w, b.x + b.w), y2 = Math.min(a.y + a.h, b.y + b.h);
  if (x2 <= x1 || y2 <= y1) return false;
  const ia = (x2 - x1) * (y2 - y1), aa = a.w * a.h, ab = b.w * b.h;
  const iou = ia / (aa + ab - ia), coverage = ia / Math.min(aa, ab);
  const ratio = Math.max(aa, ab) / Math.min(aa, ab);
  return iou > .35 || (coverage > .72 && ratio < 1.9);
}
const physical = Array.from({ length: 6 }, (_, i) => ({ x: i * 120, y: 0, w: 100, h: 220, score: 1000 }));
const duplicateCandidates = [...physical,
  { x: 2 * 120 + 2, y: 3, w: 98, h: 216, score: 500 },
  { x: 5 * 120 - 2, y: 2, w: 101, h: 215, score: 600 }];
const deduped = [];
for (const candidate of duplicateCandidates.sort((a, b) => b.score - a.score)) {
  if (!deduped.some(existing => samePhysical(existing, candidate))) deduped.push(candidate);
}
assert.equal(deduped.length, 6, '8 candidati suprapusi trebuie sa ramana 6 documente fizice');

const receiptSource = fs.readFileSync(path.join(root, 'OcrServer', 'ReceiptExtractor.swift'), 'utf8');
const routeSource = fs.readFileSync(path.join(root, 'OcrServer', 'VaporServer.swift'), 'utf8');
const chitantaSource = fs.readFileSync(path.join(root, 'OcrServer', 'ChitantaExtractor.swift'), 'utf8');
const anafSource = fs.readFileSync(path.join(root, 'OcrServer', 'AnafValidator.swift'), 'utf8');
assert.match(receiptSource, /if vat\.rates\.isEmpty/,
  'nu se inventeaza o cota TVA cand procentul lipseste');
assert.equal(receiptSource.includes('CAPITAL\\\\s+SOCIAL'), true,
  'capitalul social este exclus din sume');
assert.match(routeSource, /ReceiptSegmenterV2\.segment\(firstClean\)/,
  're-OCR-ul trebuie urmat de a doua segmentare');
assert.match(routeSource, /TextRecognizerPro\.deduplicate\(refinedCandidates\)/,
  'documentele rafinate trebuie deduplicate din nou');
assert.match(routeSource, /expandHorizontally: !hasHorizontalNeighbor/,
  'blocurile laterale ale unei chitante singure trebuie recuperate');
assert.match(routeSource, /vatAmounts\.reduce\(0, \+\)/,
  'TVA-ul cotelor multiple trebuie agregat');
assert.match(routeSource, /handwritingPass\(on: rotImg, clusterBoxes: clean\)/,
  'OCR-ul de mana trebuie limitat la documentul curent');
assert.doesNotMatch(chitantaSource, /flatMap \{ FinExtract\.amounts\(in: \$0\) \}\.max\(\)/,
  'cea mai mare valoare de pe formular nu este un fallback sigur');
assert.equal(chitantaSource.includes('RAMBURS\\\\s+CONT\\\\s+COLECTOR'), true,
  'chitanta FAN trebuie clasificata dupa semantica documentului');
assert.match(chitantaSource, /repairedAmountCandidates/,
  'sumele scrise de mana trebuie reparate contextual, nu trunchiate');
assert.match(chitantaSource, /payerIdRx/,
  'CUI-ul platitorului trebuie izolat de numarul Registrului Comertului');
assert.match(anafSource, /found\.count == 1/,
  'unicul candidat confirmat ANAF trebuie folosit pentru repararea CUI');

console.log('OK: toate regresiile universale au trecut.');
