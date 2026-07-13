//
//  PATCH_SERVE_WEBCLIENT.swift
//  NU se adauga la target — sunt blocuri de copiat in VaporServer.swift.
//
//  Rezolva cele doua erori din browser:
//   1. 404 la /webclient_index.html  -> serverul nu servea fisierul (rutele de mai jos)
//   2. CORS "origin null" la file:// -> pagina deschisa de pe disc; CORSMiddleware
//      permite si acest mod, dar modul corect e sa accesezi pagina PRIN server.
//

import Vapor

// ============ 1. PASUL DIN XCODE (fara asta, ruta da 404) ==================
//  a) Trage webclient_index.html in proiect (File > Add Files...).
//  b) Bifeaza target-ul aplicatiei la "Add to targets".
//  c) Verifica: Build Phases > Copy Bundle Resources contine webclient_index.html.
// ===========================================================================

// ============ 2. CORS (in configure(), INAINTE de definirea rutelor) =======
let corsConfiguration = CORSMiddleware.Configuration(
    allowedOrigin: .all,
    allowedMethods: [.GET, .POST, .OPTIONS],
    allowedHeaders: [.accept, .contentType, .origin]
)
app.middleware.use(CORSMiddleware(configuration: corsConfiguration), at: .beginning)

// ============ 3. SERVIREA PAGINII ==========================================
// ATENTIE: daca exista deja o ruta app.get { ... } care serveste HTML-ul vechi
// (cauta "text/html" sau "<!DOCTYPE" in VaporServer.swift), STERGE-O si pune
// asta in loc — doua rute GET / vor intra in conflict.

func serveWebClient(_ req: Request) throws -> Response {
    guard let url = Bundle.main.url(forResource: "webclient_index", withExtension: "html"),
          let html = try? String(contentsOf: url, encoding: .utf8) else {
        throw Abort(.notFound, reason: "webclient_index.html lipseste din bundle — vezi pasul 1 (Copy Bundle Resources)")
    }
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
    headers.replaceOrAdd(name: .cacheControl, value: "no-store")   // vezi mereu ultima versiune
    return Response(status: .ok, headers: headers, body: .init(string: html))
}

app.get(use: serveWebClient)                            // http://IP:8000/
app.get("webclient_index.html", use: serveWebClient)    // http://IP:8000/webclient_index.html

// ============ CUM ACCESEZI ==================================================
// De pe orice dispozitiv din retea: http://192.168.222.133:8000/
// (IP-ul iPhone-ului se poate schimba — verifica-l in aplicatie / setari Wi-Fi.)
//
// Deschiderea de pe disc (file:///F:/...) ramane posibila DOAR ca fallback de
// dezvoltare: campul de adresa apare automat in pagina, scrii acolo
// http://192.168.222.133:8000 si, cu CORS-ul de la pasul 2 activ, merge.
// ===========================================================================
