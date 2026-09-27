import AppKit
import Darwin
import ExtractKit
import Foundation
import Vision

// probe junk                      -- junk signals on built-in strings (+ stdin lines with --stdin)
// probe hog <MB> [--rlimit-as MB] [--rlimit-data MB] [--rlimit-rss MB]
//                                 -- allocate+touch 16 MB blocks up to MB, report where it stops
// probe xmlraw <file> [--resolve] -- XMLParser with no DOCTYPE guard: time, text length
// probe attr <file> <docx|doc|odt|rtf|html> <main|bg>
//                                 -- NSAttributedString import on the main or a background thread

let a = Array(CommandLine.arguments.dropFirst())
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func arg(_ name: String) -> String? { a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }

switch a.first {
case "junk":
    var cases: [(String, String)] = [
        ("ru prose", "Договор поставки № 17/2024 заключён между ООО «Ромашка» и индивидуальным предпринимателем Кузнецовым К. К. Поставщик обязуется передать товар."),
        ("en prose", "The quick brown fox jumps over the lazy dog. Section 4.2 sets the delivery schedule; penalties accrue at 0.1% per day."),
        ("fr prose", "L'élève était très fâché : il a reçu une mauvaise note à l'épreuve de français, malgré ses efforts considérables et répétés."),
        ("de prose", "Die Größe des Gebäudes überraschte die Prüfer; über fünfzig Räume müssen bis März völlig renoviert werden, heißt es."),
        ("uk prose", "Ґрунтовне дослідження їхньої діяльності показало, що підприємство є прибутковим і має значний потенціал розвитку."),
        ("kk prose", "Қазақстан Республикасының Үкіметі жаңа бағдарламаны бекітті, ол өңірлердің әлеуметтік-экономикалық дамуына бағытталған."),
        ("ru+en tech", "Настройте API-ключ в config.yaml, затем запустите docker compose up; сервер PostgreSQL слушает порт 5432 на localhost."),
        ("zh", "机器学习是人工智能的一个分支，它使计算机能够在没有明确编程的情况下从数据中学习并做出预测。"),
        ("numbers table", "2021 | 1 234,56 | 2 000,00 | 17,5%\n2022 | 1 456,00 | 2 150,25 | 18,1%\n2023 | 1 610,10 | 2 310,90 | 19,4%"),
        ("code", "func score(_ text: String) -> Double { let n = text.count; return n > 0 ? Double(hits) / Double(n) : 0 } // TODO"),
        ("sheet w/ blanks", " |  |  |  | NSSE 2011 Multi-Year Benchmark Report\n |  | 2001 | 2002 | 2003 | 2004 | 2005"),
        ("lookalike к", "Дoгoвoр пoставĸи заĸлючён мeжду ООО «Рoмашĸа» и индивидуальным прeдприниматeлeм"),
        ("only U+0138", "Договор постав\u{0138}и за\u{0138}лючён между ООО «Ромаш\u{0138}а» и индивидуальным предпринимателем"),
        ("mojibake cp1251->latin1", "Äîãîâîð ïîñòàâêè ¹ 17/2024 çàêëþ÷¸í ìåæäó ÎÎÎ «Ðîìàøêà» è èíäèâèäóàëüíûì"),
        ("mojibake utf8->latin1", "Ð\u{94}Ð¾Ð³Ð¾Ð²Ð¾Ñ\u{80} Ð¿Ð¾Ñ\u{81}Ñ\u{82}Ð°Ð²ÐºÐ¸ Ð·Ð°ÐºÐ»Ñ\u{8e}Ñ\u{87}Ñ\u{91}Ð½"),
        ("fffd 5%", String(repeating: "Договор поставки заключён ", count: 4) + String(repeating: "\u{FFFD}", count: 5)),
        ("pua", "\u{E001}\u{E002}\u{E003} \u{E004}\u{E005} № 17/2024 \u{E006}\u{E007}\u{E008}\u{E009} «\u{E00A}»"),
        ("symbol soup", "*^&^%^! ~^#%!%%! № 17/2024 ~!%&^~ё@ *@^*& ^^^ «!^*!!%!» ! !@*!%!*&!&*@&*"),
        ("control chars", "Dogovor\u{01}\u{02} postavki\u{03}\u{04}\u{05} zakl\u{06}\u{07}uchen \u{0E}\u{0F}\u{10} mezhdu \u{11}\u{12}"),
        ("short ok", "Итого"),
        ("empty", ""),
    ]
    if a.contains("--stdin") {
        while let l = readLine() { cases.append(("stdin", l)) }
    }
    for (name, t) in cases {
        let s = Junk.signals(t)
        print(String(format: "%-26@ %@ %@", name as NSString, s.score >= Junk.threshold ? "JUNK" : "ok  ", s.description))
    }

case "hog":
    func lim(_ res: Int32, _ mb: String?, _ label: String) {
        guard let mb, let v = UInt64(mb) else { return }
        var rl = rlimit()
        getrlimit(res, &rl)
        err("\(label) before: cur \(rl.rlim_cur) max \(rl.rlim_max)")
        rl.rlim_cur = v << 20   // soft only; lowering the hard limit too gave EINVAL
        if a.contains("--hard") { rl.rlim_max = v << 20 }
        let r = setrlimit(res, &rl)
        var back = rlimit()
        getrlimit(res, &back)
        err("setrlimit(\(label), \(v) MB) = \(r) \(r != 0 ? String(cString: strerror(errno)) : "") -> cur \(back.rlim_cur >> 20) MB")
    }
    if let mb = arg("--self-jetsam").flatMap(UInt32.init) {
        // memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT = 6, own pid, MB, nil, 0)
        typealias MSC = @convention(c) (UInt32, Int32, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "memorystatus_control")!
        let r = unsafeBitCast(sym, to: MSC.self)(6, getpid(), mb, nil, 0)
        err("memorystatus_control(SET_JETSAM_TASK_LIMIT, self, \(mb) MB) = \(r) \(r != 0 ? String(cString: strerror(errno)) : "")")
    }
    lim(RLIMIT_AS, arg("--rlimit-as"), "AS")
    lim(RLIMIT_DATA, arg("--rlimit-data"), "DATA")
    lim(RLIMIT_RSS, arg("--rlimit-rss"), "RSS")
    let target = Int(a[1])!
    var blocks: [UnsafeMutableRawPointer] = []
    let block = 16 << 20
    var got = 0
    while got < target {
        guard let p = malloc(block) else { err("malloc failed at \(got) MB"); break }
        memset(p, 1, block)
        blocks.append(p)
        got += 16
        if got % 512 == 0 { err("allocated \(got) MB") }
    }
    // Also try mmap directly (malloc large blocks are mmap'd anyway).
    let m = mmap(nil, 256 << 20, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
    err("mmap 256 MB after: \(m == MAP_FAILED ? "failed: " + String(cString: strerror(errno)) : "ok")")
    print("hog reached \(got) MB")

case "xmlraw":
    let data = try! Data(contentsOf: URL(fileURLWithPath: a[1]))
    final class D: NSObject, XMLParserDelegate {
        var chars = 0, maxDepth = 0, depth = 0, entities = 0
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { depth += 1; maxDepth = max(maxDepth, depth) }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
        func parser(_ p: XMLParser, foundCharacters s: String) { chars += s.utf16.count }
        func parser(_ p: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { entities += 1 }
        func parser(_ p: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { err("resolveExternalEntity \(name) \(systemID ?? "")"); return nil }
    }
    let p = XMLParser(data: data)
    let d = D()
    p.delegate = d
    p.shouldResolveExternalEntities = a.contains("--resolve")
    let t0 = Date()
    let ok = p.parse()
    print("ok=\(ok) chars=\(d.chars) maxDepth=\(d.maxDepth) entityDecls=\(d.entities) ms=\(Int(Date().timeIntervalSince(t0) * 1000)) error=\(p.parserError.map { "\($0)" } ?? "-")")

case "attr":
    let data = try! Data(contentsOf: URL(fileURLWithPath: a[1]))
    let type: NSAttributedString.DocumentType = ["docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "rtf": .rtf, "html": .html, "wordml": .wordML][a[2]]!
    let onMain = a[3] == "main"
    func run() {
        let t0 = Date()
        do {
            let s = try NSAttributedString(data: data, options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            print("ok thread=\(Thread.isMainThread ? "main" : "bg") chars=\(s.length) ms=\(Int(Date().timeIntervalSince(t0) * 1000)) head=\(s.string.prefix(60).replacingOccurrences(of: "\n", with: " "))")
        } catch {
            print("error thread=\(Thread.isMainThread ? "main" : "bg") \(error)")
        }
    }
    if onMain {
        run()
    } else {
        let done = DispatchSemaphore(value: 0)
        Thread { run(); done.signal() }.start()
        if done.wait(timeout: .now() + 20) == .timedOut { print("bg: timed out after 20 s (deadlock?)") }
    }

case "connect":
    // probe connect <port> [--no-network]: apply the sandbox, then try TCP to 127.0.0.1:<port>
    if a.contains("--no-network") {
        typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        var e: UnsafeMutablePointer<CChar>?
        let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_init")!
        let r = unsafeBitCast(sym, to: SandboxInit.self)("no-network", 1, &e)
        err("sandbox_init(no-network) = \(r)")
    }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(a[1])!).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    print("connect = \(r) \(r != 0 ? String(cString: strerror(errno)) : "connected")")
    // and can it still read files?
    print("read /etc/hosts: \((try? Data(contentsOf: URL(fileURLWithPath: "/etc/hosts")))?.count ?? -1) bytes")
    // and resolve a URL through URLSession?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(a[1])/urlsession")!) { _, resp, error in
        print("URLSession: \(error.map { "\($0.localizedDescription)" } ?? "status \((resp as? HTTPURLResponse)?.statusCode ?? 0)")")
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 10)

case "ocr":
    // probe ocr <image>: Vision text recognition (ru + en), text on stdout
    let url = URL(fileURLWithPath: a[1])
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["ru-RU", "en-US"]
    req.usesLanguageCorrection = true
    let t0 = Date()
    try! VNImageRequestHandler(url: url).perform([req])
    let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    print(lines.joined(separator: "\n"))
    err("ocr ms=\(Int(Date().timeIntervalSince(t0) * 1000)) lines=\(lines.count)")

default:
    err("usage: probe junk|hog|xmlraw|attr|connect|ocr ...")
    exit(64)
}
