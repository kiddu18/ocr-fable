import Foundation

let fullText = "S.C. MEGA IMAGE S.R.L. STR.BANU ANTONACHE.PIATA FLOREASCA.S.1 C.I.F.: RO 6719278 1.000 X 2.99 CHEFIR 3.3% 420G 2.99 A 1.000 X 0.35 PUNGA (ECOTAXA0.1) 0.35 A 1.000 X 0.39 365 KAISER SUSAN54 0.39 B SUBTOTAL 3.73 TOTAL 3.73 TVA A 24.00% 0.65 TVA B 09.00% 0.03 ACHITAT 3.73 REST 0.00 ING 3.73 NR. CARD : XXXXXXXXXXXX1528 NR. TRANZACTIE: 12856 POS:3 OP:55 TR:148 VA MULTUMIM SI VA MAI ASTEPTAM VIZITATI WWW.MEGA-IMAGE.RO TEL/FAX: 0212246677 BF. 131 DATA:06/02/2015 ORA:12-11-29 MB0572510251 BON FISCAL"

// Test CUI
func isValidCUI(cui: String) -> Bool {
    guard cui.count >= 2 && cui.count <= 10 else { return false }
    guard let cuiNum = Int(cui) else { return false }
    
    let key = "753217532"
    let cuiStr = String(format: "%09d", cuiNum)
    
    var sum = 0
    for (i, char) in cuiStr.enumerated() {
        if i == 8 { break }
        let digit = Int(String(char))!
        let keyDigit = Int(String(Array(key)[i]))!
        sum += digit * keyDigit
    }
    
    let expectedControlDigit = Int(String(cuiStr.last!))!
    var calculatedControl = (sum * 10) % 11
    if calculatedControl == 10 {
        calculatedControl = 0
    }
    
    return calculatedControl == expectedControlDigit
}

let primaryPattern = "(?:C\\.?U\\.?I\\.?|C\\.?I\\.?F\\.?|COD FISCAL|RO)[\\s\\.:]*([0-9]{2,10})"
if let regex = try? NSRegularExpression(pattern: primaryPattern, options: []) {
    let nsString = fullText as NSString
    let results = regex.matches(in: fullText, options: [], range: NSRange(location: 0, length: nsString.length))
    for match in results {
        if match.numberOfRanges > 1 {
            let cuiCandidate = nsString.substring(with: match.range(at: 1))
            print("CUI Candidate: \(cuiCandidate) -> isValid: \(isValidCUI(cui: cuiCandidate))")
        }
    }
}

let fallbackPattern = "\\b([0-9]{2,10})\\b"
if let regex = try? NSRegularExpression(pattern: fallbackPattern, options: []) {
    let nsString = fullText as NSString
    let results = regex.matches(in: fullText, options: [], range: NSRange(location: 0, length: nsString.length))
    for match in results {
        if match.numberOfRanges > 1 {
            let cuiCandidate = nsString.substring(with: match.range(at: 1))
            print("Fallback CUI Candidate: \(cuiCandidate) -> isValid: \(isValidCUI(cui: cuiCandidate))")
        }
    }
}

// Test VAT
let vatPattern = "TVA\\s*(?:[A-Z]\\s*)?([0-9]{1,2})(?:[,.][0-9]{1,2})?\\s*%?[^\\d]{0,15}?([0-9]+[,.][0-9]{2})"
if let regex = try? NSRegularExpression(pattern: vatPattern, options: []) {
    let nsString = fullText as NSString
    let results = regex.matches(in: fullText, options: [], range: NSRange(location: 0, length: nsString.length))
    for match in results {
        if match.numberOfRanges > 2 {
            let pct = nsString.substring(with: match.range(at: 1))
            let val = nsString.substring(with: match.range(at: 2))
            print("VAT: \(pct)% -> \(val)")
        }
    }
}
