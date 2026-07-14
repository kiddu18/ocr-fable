#!/usr/bin/env node
// Regresii rapide, fara macOS/Vision: geometrie + contractele critice ale extractorului.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { normalizeOrientation, segment, looksLikeSingleChitanta } = require('./replay_node');

const root = path.resolve(__dirname, '..', '..');
const bonuri = JSON.parse(fs.readFileSync(path.join(__dirname, 'cases', 'bonuri.txt'), 'utf8'));
assert.equal(segment(normalizeOrientation(bonuri)).length, 6,
  'plansa 3x2 trebuie separata in 6 documente');

const chitantaWords = [
  { text: 'CHITANTA', x: 10, y: 10, w: 100, h: 20 },
  { text: 'CUI emitent 17827267', x: 10, y: 45, w: 180, h: 20 },
  { text: 'Primit de la CUI 18518510', x: 10, y: 80, w: 220, h: 20 },
  { text: 'Suma de 344,77 lei', x: 10, y: 115, w: 180, h: 20 },
];
assert.equal(looksLikeSingleChitanta(chitantaWords), true,
  'CUI-ul emitentului si al platitorului apartin aceleiasi chitante');

const money = /(?<![\d%])(\d{1,5})\s?[.,]\s?(\d{2})(?!\d)(?!\s*%)/g;
assert.deepEqual('TOTAL 420,45'.match(money), ['420,45']);
assert.equal('COTA TVA 21,00%'.match(money), null,
  'procentul TVA nu este suma de bani');

const receiptSource = fs.readFileSync(path.join(root, 'OcrServer', 'ReceiptExtractor.swift'), 'utf8');
const routeSource = fs.readFileSync(path.join(root, 'OcrServer', 'VaporServer.swift'), 'utf8');
const chitantaSource = fs.readFileSync(path.join(root, 'OcrServer', 'ChitantaExtractor.swift'), 'utf8');
assert.match(receiptSource, /if vat\.rates\.isEmpty/,
  'nu se inventeaza o cota TVA cand procentul lipseste');
assert.equal(receiptSource.includes('CAPITAL\\\\s+SOCIAL'), true,
  'capitalul social este exclus din sume');
assert.match(routeSource, /ReceiptSegmenterV2\.segment\(firstClean\)/,
  're-OCR-ul trebuie urmat de a doua segmentare');
assert.match(routeSource, /vatAmounts\.reduce\(0, \+\)/,
  'TVA-ul cotelor multiple trebuie agregat');
assert.match(routeSource, /handwritingPass\(on: rotImg, clusterBoxes: clean\)/,
  'OCR-ul de mana trebuie limitat la documentul curent');
assert.doesNotMatch(chitantaSource, /flatMap \{ FinExtract\.amounts\(in: \$0\) \}\.max\(\)/,
  'cea mai mare valoare de pe formular nu este un fallback sigur');

console.log('OK: toate regresiile universale au trecut.');
