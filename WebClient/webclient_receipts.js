//
// webclient_receipts.js
// Patch pentru WebClient: randeaza TOATE bonurile din campul `receipts`
// al raspunsului /upload, nu doar `accounting_data` (care era doar primul bon).
//
// Integrare:
//   1. In HTML, sub zona de rezultat existenta, adauga:  <div id="receipts"></div>
//   2. Include acest fisier si, dupa ce primesti raspunsul JSON, apeleaza:
//        renderReceipts(json);
//

function renderReceipts(json) {
  const host = document.getElementById("receipts");
  if (!host) return;
  host.innerHTML = "";

  const receipts = json.receipts || [];
  if (!receipts.length) {
    host.innerHTML = "<p>Nu a fost detectat niciun bon.</p>";
    return;
  }

  const header = document.createElement("p");
  header.textContent = receipts.length + " bonuri detectate";
  header.style.fontWeight = "600";
  host.appendChild(header);

  const money = (v) =>
    v == null ? "—" : Number(v).toFixed(2).replace(".", ",") + " lei";

  for (const r of receipts) {
    const card = document.createElement("div");
    card.style.cssText =
      "border:1px solid #ccc;border-radius:8px;padding:12px;margin:10px 0;" +
      "font-family:system-ui,sans-serif;font-size:14px;line-height:1.5";

    const name = r.anaf && r.anaf.denumire ? r.anaf.denumire : (r.merchantNameOCR || "Comerciant necunoscut");
    const anafBadge = badgeForStatus(r.anaf ? r.anaf.status : "neverificat");
    const conf = r.confidence != null ? Math.round(r.confidence * 100) + "%" : "—";

    let html =
      "<div style='display:flex;justify-content:space-between;align-items:baseline'>" +
      "<strong>" + esc(name) + "</strong>" + anafBadge + "</div>" +
      row("CUI", r.cui ? "RO " + esc(r.cui) : (r.cuiOCR ? esc(r.cuiOCR) + " (necitit sigur)" : "—")) +
      row("Bon nr. / Data", (r.bonNumber || "—") + " / " + (r.date || "—") + (r.time ? " " + r.time : "")) +
      row("Total", "<b>" + money(r.total) + "</b>" +
        (r.totalSource === "derivat_din_tva" ? " <i>(derivat din TVA, exista pe bon)</i>" : "")) +
      (r.vatLines || []).map(v =>
        row("TVA " + v.rate + "%", money(v.amount) + (v.base != null ? " (baza " + money(v.base) + ")" : ""))
      ).join("") +
      row("Plata", r.paymentMethod || "—") +
      (r.fuelLiters ? row("Carburant", esc(r.productHint || "") + " — " + r.fuelLiters + " L x " + r.fuelUnitPrice + " lei/L") : "") +
      row("Cont sugerat", esc(r.suggestedAccount || "—")) +
      (r.vatDeductibility ? row("Deducere TVA", esc(r.vatDeductibility)) : "") +
      (r.isSimplifiedInvoice
        ? row("Regim", "Factura simplificata (CUI-ul cumparatorului e pe bon" +
              (r.buyerName ? ": " + esc(r.buyerName) : "") + ")")
        : "") +
      row("Verificare matematica", r.mathVerified ? "OK ✓" : "NU — verifica manual") +
      row("Incredere", conf);

    if (r.entries && r.entries.length) {
      html += "<details style='margin-top:6px'><summary>Nota contabila propusa</summary><table style='margin-top:4px'>";
      for (const e of r.entries) {
        html += "<tr><td style='padding-right:8px'>" + esc(e.debit) + " = " + esc(e.credit) +
                "</td><td style='padding-right:8px;text-align:right'>" + money(e.amount) +
                "</td><td style='color:#666'>" + esc(e.label) + "</td></tr>";
      }
      html += "</table></details>";
    }

    if (r.accountingNote) {
      html += "<p style='color:#666;margin:6px 0 0'>" + esc(r.accountingNote) + "</p>";
    }

    if (r.warnings && r.warnings.length) {
      html += "<ul style='color:#b45309;margin:6px 0 0;padding-left:18px'>" +
        r.warnings.map(w => "<li>" + esc(w) + "</li>").join("") + "</ul>";
    }

    html += "<details style='margin-top:6px'><summary>Text OCR brut</summary><pre style='white-space:pre-wrap'>" +
            esc(r.rawText || "") + "</pre></details>";

    card.innerHTML = html;
    host.appendChild(card);
  }

  function row(label, value) {
    return "<div><span style='color:#666'>" + label + ":</span> " + value + "</div>";
  }

  function badgeForStatus(status) {
    const map = {
      confirmat_anaf: ["Confirmat ANAF", "#16a34a"],
      confirmat_anaf_reparat: ["Confirmat ANAF (CUI reparat)", "#16a34a"],
      cui_gasit_nume_diferit_verifica_manual: ["Nume diferit la ANAF!", "#dc2626"],
      cui_incert_necesita_verificare: ["CUI incert", "#d97706"],
      cui_negasit_anaf: ["Negasit la ANAF", "#dc2626"],
      fara_cui: ["Fara CUI", "#dc2626"],
      neverificat: ["Neverificat", "#6b7280"],
    };
    const [text, color] = map[status] || map.neverificat;
    return "<span style='font-size:12px;color:#fff;background:" + color +
           ";border-radius:10px;padding:2px 8px;margin-left:8px'>" + text + "</span>";
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
}

// Chitante de mana: randare cu AMBELE parti (emitent + platitor).
// Apeleaza renderChitante(json) dupa renderReceipts(json); cere <div id="chitante"></div>.
function renderChitante(json) {
  const host = document.getElementById("chitante");
  if (!host) return;
  host.innerHTML = "";
  const list = json.chitante || [];
  if (!list.length) return;

  const money = (v) => v == null ? "—" : Number(v).toFixed(2).replace(".", ",") + " lei";
  const esc = (s) => String(s).replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const row = (l, v) => "<div><span style='color:#666'>" + l + ":</span> " + v + "</div>";
  const party = (label, nume, cui, cuiValid, anaf) => {
    const anafName = anaf && anaf.denumire ? esc(anaf.denumire) : null;
    let badge = "";
    if (anaf && anaf.found) badge = " <span style='font-size:12px;color:#fff;background:#16a34a;border-radius:10px;padding:1px 7px'>ANAF ✓</span>";
    else if (cuiValid) badge = " <span style='font-size:12px;color:#fff;background:#6b7280;border-radius:10px;padding:1px 7px'>checksum ✓</span>";
    else if (cui) badge = " <span style='font-size:12px;color:#fff;background:#d97706;border-radius:10px;padding:1px 7px'>neconfirmat</span>";
    return row(label, "<b>" + esc(anafName || nume || "—") + "</b>" +
      (cui ? " — CUI " + esc(cui) : "") + badge);
  };

  const header = document.createElement("p");
  header.textContent = list.length + " chitante detectate";
  header.style.fontWeight = "600";
  host.appendChild(header);

  for (const c of list) {
    const card = document.createElement("div");
    card.style.cssText =
      "border:1px solid #ccc;border-radius:8px;padding:12px;margin:10px 0;" +
      "font-family:system-ui,sans-serif;font-size:14px;line-height:1.5";

    const sumaBadge = c.sumaConfirmata
      ? " <span style='font-size:12px;color:#fff;background:#16a34a;border-radius:10px;padding:1px 7px'>confirmata: cifre = litere</span>"
      : " <span style='font-size:12px;color:#fff;background:#d97706;border-radius:10px;padding:1px 7px'>fara dubla validare</span>";

    let html =
      "<div style='display:flex;justify-content:space-between;align-items:baseline'>" +
      "<strong>Chitanta " + esc(c.numar ? "nr. " + c.numar : "") +
      (c.serie ? " seria " + esc(c.serie) : "") + "</strong>" +
      (c.directie ? "<span style='color:#666'>" + (c.directie === "incasare" ? "INCASARE" : "PLATA") + "</span>" : "") +
      "</div>" +
      party("A primit (emitent)", c.emitentNume, c.emitentCui, c.emitentCuiValid, c.emitentAnaf) +
      (c.emitentRegCom ? row("Reg. Com.", esc(c.emitentRegCom)) : "") +
      party("De la (platitor)", c.platitorNume, c.platitorCui || c.platitorCnp, c.platitorCuiValid, c.platitorAnaf) +
      row("Data", c.date || "—") +
      row("Suma", "<b>" + money(c.suma) + "</b>" + sumaBadge) +
      (c.sumaLitereText ? row("In litere", "<i>" + esc(c.sumaLitereText) + "</i>" +
        (c.sumaLitere != null ? " = " + money(c.sumaLitere) : "")) : "") +
      (c.reprezentand ? row("Reprezentand", esc(c.reprezentand)) : "") +
      (c.facturaReferinta ? row("Factura referita", esc(c.facturaReferinta)) : "") +
      row("Cont", esc(c.suggestedAccount || "—"));

    if (c.entries && c.entries.length) {
      html += "<table style='margin-top:4px'>";
      for (const e of c.entries) {
        html += "<tr><td style='padding-right:8px'>" + esc(e.debit) + " = " + esc(e.credit) +
                "</td><td style='padding-right:8px;text-align:right'>" + money(e.amount) +
                "</td><td style='color:#666'>" + esc(e.label) + "</td></tr>";
      }
      html += "</table>";
    }
    if (c.accountingNote) html += "<p style='color:#666;margin:6px 0 0'>" + esc(c.accountingNote) + "</p>";
    if (c.warnings && c.warnings.length) {
      html += "<ul style='color:#b45309;margin:6px 0 0;padding-left:18px'>" +
        c.warnings.map(w => "<li>" + esc(w) + "</li>").join("") + "</ul>";
    }
    card.innerHTML = html;
    host.appendChild(card);
  }
}
