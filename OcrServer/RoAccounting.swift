//
//  RoAccounting.swift
//  OcrServer
//
//  Motor de RECOMANDARI de conturi contabile pentru bonuri fiscale,
//  conform planului de conturi OMFP 1802/2014 si practicii contabile RO.
//
//  Cum functioneaza: regulile de mai jos se parcurg IN ORDINE si castiga
//  prima care se potriveste pe textul complet al bonului (antet + produse).
//  Ordinea conteaza: categoriile specifice stau inaintea celor generale.
//
//  Sugestia e o RECOMANDARE — incadrarea finala apartine contabilului;
//  de aceea fiecare regula vine cu nota de deductibilitate si avertizari.
//  Peste aceste sugestii, clientul web aplica "Regulile de conturi" locale
//  ale utilizatorului (cuvant cheie -> cont), care au prioritate.
//

import Foundation

enum RoAccounting {

    struct Classification {
        let accountCode: String      // ex. "6022"
        let account: String          // ex. "6022 Cheltuieli privind combustibilii"
        let note: String?
        let vatDeductibility: String // ex. "100%" sau "50% (art. 298 CF)"
    }

    private struct Rule {
        let pattern: String          // regex, case-insensitive, pe textul complet
        let cls: Classification
    }

    /// Regulile, de la specific la general.
    private static let rules: [Rule] = [

        // --- COMBUSTIBIL — 6022 ---
        Rule(pattern: "MOTORINA|BENZINA|\\bGPL\\b|DIESEL|ADBLUE|CARBURANT|\\bOMV\\b|PETROM|\\bMOL\\b|ROMPETROL|LUKOIL|SOCAR|GAZPROM|\\bAVIA\\b",
             cls: Classification(
                accountCode: "6022",
                account: "6022 Cheltuieli privind combustibilii",
                note: "Vehicul neutilizat exclusiv economic: TVA si cheltuiala deductibile 50% "
                    + "(art. 298 si art. 25 alin. (3) lit. l) CF). Cu foaie de parcurs: 100%.",
                vatDeductibility: "50% fara foaie de parcurs / 100% cu foaie de parcurs")),

        // --- ENERGIE, APA — 605 ---
        Rule(pattern: "\\bENEL\\b|E\\.?ON|ENGIE|ELECTRICA|HIDROELECTRICA|CEZ\\b|PPC\\b|APA\\s?NOVA|APAVITAL|COMPANIA\\s+DE\\s+APA|ENERGIE\\s+ELECTRICA|GAZE\\s+NATURALE",
             cls: Classification(
                accountCode: "605",
                account: "605 Cheltuieli privind energia si apa",
                note: "Deductibil integral daca locul de consum e sediul/punctul de lucru al firmei.",
                vatDeductibility: "100%")),

        // --- TELECOM, POSTA — 626 ---
        Rule(pattern: "ORANGE|VODAFONE|TELEKOM|\\bDIGI\\b|\\bRCS\\b|RDS\\b|POSTA\\s+ROMANA|ABONAMENT\\s+(MOBIL|INTERNET|TV)",
             cls: Classification(
                accountCode: "626",
                account: "626 Cheltuieli postale si taxe de telecomunicatii",
                note: nil,
                vatDeductibility: "100%")),

        // --- CURIERAT, TRANSPORT MARFA — 624 ---
        Rule(pattern: "FAN\\s?COURIER|SAMEDAY|CARGUS|\\bDPD\\b|\\bGLS\\b|\\bDHL\\b|\\bUPS\\b|\\bTNT\\b|CURIER|EXPEDIERE|AWB\\b",
             cls: Classification(
                accountCode: "624",
                account: "624 Cheltuieli cu transportul de bunuri si personal",
                note: nil,
                vatDeductibility: "100%")),

        // --- CAZARE, DEPLASARI — 625 ---
        Rule(pattern: "HOTEL|PENSIUNE|CAZARE|BOOKING|MOTEL|HOSTEL",
             cls: Classification(
                accountCode: "625",
                account: "625 Cheltuieli cu deplasari, detasari si transferari",
                note: "Deductibil pentru deplasari in interes de serviciu — pastreaza ordinul de deplasare.",
                vatDeductibility: "100% (deplasare in interes de serviciu)")),

        // --- SERVICE AUTO, REPARATII — 611 ---
        Rule(pattern: "SERVICE\\s+AUTO|VULCANIZARE|\\bITP\\b|SCHIMB\\s+ULEI|REPARATI[EI]|PIESE\\s+AUTO|AUTOSERVICE",
             cls: Classification(
                accountCode: "611",
                account: "611 Cheltuieli cu intretinerea si reparatiile",
                note: "Pentru vehicule cu utilizare mixta se aplica limitarea de 50% (art. 298 CF), ca la combustibil.",
                vatDeductibility: "100% / 50% la vehicule cu utilizare mixta")),

        // --- ASIGURARI — 613 ---
        Rule(pattern: "ASIGURAR|ALLIANZ|GROUPAMA|OMNIASIG|EUROINS|GENERALI|\\bRCA\\b|CASCO|ASIROM|GRAWE",
             cls: Classification(
                accountCode: "613",
                account: "613 Cheltuieli cu primele de asigurare",
                note: "Asigurarile (RCA/CASCO etc.) sunt scutite de TVA — pe bon nu ar trebui sa apara TVA.",
                vatDeductibility: "n/a (operatiune scutita de TVA)")),

        // --- COMISIOANE BANCARE — 627 ---
        Rule(pattern: "COMISION\\s+BANCAR|BANCA\\s+TRANSILVANIA|\\bBCR\\b|\\bBRD\\b|\\bING\\b|RAIFFEISEN|UNICREDIT|CEC\\s+BANK|TAXA\\s+CONT",
             cls: Classification(
                accountCode: "627",
                account: "627 Cheltuieli cu serviciile bancare si asimilate",
                note: "Serviciile bancare sunt in general scutite de TVA.",
                vatDeductibility: "n/a (de regula scutit de TVA)")),

        // --- ONORARII (notar, avocat, expert) — 622 ---
        Rule(pattern: "NOTAR|AVOCAT|EXECUTOR|EXPERT\\s+CONTABIL|ONORARIU|CABINET\\s+DE\\s+AVOCATURA|TRADUCERI\\s+AUTORIZATE",
             cls: Classification(
                accountCode: "622",
                account: "622 Cheltuieli privind comisioanele si onorariile",
                note: nil,
                vatDeductibility: "100%")),

        // --- CHIRII — 612 ---
        Rule(pattern: "CHIRIE|\\bRENT\\b|INCHIRIERE\\s+SPATIU|LOCATIUNE",
             cls: Classification(
                accountCode: "612",
                account: "612 Cheltuieli cu redeventele, locatiile de gestiune si chiriile",
                note: nil,
                vatDeductibility: "100% (daca proprietarul a optat pentru taxare)")),

        // --- RECLAMA (inclusiv online) — 623 analitic reclama ---
        Rule(pattern: "GOOGLE\\s+ADS|FACEBOOK|META\\s+ADS|TIKTOK\\s+ADS|PUBLICITATE|RECLAMA|PROMOVARE",
             cls: Classification(
                accountCode: "623",
                account: "623 Reclama si publicitate (analitic distinct de protocol)",
                note: "Reclama e integral deductibila (spre deosebire de protocol). "
                    + "La facturile Google/Meta din UE verifica taxarea inversa (nu apar pe bon fiscal de regula).",
                vatDeductibility: "100%")),

        // --- PROTOCOL: restaurante, cafenele, cadouri, parfumerie — 623 ---
        Rule(pattern: "RESTAURANT|CATERING|CAFENEA|COFFEE|PIZZA|BISTRO|FAST\\s?FOOD|PATISERIE|COFETARIE|PARFUMERIE|DOUGLAS|SEPHORA|\\bCADOU|NOTINO|FLORARIE",
             cls: Classification(
                accountCode: "623",
                account: "623 Cheltuieli de protocol",
                note: "Protocol: deductibil limitat la 2% din profitul contabil ajustat. "
                    + "TVA la cadouri deductibila doar in plafonul de 100 lei/beneficiar (art. 270 alin. (8) lit. b) CF). "
                    + "La restaurant: mancarea e la 11%, alcoolul la 21% — verifica liniile TVA.",
                vatDeductibility: "limitat (protocol)")),

        // --- ELECTRONICE, IT — 303 / 214 dupa prag ---
        Rule(pattern: "EMAG|ALTEX|FLANCO|MEDIA\\s+GALAXY|\\bPC\\s?GARAGE|CEL\\.RO|LAPTOP|MONITOR|IMPRIMANTA|TELEFON\\s+MOBIL|TABLETA",
             cls: Classification(
                accountCode: "303",
                account: "303 Obiecte de inventar / 214 Imobilizari (peste plafonul de 2.500 lei)",
                note: "Sub 2.500 lei si durata > 1 an: obiect de inventar (303, dat in consum pe 603). "
                    + "Peste 2.500 lei: mijloc fix (214/213), amortizat.",
                vatDeductibility: "100%")),

        // --- BRICOLAJ, MATERIALE — 6028 / 604 / 303 ---
        Rule(pattern: "DEDEMAN|HORNBACH|LEROY\\s?MERLIN|BRICO|ARABESQUE|MATHAUS|MATERIALE\\s+DE\\s+CONSTRUCTI",
             cls: Classification(
                accountCode: "6028",
                account: "6028 Alte materiale consumabile / 303 obiecte de inventar / 611 daca e reparatie",
                note: "Incadrarea depinde de destinatie: consumabile (6028), scule cu folosinta indelungata (303), "
                    + "materiale pentru reparatii la sediu (611).",
                vatDeductibility: "100%")),

        // --- PAPETARIE, BIROTICA — 604 ---
        Rule(pattern: "PAPETARIE|BIROTICA|LIBRARIE|TONER|CARTUS|HARTIE\\s+COPIATOR|DIVERTA|AUCHAN\\s+PAPETARIE|RECHIZITE",
             cls: Classification(
                accountCode: "604",
                account: "604 Cheltuieli privind materialele nestocate",
                note: nil,
                vatDeductibility: "100%")),

        // --- FARMACII — dupa destinatie ---
        Rule(pattern: "FARMACI|CATENA|HELP\\s?NET|SENSIBLU|DR\\.?\\s?MAX|BENU\\b",
             cls: Classification(
                accountCode: "604",
                account: "604 Materiale nestocate (trusa medicala firma) / 6458 dupa destinatie",
                note: "Doar trusa de prim ajutor si medicatia de uz colectiv sunt deductibile pe firma; "
                    + "medicamentele personale nu sunt.",
                vatDeductibility: "dupa destinatie")),

        // --- SUPERMARKET — necesita destinatie ---
        Rule(pattern: "KAUFLAND|LIDL|CARREFOUR|MEGA\\s?IMAGE|PROFI\\b|AUCHAN|PENNY|METRO\\b|SELGROS|LA\\s?DOI\\s?PASI",
             cls: Classification(
                accountCode: "6028",
                account: "6028 Consumabile (apa, cafea birou) / 623 protocol, dupa destinatie",
                note: "Bonurile de supermarket cer destinatia: consumabile de birou (6028, integral deductibile) "
                    + "vs. protocol (623, limitat). Verifica produsele de pe bon.",
                vatDeductibility: "dupa destinatie")),

        // --- ROVINIETA, TAXE DRUM — 635 ---
        Rule(pattern: "ROVINIETA|PEAJ|TAXA\\s+(DE\\s+)?POD|TAXA\\s+DRUM|CNAIR",
             cls: Classification(
                accountCode: "635",
                account: "635 Cheltuieli cu alte impozite, taxe si varsaminte asimilate",
                note: "Rovinieta si taxele de drum nu poarta TVA.",
                vatDeductibility: "n/a (fara TVA)")),

        // --- PARCARE, SPALATORIE AUTO — 628 cu limitarea auto ---
        Rule(pattern: "PARCARE|PARKING|SPALATORIE\\s+AUTO",
             cls: Classification(
                accountCode: "628",
                account: "628 Alte cheltuieli cu serviciile executate de terti",
                note: "Cheltuielile legate de vehicul cu utilizare mixta urmeaza limitarea de 50% (art. 298 CF).",
                vatDeductibility: "100% / 50% la vehicule cu utilizare mixta")),
    ]

    private static let compiled: [(NSRegularExpression, Classification)] = rules.compactMap { r in
        (try? NSRegularExpression(pattern: r.pattern, options: [.caseInsensitive])).map { ($0, r.cls) }
    }

    static func classify(fullText: String) -> Classification {
        let t = fullText.uppercased()
        let range = NSRange(t.startIndex..., in: t)
        for (rx, cls) in compiled where rx.firstMatch(in: t, range: range) != nil {
            return cls
        }
        return Classification(
            accountCode: "628",
            account: "628 Alte cheltuieli cu serviciile / 604 Materiale nestocate",
            note: "Comerciant neincadrat automat — necesita incadrare manuala. "
                + "Poti adauga o regula locala (cuvant cheie -> cont) in pagina web.",
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
            : "Plata card (5125 sume in curs; foloseste 5121 la card de firma sau 542 la decont angajat)"
        out.append(AccountingEntryDTO(debit: "401", credit: payingAccount,
                                      amount: total.ron2, label: payLabel))
        return out
    }
}
