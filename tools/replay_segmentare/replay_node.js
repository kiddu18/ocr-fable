#!/usr/bin/env node
// Replay executabil pe Windows pentru ReceiptSegmenterV2.swift.
// Nu face OCR; foloseste dump-ul real /debug_boxes si reproduce geometria pipeline-ului.

const fs = require('node:fs');

function medianHeight(words) {
  const hs = words.map(w => w.h).sort((a, b) => a - b);
  return Math.max(hs[Math.floor(hs.length / 2)] || 4, 4);
}

function normalizeOrientation(raw) {
  const words = raw.map(b => ({
    text: String(b.text ?? b.t ?? ''), x: +b.x, y: +b.y, w: +b.w, h: +b.h,
  }));
  const vertical = words.filter(b => b.h > b.w && b.text.length > 2).length;
  if (vertical <= words.length / 2) return words;
  const hMax = Math.max(...words.map(b => b.y + b.h));
  return words.map(b => ({ text: b.text, x: hMax - (b.y + b.h), y: b.x, w: b.h, h: b.w }));
}

function linesWithY(words) {
  if (!words.length) return [];
  const mh = medianHeight(words);
  const sorted = [...words].sort((a, b) => (a.y + a.h / 2) - (b.y + b.h / 2) || a.x - b.x);
  const lines = [], centers = [];
  for (const word of sorted) {
    const center = word.y + word.h / 2;
    if (centers.length && Math.abs(center - centers.at(-1)) < mh * 0.7) {
      lines.at(-1).push(word);
      const n = lines.at(-1).length;
      centers[centers.length - 1] = (centers.at(-1) * (n - 1) + center) / n;
    } else {
      lines.push([word]); centers.push(center);
    }
  }
  return lines.map((line, i) => ({
    y: centers[i], words: line.sort((a, b) => a.x - b.x),
    text: line.sort((a, b) => a.x - b.x).map(w => w.text).join(' '),
  }));
}

const groupLines = words => linesWithY(words).map(l => l.text);
function bbox(words) {
  return {
    minX: Math.min(...words.map(w => w.x)), minY: Math.min(...words.map(w => w.y)),
    maxX: Math.max(...words.map(w => w.x + w.w)), maxY: Math.max(...words.map(w => w.y + w.h)),
  };
}

function xycut(words, minGapX, minGapY, out) {
  if (words.length < 10) { out.push(words); return; }
  function bestGap(axis) {
    const intervals = words.map(w => axis === 'x' ? [w.x, w.x + w.w] : [w.y, w.y + w.h])
      .sort((a, b) => a[0] - b[0]);
    const merged = [intervals[0].slice()];
    for (const [a, b] of intervals.slice(1)) {
      if (a <= merged.at(-1)[1] + 2) merged.at(-1)[1] = Math.max(merged.at(-1)[1], b);
      else merged.push([a, b]);
    }
    let best = null;
    for (let i = 0; i < merged.length - 1; i++) {
      const gap = merged[i + 1][0] - merged[i][1];
      if (!best || gap > best.size) best = { size: gap, split: (merged[i][1] + merged[i + 1][0]) / 2 };
    }
    return best;
  }
  const gx = bestGap('x'), gy = bestGap('y');
  const sx = gx?.size ?? 0, sy = gy?.size ?? 0;
  if (sx < minGapX && sy < minGapY) { out.push(words); return; }
  if (sx / minGapX >= sy / minGapY && gx) {
    xycut(words.filter(w => w.x + w.w / 2 < gx.split), minGapX, minGapY, out);
    xycut(words.filter(w => w.x + w.w / 2 >= gx.split), minGapX, minGapY, out);
  } else if (gy) {
    xycut(words.filter(w => w.y + w.h / 2 < gy.split), minGapX, minGapY, out);
    xycut(words.filter(w => w.y + w.h / 2 >= gy.split), minGapX, minGapY, out);
  } else out.push(words);
}

const repair = s => s.toUpperCase().replace(/[OQDIL|ZSBG@]/g, c => ({O:'0',Q:'0',D:'0',I:'1',L:'1','|':'1',Z:'2',S:'5',B:'8',G:'6','@':'0'}[c]));
const ctx = /(?:COD\s*FISCAL|COD\s*IDENTIFICARE\s*FISCALA|\bC\.?\s*I\.?\s*F\b|\bCUI\b)\s*[.:]?\s*(?:R[O0])?\s*([0-9OQDILSZB@]{4,12})/ig;
const excl = /CLIENT|CNP|CUMPARATOR|BENEF/i;
const strong = /NUMAR\s*BON|COD\s*FISCAL|COD\s*IDENTIFICARE\s*FISCALA|\bR[O0]\s?\d{6,10}\b/i;
const anchor = /NUMAR\s*BON|COD\s*FISCAL|COD\s*IDENTIFICARE\s*FISCALA|\bC\.?\s*I\.?\s*F\b|\bCUI\b|\bR[O0]\s?\d{6,10}\b|\b(?:S\.?\s?R\.?\s?L\.?|S\.?A\.?|P\.?F\.?A\.?)\b/i;
const chitantaTitle = /\bCH[I1L][T7L][A-ZĂÂÎȘȚ]{3,}\b|(?:SERIE|SERIA|SERIC)\s*[\/-]?\s*(?:NUMAR|NWUAR|NOMAR|TOMNAR|ANAR)/i;

function looksLikeSingleChitanta(words) {
  const text = groupLines(words).join(' ').toUpperCase();
  if (/BON\s+FISCAL|TOTAL\s*TVA|CASA\s+DE\s+MARCAT/i.test(text)) return false;
  return chitantaTitle.test(text) || (text.includes('PRIMIT DE LA') && text.includes('SUMA'));
}

function merchantCuis(words) {
  const result = new Set();
  for (const line of groupLines(words)) {
    if (excl.test(line)) continue;
    ctx.lastIndex = 0;
    for (const m of line.matchAll(ctx)) {
      const digits = repair(m[1]).replace(/\D/g, '');
      if (digits.length >= 4) result.add(digits);
    }
  }
  return result;
}

const hasFiscalHeader = words => groupLines(words).some(line =>
  chitantaTitle.test(line) || (strong.test(line) && !excl.test(line)));
const looksLikeReceipt = words => merchantCuis(words).size > 0
  || groupLines(words).some(l => /NUMAR\s*BON/i.test(l) || chitantaTitle.test(l));

function mergeFragments(parts, mh) {
  const merged = parts.map(p => [...p]);
  let changed = true;
  while (changed) {
    changed = false;
    outer: for (let i = 0; i < merged.length; i++) for (let j = i + 1; j < merged.length; j++) {
      const a = bbox(merged[i]), b = bbox(merged[j]);
      const inter = Math.min(a.maxX, b.maxX) - Math.max(a.minX, b.minX);
      const minW = Math.min(a.maxX - a.minX, b.maxX - b.minX);
      const overlap = inter > 0 && minW > 0 ? inter / minW : 0;
      const vGap = Math.max(b.minY - a.maxY, a.minY - b.maxY, 0);
      const ta = groupLines(merged[i]).join(' ').toUpperCase();
      const tb = groupLines(merged[j]).join(' ').toUpperCase();
      const aTitle = chitantaTitle.test(ta), bTitle = chitantaTitle.test(tb);
      const aBody = ta.includes('PRIMIT DE LA') && ta.includes('SUMA');
      const bBody = tb.includes('PRIMIT DE LA') && tb.includes('SUMA');
      const hasBon = /BON\s+FISCAL|TOTAL\s*TVA|CASA\s+DE\s+MARCAT/i.test(`${ta} ${tb}`);
      const yInter = Math.min(a.maxY, b.maxY) - Math.max(a.minY, b.minY);
      const minH = Math.min(a.maxY - a.minY, b.maxY - b.minY);
      const yOverlap = yInter > 0 && minH > 0 ? yInter / minH : 0;
      const hGap = Math.max(b.minX - a.maxX, a.minX - b.maxX, 0);
      if (!hasBon && ((aTitle && bBody) || (bTitle && aBody)) && yOverlap > .25 && hGap < mh * 45) {
        merged[i].push(...merged[j]); merged.splice(j, 1); changed = true; break outer;
      }
      if (looksLikeReceipt(merged[i]) && looksLikeReceipt(merged[j])) continue;
      const ca = merchantCuis(merged[i]), cb = merchantCuis(merged[j]);
      if (ca.size && cb.size && [...ca].every(x => !cb.has(x))) continue;
      if (overlap > 0.5 && vGap < mh * 4) {
        merged[i].push(...merged[j]); merged.splice(j, 1); changed = true; break outer;
      }
    }
  }
  return merged;
}

function splitByAnchors(cluster, mh) {
  const lines = linesWithY(cluster);
  const selectedAnchor = looksLikeSingleChitanta(cluster) ? chitantaTitle : anchor;
  const ys = lines.filter(l => selectedAnchor.test(l.text) && !excl.test(l.text)).map(l => l.y).sort((a,b) => a-b);
  const groups = [];
  for (const y of ys) if (!groups.length || y - groups.at(-1) >= mh * 12) groups.push(y);
  if (groups.length < 2) return [cluster];
  const cuts = [];
  for (let k = 0; k < groups.length - 1; k++) {
    const lo = groups[k], hi = groups[k+1];
    const seq = [lo, ...lines.map(l=>l.y).filter(y=>y>lo&&y<hi).sort((a,b)=>a-b), hi];
    let gap = -1, cut = (lo + hi) / 2;
    for (let i=0;i<seq.length-1;i++) if(seq[i+1]-seq[i]>gap){gap=seq[i+1]-seq[i];cut=(seq[i]+seq[i+1])/2;}
    cuts.push(cut);
  }
  const parts = Array.from({length:cuts.length+1},()=>[]);
  for(const w of cluster){let k=0;cuts.forEach((c,i)=>{if(w.y+w.h/2>=c)k=i+1});parts[k].push(w);}
  return parts.filter(p=>p.length>=10);
}

function strongGroupCount(cluster,mh){
  const ys=linesWithY(cluster).filter(l=>strong.test(l.text)&&!excl.test(l.text)).map(l=>l.y).sort((a,b)=>a-b);
  let groups=0,last=-Infinity;for(const y of ys){if(y-last>=mh*14)groups++;last=y;}return groups;
}
function chitantaHeaderGroupCount(cluster,mh){
  const ys=linesWithY(cluster).filter(l=>chitantaTitle.test(l.text)).map(l=>l.y).sort((a,b)=>a-b);
  let groups=0,last=-Infinity;for(const y of ys){if(y-last>=mh*10)groups++;last=y;}return groups;
}
function bestGap(cluster,axis){
  const iv=cluster.map(w=>axis==='x'?[w.x,w.x+w.w]:[w.y,w.y+w.h]).sort((a,b)=>a[0]-b[0]);
  const mg=[iv[0].slice()];for(const [a,b] of iv.slice(1)){if(a<=mg.at(-1)[1]+2)mg.at(-1)[1]=Math.max(mg.at(-1)[1],b);else mg.push([a,b]);}
  let best=null;for(let i=0;i<mg.length-1;i++){const size=mg[i+1][0]-mg[i][1];if(!best||size>best.size)best={size,split:(mg[i][1]+mg[i+1][0])/2};}return best;
}
function forceSplit(cluster,mh,needBoth){
  const gx=bestGap(cluster,'x'),gy=bestGap(cluster,'y'),cs=[];if(gx&&gx.size>=mh*.5)cs.push(['x',gx]);if(gy&&gy.size>=mh*.8)cs.push(['y',gy]);
  for(const [axis,g] of cs.sort((a,b)=>b[1].size-a[1].size)){const lo=cluster.filter(w=>(axis==='x'?w.x+w.w/2:w.y+w.h/2)<g.split),hi=cluster.filter(w=>(axis==='x'?w.x+w.w/2:w.y+w.h/2)>=g.split);if(lo.length>=10&&hi.length>=10&&(!needBoth||(hasFiscalHeader(lo)&&hasFiscalHeader(hi))))return[lo,hi];}return null;
}
function enforceOneHeader(cluster,mh,depth=0){const isChitanta=looksLikeSingleChitanta(cluster),multiCui=!isChitanta&&merchantCuis(cluster).size>=2,multiHdr=isChitanta?chitantaHeaderGroupCount(cluster,mh)>=2:strongGroupCount(cluster,mh)>=2;if(depth>6||(!multiCui&&!multiHdr))return[cluster];const split=forceSplit(cluster,mh,!multiCui);return split?[...enforceOneHeader(split[0],mh,depth+1),...enforceOneHeader(split[1],mh,depth+1)]:[cluster];}

function absorbOrphans(clusters,mh){const anchored=clusters.filter(hasFiscalHeader),orphans=clusters.filter(c=>!hasFiscalHeader(c));if(!anchored.length)return clusters;for(const o of orphans){const ob=bbox(o);let bi=-1,bk=[Infinity,Infinity];anchored.forEach((a,i)=>{const ab=bbox(a),inter=Math.min(ob.maxX,ab.maxX)-Math.max(ob.minX,ab.minX),minw=Math.min(ob.maxX-ob.minX,ab.maxX-ab.minX),xo=inter>0&&minw>0?inter/minw:0,vg=Math.max(ab.minY-ob.maxY,ob.minY-ab.maxY,0),hg=Math.max(ab.minX-ob.maxX,ob.minX-ab.maxX,0),key=[xo>.3?0:1,xo>.3?vg:Math.hypot(vg,hg)];if(key[0]<bk[0]||(key[0]===bk[0]&&key[1]<bk[1])){bk=key;bi=i;}});if(bi>=0&&bk[1]<=mh*20)anchored[bi].push(...o);}return anchored;}

function segment(words){const mh=medianHeight(words),parts=[];xycut(words,mh,mh*1.5,parts);let m=mergeFragments(parts.filter(p=>p.length>=8||chitantaTitle.test(groupLines(p).join(' '))),mh).flatMap(p=>splitByAnchors(p,mh)).flatMap(p=>enforceOneHeader(p,mh));m=absorbOrphans(m,mh);return m.filter(p=>p.length>=12).sort((a,b)=>Math.floor(bbox(a).minX/400)-Math.floor(bbox(b).minX/400)||bbox(a).minY-bbox(b).minY);}

function describe(clusters){console.log(`clusters=${clusters.length}`);clusters.forEach((c,i)=>{const b=bbox(c),text=groupLines(c).join(' | '),names=[...new Set((text.match(/MAGISTRAL|MOL|DOUGLAS|TURIST|ROG|DAISY|AMERIS|DONA|FAN/ig)||[]).map(x=>x.toUpperCase()))];console.log(`${i}: n=${c.length} x=${b.minX.toFixed(0)}-${b.maxX.toFixed(0)} y=${b.minY.toFixed(0)}-${b.maxY.toFixed(0)} names=${names.join(',')} cuis=${[...merchantCuis(c)].join(',')}`);});}

if (require.main === module) {
  const file=process.argv[2];
  if(!file)throw new Error('Usage: node replay_node.js <debug_boxes.txt>');
  const raw=JSON.parse(fs.readFileSync(file,'utf8'));
  describe(segment(normalizeOrientation(raw)));
}

module.exports = { normalizeOrientation, segment, groupLines, bbox, merchantCuis,
  looksLikeSingleChitanta };
