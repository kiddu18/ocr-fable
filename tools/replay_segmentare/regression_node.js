#!/usr/bin/env node
// Regresii rapide, fara macOS/Vision: geometrie + contractele critice ale extractorului.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { normalizeOrientation, segment, groupLines, looksLikeSingleChitanta } = require('./replay_node');

const root = path.resolve(__dirname, '..', '..');
const bonuri = JSON.parse(fs.readFileSync(path.join(__dirname, 'cases', 'bonuri.txt'), 'utf8'));
assert.equal(segment(bonuri).length, 6,
  'plansa verticala 3x2 trebuie normalizata automat si separata in 6 documente');

// Dump-ul trimis dupa rularea v4 contine un caz nou: bonurile Tourist si
// Magistral din dreapta-jos nu au gol alb suficient pentru XY-cut. Separarea
// dupa doua antete fiscale complete trebuie sa refaca tot 6 documente.
const bonuriFeedbackV4 = JSON.parse(fs.readFileSync(
  path.join(__dirname, 'cases', 'bonuri_feedback_v4.txt'), 'utf8'));
assert.equal(segment(bonuriFeedbackV4).length, 6,
  'feedback-ul v4 trebuie separat in exact 6 bonuri, fara fragmentare sau lipire');

const bonuriFeedbackV5 = JSON.parse(fs.readFileSync(
  path.join(__dirname, 'cases', 'bonuri_feedback_v5.txt'), 'utf8'));
const bonuriV5Clusters = segment(bonuriFeedbackV5);
assert.equal(bonuriV5Clusters.length, 6,
  'cele 3 zone initiale din buildul v5 trebuie resegmentate la nivel de pagina in 6 bonuri');
const douglasV5 = bonuriV5Clusters.find(c =>
  groupLines(c).join(' ').toUpperCase().includes('DOUGLAS'));
assert.ok(douglasV5, 'Douglas trebuie recuperat ca document autonom din zona compusa v5');
const douglasV5Items = groupLines(douglasV5).filter(line =>
  /(?:\s|-)\b[A-E]\b\s*$/i.test(line) && !/TOTAL|SUBTOTAL|TVA|CARD|REST/i.test(line));
const douglasV5Total = douglasV5Items.reduce((sum, line) => {
  const values = [...line.matchAll(/(?<![\p{L}\d%])(\d{1,5})\s?[.,]\s?(\d{2})(?![\p{L}\d])/gu)]
    .map(m => Number(`${m[1]}.${m[2]}`));
  const value = values.at(-1) || 0;
  return sum + (/DISCOUNT|REDUCERE|RABAT|\d[.,]\d{2}\s*-\s*[A-E]\s*$/i.test(line) ? -value : value);
}, 0);
assert.equal(Math.round(douglasV5Total * 100) / 100, 613.10,
  'Douglas v5 trebuie sa isi recupereze totalul din articolele propriului cluster');

const bonClusters = segment(bonuri);
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
let pageBreak = 1, largestReset = -Infinity;
for (let i = 1; i < chitante.length; i++) {
  const reset = chitante[i - 1].y - chitante[i].y;
  if (reset > largestReset) { largestReset = reset; pageBreak = i; }
}
const page1Clusters = segment(chitante.slice(0, pageBreak));
assert.equal(page1Clusters.length, 3,
  'prima pagina PDF trebuie sa contina 3 documente');
assert.equal(segment(chitante.slice(pageBreak)).length, 3,
  'a doua pagina PDF trebuie sa contina Ameris, FAN si DONA');
const page2Clusters = segment(chitante.slice(pageBreak));
const ameris = page2Clusters.find(c => groupLines(c).join(' ').toUpperCase().includes('AMERIS'));
assert.ok(ameris, 'bonul fiscal de pe pagina a doua trebuie pastrat complet');
const amerisVat = groupLines(ameris).flatMap(line => {
  const m = line.match(/SUMA\s+TVA\s+[A-E]\s+(\d{1,2})%.*?(\d{1,5})[,.](\d{2})/i);
  return m ? [{ rate: Number(m[1]), amount: Number(`${m[2]}.${m[3]}`) }] : [];
});
assert.deepEqual(amerisVat, [{ rate: 21, amount: 7.01 }, { rate: 11, amount: 37.66 }],
  'cotele multiple si sumele lor trebuie pastrate pe acelasi document');
assert.equal(Math.round(amerisVat.reduce((s, x) => s + x.amount, 0) * 100) / 100, 44.67,
  'TVA-ul documentului cu cote multiple trebuie agregat');
const printedDaisyText = groupLines(page1Clusters.find(c =>
  groupLines(c).join(' ').includes('14332'))).join(' ');
assert.match(printedDaisyText, /SERIE\s+DSF\s+NUMAR\s+14332/i,
  'seria DSF nu trebuie inlocuita de cuvantul generic SERIA');
const donaText = groupLines(page2Clusters.find(c =>
  groupLines(c).join(' ').toUpperCase().includes('DONA'))).join(' ');
assert.match(donaText, /SERIE\s*\/\s*NHONAR:\s*DI[., ]+200861/i,
  'seria si numarul DONA trebuie pastrate din antetul OCR');
const fanText = groupLines(page2Clusters.find(c =>
  groupLines(c).join(' ').toUpperCase().includes('FAN COURIER'))).join(' ');
assert.match(fanText, /SUMA\s+DE\s+387\s*[., ]\s*46/i,
  'suma FAN trebuie sa ramana in documentul FAN');

const chitanteFeedbackV5 = JSON.parse(fs.readFileSync(
  path.join(__dirname, 'cases', 'chitante_feedback_v5.txt'), 'utf8'));
let pageBreakV5 = 1, largestResetV5 = -Infinity;
for (let i = 1; i < chitanteFeedbackV5.length; i++) {
  const reset = chitanteFeedbackV5[i - 1].y - chitanteFeedbackV5[i].y;
  if (reset > largestResetV5) { largestResetV5 = reset; pageBreakV5 = i; }
}
const feedbackV5Page1 = segment(chitanteFeedbackV5.slice(0, pageBreakV5));
const feedbackV5Page2 = segment(chitanteFeedbackV5.slice(pageBreakV5));
assert.equal(feedbackV5Page1.length, 3,
  'pagina 1 din feedback-ul v5 trebuie sa pastreze cele 3 chitante');
assert.equal(feedbackV5Page2.length, 3,
  'zona comuna FAN+DONA din feedback-ul v5 trebuie separata in doua documente');
assert.ok(feedbackV5Page2.some(c => /FAN/i.test(groupLines(c).join(' '))),
  'FAN trebuie sa fie document separat');
assert.ok(feedbackV5Page2.some(c => /DONA/i.test(groupLines(c).join(' '))),
  'DONA trebuie sa fie document separat');
const printedDaisyV5 = groupLines(feedbackV5Page1.find(c =>
  /14332/.test(groupLines(c).join(' ')))).join(' ');
assert.ok(printedDaisyV5.includes('18518510'),
  'CUI-ul emitentului Daisy trebuie pastrat in clusterul DSF');
assert.ok(!printedDaisyV5.includes('43544049')
    || printedDaisyV5.indexOf('18518510') < printedDaisyV5.indexOf('43544049'),
  'CUI-ul platitorului nu trebuie sa inlocuiasca emitentul din antet');

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

const explicitNumber = /(?:NUMAR|NWUAR|NOMAR|TOMNAR|NOUAR|NHONAR|ANAR)\s*[:#.-]*\s*(?:[A-Z]{1,8}[., ]*)?(\d{1,16})/i;
const weakNumber = /\bNR\.?\s*[:#.-]*\s*(\d{1,16})/i;
const numberNoise = /REG\.?\s*COM|ORD\.?\s*REG|ADRES|CUI|CIF|IBAN|CONT|TELEFON|TEL\.?|FAX|CAPITAL|FACTUR/i;
function documentNumber(lines) {
  for (const rx of [explicitNumber, weakNumber]) {
    for (const line of lines) {
      if (rx === weakNumber && numberNoise.test(line)) continue;
      const m = line.match(rx); if (m) return m[1];
    }
  }
}
assert.equal(documentNumber([
  'Adresa str. Biharia nr. 67-77 Serie DSF Numar 14332',
  'Data 14.05.2026',
]), '14332', 'numarul chitantei are prioritate fata de nr. din adresa');
assert.equal(documentNumber([
  'Nr.Reg.Com. J2006004970406 Seria DSE nr. 1627',
  'Banca Libra Bank Nr. 1827',
]), '1827', 'numarul Registrului Comertului nu devine numarul chitantei');
assert.equal('Chitata Serie/Nhonar: DI. 200861'.match(explicitNumber)[1], '200861',
  'varianta OCR Nhonar cu serie inline trebuie acceptata');

function completeDocument(text) {
  const up = text.toUpperCase();
  const chitanta = /CH[I1L][T7L][A-ZĂÂÎȘȚ]{3,}/i.test(up);
  if (chitanta) return up.includes('PRIMIT DE LA') && up.includes('SUMA');
  const header = /COD\s*FISCAL|CUI|NUMAR\s*BON|\bRO\d{6,10}\b/i.test(up);
  const body = /BON\s+FISCAL|(?<!SUB)\bTOTAL\b(?!\s*TVA)/i.test(up);
  return header && body;
}
assert.equal([
  'COD FISCAL RO34626689',
  'TOTAL 183,48 TOTAL TVA 31,84',
].every(completeDocument), false,
'un antet si un footer ale aceluiasi bon nu sunt doua documente autonome');
assert.equal([
  'COD FISCAL RO34626689 NUMAR BON 114 TOTAL 180,75 BON FISCAL',
  'CUI RO22254794 NUMAR BON 31 TOTAL 613,10 BON FISCAL',
].every(completeDocument), true,
'doua clustere complete pot fi acceptate ca documente distincte');

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

function isolatedCell(rects, index, pageW, pageH) {
  const a = rects[index], midX = r => r.x+r.w/2, midY = r => r.y+r.h/2;
  let left=0, top=0, right=pageW, bottom=pageH;
  rects.forEach((b,j) => {
    if (j===index) return;
    const yi=Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y);
    const xi=Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x);
    const yo=yi>0?yi/Math.min(a.h,b.h):0, xo=xi>0?xi/Math.min(a.w,b.w):0;
    let sx,sy;
    if(yo>.2&&xo<=.2){sx=true;sy=false}
    else if(xo>.2&&yo<=.2){sx=false;sy=true}
    else {const dx=Math.abs(midX(a)-midX(b))/Math.max(a.w,b.w,1),dy=Math.abs(midY(a)-midY(b))/Math.max(a.h,b.h,1);sx=dx>=dy;sy=dy>dx}
    if(sx){const m=(midX(a)+midX(b))/2;if(midX(b)<midX(a))left=Math.max(left,m);else right=Math.min(right,m)}
    if(sy){const m=(midY(a)+midY(b))/2;if(midY(b)<midY(a))top=Math.max(top,m);else bottom=Math.min(bottom,m)}
  });
  return {x:left,y:top,w:right-left,h:bottom-top};
}
const irregular = [
  {x:30,y:20,w:190,h:280}, {x:280,y:55,w:170,h:235},
  {x:80,y:350,w:180,h:230}, {x:340,y:390,w:145,h:200},
];
for (let i=0;i<irregular.length;i++) {
  const cell=isolatedCell(irregular,i,520,620), a=irregular[i];
  const cx=a.x+a.w/2,cy=a.y+a.h/2;
  assert.ok(cx>=cell.x&&cx<=cell.x+cell.w&&cy>=cell.y&&cy<=cell.y+cell.h,
    'celula izolata trebuie sa isi pastreze centrul documentului');
  irregular.forEach((b,j)=>{if(j!==i){const bx=b.x+b.w/2,by=b.y+b.h/2;assert.ok(!(bx>cell.x&&bx<cell.x+cell.w&&by>cell.y&&by<cell.y+cell.h),'celula izolata nu trebuie sa contina centrul vecinului')}});
}

const receiptSource = fs.readFileSync(path.join(root, 'OcrServer', 'ReceiptExtractor.swift'), 'utf8');
const routeSource = fs.readFileSync(path.join(root, 'OcrServer', 'VaporServer.swift'), 'utf8');
const chitantaSource = fs.readFileSync(path.join(root, 'OcrServer', 'ChitantaExtractor.swift'), 'utf8');
const anafSource = fs.readFileSync(path.join(root, 'OcrServer', 'AnafValidator.swift'), 'utf8');
const segmenterSource = fs.readFileSync(path.join(root, 'OcrServer', 'ReceiptSegmenterV2.swift'), 'utf8');
const recognizerSource = fs.readFileSync(path.join(root, 'OcrServer', 'TextRecognizerPro.swift'), 'utf8');
assert.match(receiptSource, /cota legala/,
  'cand cota TVA lipseste din OCR se foloseste cota legala la data documentului');
assert.match(receiptSource, /productLineTotal|derivat_din_articole/,
  'totalul poate fi reconstruit din articole / linia de produs');
assert.match(receiptSource, /Litri x pret|fuelTotal/,
  'combustibilul poate corecta totalul gresit');
assert.equal(receiptSource.includes('CAPITAL\\\\s+SOCIAL'), true,
  'capitalul social este exclus din sume');
assert.match(chitantaSource, /TRX/,
  'ID TRX/CHITANTA de pe bonuri nu trebuie clasificat ca chitanta');
assert.match(segmenterSource, /splitSideBySideDocuments/,
  'bonurile alaturate trebuie separate o singura data, la detectia initiala');
assert.match(routeSource, /func isolatedCell\(for index: Int\)/,
  'fiecare document trebuie sa primeasca o celula OCR izolata de vecini');
assert.match(routeSource, /cleanByTurns/,
  'zonele OCR curate trebuie reunite pe orientare inainte de segmentarea paginii');
assert.match(routeSource, /appendSegmented|ReceiptSegmenterV2\.segment/,
  'numarul documentelor finale trebuie stabilit dupa re-OCR la nivelul paginii');
assert.match(routeSource, /Fallback full-page re-OCR|fullClean/,
  'daca detectia pierde documente, exista fallback pe toata pagina');
assert.doesNotMatch(routeSource, /finalDetections\.reserveCapacity\(detections\.count\)/,
  'o zona initiala nu trebuie presupusa automat drept un singur document');
assert.match(routeSource, /for \(detIndex, det\) in detections\.enumerated\(\)/,
  'fiecare detectie fizica trebuie procesata exact o data');
assert.match(recognizerSource, /mapRectFromBase/,
  'celula izolata trebuie transformata corect in orice orientare OCR');
assert.match(recognizerSource, /cropRect requestedRect: CGRect[\s\S]*fallbackBoxes/,
  're-OCR-ul trebuie sa accepte dreptunghiul sigur si fallback-ul primei citiri');
assert.doesNotMatch(routeSource, /ReceiptSegmenterV2\.segment\(firstClean\)/,
  're-OCR-ul nu mai are voie sa fragmenteze din nou acelasi document');
assert.doesNotMatch(routeSource, /deduplicate\(refinedCandidates\)/,
  'deduplicarea dupa crop nu mai are voie sa elimine documente reale');
assert.doesNotMatch(routeSource, /expandDownward:/,
  'un crop nu se mai extinde liber in documentul de dedesubt');
assert.match(routeSource, /linesText: rawLines \+ hwLines/,
  'antetul tiparit trebuie sa aiba prioritate fata de OCR-ul de mana');
assert.match(routeSource, /vatAmounts\.reduce\(0, \+\)/,
  'TVA-ul cotelor multiple trebuie agregat');
assert.match(routeSource, /handwritingPass\(\s*on: rotImg,\s*clusterBoxes: clean\)/,
  'OCR-ul de mana trebuie limitat la documentul curent');
assert.match(routeSource, /focusedChitantaFieldsPass/,
  'campurile critice trebuie recitite separat la rezolutie marita');
assert.doesNotMatch(chitantaSource, /flatMap \{ FinExtract\.amounts\(in: \$0\) \}\.max\(\)/,
  'cea mai mare valoare de pe formular nu este un fallback sigur');
assert.equal(chitantaSource.includes('RAMBURS\\\\s+CONT\\\\s+COLECTOR'), true,
  'chitanta FAN trebuie clasificata dupa semantica documentului');
assert.match(chitantaSource, /repairedAmountCandidates/,
  'sumele scrise de mana trebuie reparate contextual, nu trunchiate');
assert.doesNotMatch(chitantaSource, /Set\(exactAmountCandidates\)\)\.sorted/,
  'sumele candidate nu trebuie sortate crescator');
assert.match(chitantaSource, /explicitNumberRx/,
  'Numar/Nouar trebuie sa aiba prioritate fata de nr. din adresa');
assert.match(chitantaSource, /payerIdRx/,
  'CUI-ul platitorului trebuie izolat de numarul Registrului Comertului');
assert.match(chitantaSource, /SRONAR/,
  'eticheta Numar degradata de OCR trebuie acceptata fara valori hardcodate');
assert.match(chitantaSource, /degradedTitle/,
  'titlul de chitanta cu prima litera pierduta trebuie clasificat semantic');
assert.match(receiptSource, /"P": "0"/,
  'P citit in CUI-ul MOL trebuie tratat ca ipoteza OCR pentru zero');
assert.match(receiptSource, /\[%X/,
  'X citit in locul semnului procent trebuie acceptat numai in context TVA');
assert.match(anafSource, /found\.count == 1/,
  'unicul candidat confirmat ANAF trebuie folosit pentru repararea CUI');
assert.match(anafSource, /confirmat_anaf/,
  'CUI valid gasit la ANAF este confirmat chiar daca antetul OCR e zgomotos');

// --- Extractie end-to-end pe dump-ul real (ground truth 6 bonuri) ---
const { extract } = require('./extract_node');

const bonuriV5ForExtract = JSON.parse(fs.readFileSync(
  path.join(__dirname, 'cases', 'bonuri_feedback_v5.txt'), 'utf8'));
const extractClusters = segment(bonuriV5ForExtract);
assert.equal(extractClusters.length, 6, 'extractie: 6 clustere');

const extracted = extractClusters.map(c => {
  const lines = groupLines(c);
  const text = lines.join(' ');
  assert.equal(looksLikeSingleChitanta(c), false,
    'niciun cluster din poza de bonuri nu e chitanta: ' + text.slice(0, 40));
  return { text, result: extract(lines) };
});

function findExtract(re) {
  for (let i = 0; i < extracted.length; i++) {
    if (re.test(extracted[i].text)) return { i, ...extracted[i] };
  }
  return null;
}

for (const exp of [
  { key: /DOUGLAS/i, total: 613.10, vat: 106.41, cui: '22254794' },
  { key: /MOL ROMANIA|PETROLEUM/i, total: 188.16, vat: 32.66, cui: '7745470' },
  { key: /TURIST/i, total: 181.15, vat: 31.44, cui: '7709175' },
]) {
  const hit = findExtract(exp.key);
  assert.ok(hit, 'lipsa document: ' + exp.key);
  assert.equal(hit.result.total, exp.total,
    `total ${exp.key} asteptat ${exp.total}, gasit ${hit.result.total}`);
  assert.ok(Math.abs((hit.result.vat || 0) - exp.vat) <= 0.06,
    `TVA ${exp.key} asteptat ${exp.vat}, gasit ${hit.result.vat}`);
  if (exp.cui) assert.equal(hit.result.cui, exp.cui, `CUI ${exp.key}`);
}

const rog = findExtract(/146[.,]26|R046953|35[.,]5\s*L/i);
assert.ok(rog, 'ROG GAZ trebuie extras');
assert.equal(rog.result.total, 146.26, 'ROG total din litri x pret');
assert.ok(Math.abs((rog.result.vat || 0) - 25.38) <= 0.06, 'ROG TVA ' + rog.result.vat);

const mag = extracted.filter(e => /MAGISTRAL/i.test(e.text) && /34626689/.test(e.text));
assert.equal(mag.length, 2, 'doua bonuri Magistral');
const magTotals = mag.map(m => m.result.total).sort((a, b) => a - b);
assert.deepEqual(magTotals, [180.75, 183.48], 'totaluri Magistral');

const molWords = extractClusters.find(c => /MOL/i.test(groupLines(c).join(' ')));
assert.equal(looksLikeSingleChitanta(molWords), false, 'MOL cu TRX/CHITANTA ramane bon fiscal');

const chitV5 = JSON.parse(fs.readFileSync(
  path.join(__dirname, 'cases', 'chitante_feedback_v5.txt'), 'utf8'));
let pb = 1, lr = -Infinity;
for (let i = 1; i < chitV5.length; i++) {
  const reset = chitV5[i - 1].y - chitV5[i].y;
  if (reset > lr) { lr = reset; pb = i; }
}
const amerisCluster = segment(chitV5.slice(pb)).find(c =>
  /AMERIS/i.test(groupLines(c).join(' ')));
assert.ok(amerisCluster, 'Ameris pe pagina 2');
const amerisExt = extract(groupLines(amerisCluster));
assert.equal(amerisExt.total, 420.45, 'Ameris total');
assert.ok(Math.abs((amerisExt.vat || 0) - 44.67) <= 0.15,
  'Ameris TVA multi-cota ~44.67 got ' + amerisExt.vat);

console.log('OK: toate regresiile universale au trecut.');
console.log('OK: extractie ground-truth 6 bonuri + Ameris multi-TVA.');
