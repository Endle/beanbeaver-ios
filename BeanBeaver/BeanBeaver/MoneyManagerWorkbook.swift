import Foundation

/// Minimal, dependency-free `.xlsx` (Office Open XML SpreadsheetML) writer.
///
/// Realbyte's *Money Manager* imports transactions from an Excel file
/// (More → Backup → Import excel file), so `MoneyManagerExport` has to hand it a
/// genuine `.xlsx`. iOS ships no public zip-container API and this app pins its
/// dependencies deliberately, so rather than take one on we emit the handful of
/// XML parts a spreadsheet needs and pack them into a `stored` (uncompressed) ZIP
/// by hand — small, self-contained, and byte-verifiable (`unzip -t` checks the
/// CRC-32 of every part).
///
/// Every cell is written as an **inline string** (`t="inlineStr"`); Money Manager
/// reads the cell's text regardless — exactly as it does the tab-separated files
/// the community migration tools feed the same importer — so we skip a
/// shared-strings table, a styles table, and number formatting entirely.
///
/// Kept independent of `BBReceiptKit` (it takes `[[String]]`, not receipts) so it
/// can be exercised from a plain `swift` harness without the app.
enum MoneyManagerWorkbook {
    /// Build a one-worksheet `.xlsx` from `rows` — each an array of cell strings,
    /// the first row treated like any other (the caller supplies the header).
    /// Returns the finished archive bytes.
    static func xlsx(sheetName: String, rows: [[String]]) -> Data {
        let parts: [ZipEntry] = [
            ZipEntry(path: "[Content_Types].xml", data: Data(contentTypesXML.utf8)),
            ZipEntry(path: "_rels/.rels", data: Data(rootRelsXML.utf8)),
            ZipEntry(path: "xl/workbook.xml", data: Data(workbookXML(sheetName: sheetName).utf8)),
            ZipEntry(path: "xl/_rels/workbook.xml.rels", data: Data(workbookRelsXML.utf8)),
            ZipEntry(path: "xl/worksheets/sheet1.xml", data: Data(sheetXML(rows: rows).utf8)),
        ]
        return Zip.archive(parts)
    }

    /// CRC-32 (IEEE 802.3) — the checksum the ZIP headers carry over each part.
    /// Lives here (not buried in `Zip`) so a test harness can assert it against
    /// the known vector `0xCBF43926` for `"123456789"`.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - OOXML parts

    // Raw string literals (`#"…"#`) so the XML's own double quotes need no
    // escaping; `.joined()` keeps each part one logical line, sidestepping
    // multiline-literal indentation stripping.
    private static let contentTypesXML = [
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
        #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#,
        #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#,
        #"<Default Extension="xml" ContentType="application/xml"/>"#,
        #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#,
        #"<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#,
        #"</Types>"#,
    ].joined()

    private static let rootRelsXML = [
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
        #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#,
        #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>"#,
        #"</Relationships>"#,
    ].joined()

    private static func workbookXML(sheetName: String) -> String {
        [
            #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#,
            #"<sheets><sheet name="\#(escapeAttr(sheetName))" sheetId="1" r:id="rId1"/></sheets>"#,
            #"</workbook>"#,
        ].joined()
    }

    private static let workbookRelsXML = [
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
        #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#,
        #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>"#,
        #"</Relationships>"#,
    ].joined()

    private static func sheetXML(rows: [[String]]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        xml += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
        for (r, row) in rows.enumerated() {
            let rowNumber = r + 1
            xml += #"<row r="\#(rowNumber)">"#
            for (c, cell) in row.enumerated() {
                let ref = "\(columnName(c))\(rowNumber)"
                xml += #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(escapeText(cell))</t></is></c>"#
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    // MARK: - Helpers

    /// Zero-based column index to its spreadsheet label: 0→"A", 25→"Z", 26→"AA".
    private static func columnName(_ index: Int) -> String {
        var i = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + i % 26))) + name
            i = i / 26 - 1
        } while i >= 0
        return name
    }

    private static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// One file inside the archive.
private struct ZipEntry {
    let path: String
    let data: Data
}

/// Minimal `stored` (no-compression) ZIP builder — enough to package OOXML parts
/// into an `.xlsx`. Uncompressed keeps it trivial and byte-verifiable; the parts
/// are a few KB, so compression would buy nothing worth the deflate code.
private enum Zip {
    static func archive(_ entries: [ZipEntry]) -> Data {
        var out = Data()
        var central = Data()
        // A constant, valid MS-DOS timestamp (1980-01-01 00:00:00): the importer
        // doesn't care and a fixed value keeps output deterministic.
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021 // ((1980-1980)<<9) | (1<<5) | 1

        for entry in entries {
            let nameBytes = Array(entry.path.utf8)
            let crc = MoneyManagerWorkbook.crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            // Local file header
            out.append(contentsOf: le32(0x04034B50)) // signature
            out.append(contentsOf: le16(20))         // version needed
            out.append(contentsOf: le16(0))          // general-purpose flags
            out.append(contentsOf: le16(0))          // method: 0 = stored
            out.append(contentsOf: le16(dosTime))
            out.append(contentsOf: le16(dosDate))
            out.append(contentsOf: le32(crc))
            out.append(contentsOf: le32(size))       // compressed size
            out.append(contentsOf: le32(size))       // uncompressed size
            out.append(contentsOf: le16(UInt16(nameBytes.count)))
            out.append(contentsOf: le16(0))          // extra length
            out.append(contentsOf: nameBytes)
            out.append(entry.data)

            // Central directory header
            central.append(contentsOf: le32(0x02014B50)) // signature
            central.append(contentsOf: le16(20))         // version made by
            central.append(contentsOf: le16(20))         // version needed
            central.append(contentsOf: le16(0))          // flags
            central.append(contentsOf: le16(0))          // method
            central.append(contentsOf: le16(dosTime))
            central.append(contentsOf: le16(dosDate))
            central.append(contentsOf: le32(crc))
            central.append(contentsOf: le32(size))
            central.append(contentsOf: le32(size))
            central.append(contentsOf: le16(UInt16(nameBytes.count)))
            central.append(contentsOf: le16(0))          // extra length
            central.append(contentsOf: le16(0))          // comment length
            central.append(contentsOf: le16(0))          // disk number start
            central.append(contentsOf: le16(0))          // internal attrs
            central.append(contentsOf: le32(0))          // external attrs
            central.append(contentsOf: le32(offset))     // local header offset
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(out.count)
        let centralSize = UInt32(central.count)
        out.append(central)

        // End of central directory record
        out.append(contentsOf: le32(0x06054B50))
        out.append(contentsOf: le16(0))                    // this disk number
        out.append(contentsOf: le16(0))                    // disk with central dir
        out.append(contentsOf: le16(UInt16(entries.count))) // entries on this disk
        out.append(contentsOf: le16(UInt16(entries.count))) // total entries
        out.append(contentsOf: le32(centralSize))
        out.append(contentsOf: le32(centralOffset))
        out.append(contentsOf: le16(0))                    // comment length
        return out
    }

    private static func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
