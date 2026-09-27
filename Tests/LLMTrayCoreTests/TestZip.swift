import Compression
import Foundation

/// Just enough zip writing to build Office containers and hostile ones
/// (bombs, lying sizes, overlaps) at test time -- no binaries committed.
final class TestZip {
    private var out = Data()
    private var central = Data()
    private(set) var count = 0
    /// Overrides for the end record: a zip64 marker, a lying entry count.
    var endRecordCount: Int?

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    /// Raw DEFLATE, as zip stores it.
    static func deflate(_ data: Data) -> Data {
        let capacity = max(64, data.count + 1024)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { raw in
            compression_encode_buffer(dst, capacity, raw.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: dst, count: n)
    }

    private func le16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    private func le32(_ v: Int, _ d: inout Data) { for i in 0..<4 { d.append(UInt8((v >> (8 * i)) & 0xFF)) } }

    func add(_ name: String, _ text: String, store: Bool = false) { add(name, Data(text.utf8), store: store) }

    func add(_ name: String, _ data: Data, store: Bool = false, declaredSize: Int? = nil, flags: Int = 0) {
        let payload = store ? data : Self.deflate(data)
        addRaw(name, method: store ? 0 : 8, payload: payload, size: declaredSize ?? data.count, crc: Self.crc(data), flags: flags)
    }

    /// One entry; `localName` lets the local header disagree with the
    /// central directory, `offset` points the central record elsewhere.
    func addRaw(_ name: String, method: Int, payload: Data, size: Int, crc: UInt32, flags: Int = 0,
                localName: String? = nil, offset: Int? = nil, localMethod: Int? = nil, localSize: Int? = nil, localFlags: Int? = nil,
                centralExtra: Data = Data()) {
        let nameData = Data(name.utf8)
        let local = Data((localName ?? name).utf8)
        let at = offset ?? out.count
        if offset == nil {
            var lh = Data()
            le32(0x0403_4B50, &lh); le16(20, &lh); le16(localFlags ?? flags, &lh); le16(localMethod ?? method, &lh); le16(0, &lh); le16(0x21, &lh)
            le32(Int(crc), &lh); le32(payload.count, &lh); le32(localSize ?? size, &lh); le16(local.count, &lh); le16(0, &lh)
            out.append(lh); out.append(local); out.append(payload)
        }
        var ch = Data()
        le32(0x0201_4B50, &ch); le16(20, &ch); le16(20, &ch); le16(flags, &ch); le16(method, &ch); le16(0, &ch); le16(0x21, &ch)
        le32(Int(crc), &ch); le32(payload.count, &ch); le32(size, &ch); le16(nameData.count, &ch)
        le16(centralExtra.count, &ch); le16(0, &ch); le16(0, &ch); le16(0, &ch); le32(0, &ch); le32(at, &ch)
        central.append(ch); central.append(nameData); central.append(centralExtra)
        count += 1
    }

    /// Where the next entry's local header will go.
    var offset: Int { out.count }

    func finish() -> Data {
        var d = out
        let cdOffset = d.count
        d.append(central)
        var e = Data()
        let n = endRecordCount ?? count
        le32(0x0605_4B50, &e); le16(0, &e); le16(0, &e); le16(n, &e); le16(n, &e)
        le32(central.count, &e); le32(cdOffset, &e); le16(0, &e)
        d.append(e)
        return d
    }

    /// A minimal docx whose body is `body` (already XML), plus extra parts.
    static func docx(body: String, extra: [(String, Data)] = []) -> Data {
        let z = TestZip()
        z.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """)
        z.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """)
        z.add("word/document.xml", """
        <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """)
        for (name, data) in extra { z.add(name, data) }
        return z.finish()
    }

    static func paragraph(_ text: String) -> String { "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>" }
}
