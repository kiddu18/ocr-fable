//
//  RoAccounting.swift
//  OcrServer
//
//  Incadrare contabila + generarea notei contabile (monografie) pentru bonuri
//  fiscale, conform planului de conturi romanesc (OMFP 1802/2014).
//
//  Conturi folosite:
//   6022 Cheltuieli privind combustibilii     3022 Combustibili (daca se stocheaza)
//   604  Materiale nestocate                  303  Obiecte de inventar
//   623  Protocol, reclama si publicitate     628  Alte cheltuieli cu serviciile
//   4426 TVA deductibila                      401  Furnizori
//   5311 Casa in lei                          5121 Conturi la banci in lei
//   5125 Sume in curs de decontare            542  Avansuri de trezorerie
//

import Foundation

enum RoAccounting {

    struct Classification {
        let accountCode: String      // ex. "6022"
        let account: String          // ex. "6022 Cheltuieli privind combustibilii"
        let note: String?
        let vatDeductibility: String // ex. "100%" sau "50% (art. 298 Cod fiscal)"
    }

    static func classify(fullText: String) -> Classification {
        let t = fullText.uppercased()

        if t.range(of: "MOTORINA|BENZINA|\\bGPL\\b|DIESEL|ADBLUE|OMV|PETROM|\\bMOL\\b|ROMPETROL|LUKOIL|SOCAR|GAZ\\s+SRL",
                   options: .regularExpression) != nil {
            return Classification(
                accountCode: "6022",
                account: "6022 Cheltuieli privind combustibilii (3022 daca se stocheaza)",
                note: "Vehicul neutilizat exclusiv economic: TVA deductibila 50% si cheltuiala deductibila 50% "
                    + "(art. 298 si art. 25 alin. (3) lit. l) Cod fiscal). Cu foaie de parcurs: 100%.",
                vatDeductibility: "50% fara foaie de parcurs / 100% cu foaie de parcurs (art. 298 CF)")
        }
        if t.range(of: "PARFUMERIE|DOUGLAS|SEPHORA|\\bCADOU|NOTINO", options: .regularExpression) != nil {
            return Classification(
                accountCode: "623",
                account: "623 Protocol (sau 6588 Alte cheltuieli, dupa destinatie)",
                note: "Protocol: deductibil limitat la 2% din profitul contabil ajustat (impozit pe profit). "
                    + "Cadouri: TVA deductibila doar in plafonul de 100 lei/beneficiar (art. 270 alin. (8) lit. b) CF).",
                vatDeductibility: "limitat (plafon cadouri 100 lei/beneficiar)")
        }
        if t.range(of: "RESTAURANT|CATERING|CAFENEA|PIZZA|BISTRO|FAST\\s?FOOD", options: .regularExpression) != nil {
            return Classification(
                accountCode: "623",
                account: "623 Protocol",
                note: "Atentie: pe acelasi bon mancarea/serviciul de restaurant e la 11%, alcoolul la 21% — verifica liniile TVA.",
                vatDeductibility: "limitat (protocol)")
        }
        if t.range(of: "PAPETARIE|BIROTICA|EMAG|ALTEX|DEDEMAN|HORNBACH|LEROY", options: .regularExpression) != nil {
            return Classification(
                accountCode: "604",
                account: "604 Materiale nestocate / 303 Obiecte de inventar",
                note: "Obiectele cu durata de folosinta > 1 an dar sub plafonul de imobilizare merg pe 303.",
                vatDeductibility: "100%")
        }
        if t.range(of: "FARMACIE|CATENA|HELP\\s?NET|SENSIBLU|DR\\.?\\s?MAX", options: .regularExpression) != nil {
            return Classification(
                accountCode: "604",
                account: "604 Materiale nestocate (truse medicale) / 6458 dupa destinatie",
                note: "Medicamentele pentru uz personal nu sunt deductibile pe firma.",
                vatDeductibility: "dupa destinatie")
        }
        return Classification(
            accountCode: "628",
            account: "628 Alte cheltuieli cu serviciile / 604 Materiale nestocate",
            note: "Necesita incadrare manuala.",
            vatDeductibility: "de stabilit")
    }

    /// Nota contabila propusa. Varianta generata presupune deducere integrala a TVA;
    /// limitarile (50% combustibil, plafon protocol) sunt semnalate in label si note.
    static func entries(total: Double?, vat: Double, accountCode: String,
                        paymentMethod: String?, vatDeductibility: String) -> [AccountingEntryDTO] {
        guard let total, total > 0 else { return [] }
        let vatAmount = min(max(vat, 0), total).ron2
        let base = (total - vatAmount).ron2

        var out: [AccountingEntryDTO] = []
        out.append(AccountingEntryDTO(debit: accountCode, credit: "401",
                                      amount: base, label: "Valoare fara TVA"))
        if vatAmount > 0 {
            out.append(AccountingEntryDTO(debit: "4426", credit: "401", amount: vatAmount,
                                          label: "TVA deductibila — \(vatDeductibility)"))
        }
        let payingAccount = (paymentMethod == "numerar") ? "5311" : "5125"
        let payLabel = (paymentMethod == "numerar")
            ? "Plata numerar (casa)"
            : "Plata card (5125 sume in curs; foloseste 5121 la card de firma sau 542 la decontul angajatului)"
        out.append(AccountingEntryDTO(debit: "401", credit: payingAccount,
                                      amount: total.ron2, label: payLabel))
        return out
    }
}
