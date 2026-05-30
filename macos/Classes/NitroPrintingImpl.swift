import Foundation
import AppKit
import Combine
import PDFKit
import Network

public class NitroPrintingImpl: NSObject, HybridNitroPrintingProtocol,
                                 NetServiceBrowserDelegate, NetServiceDelegate {

    // MARK: - Streams

    private let _onPrintJobChanged      = PassthroughSubject<PrintJobUpdate, Never>()
    private let _onPrinterStatusChanged = PassthroughSubject<PrinterStatus, Never>()
    private let _onPrinterDiscovered    = PassthroughSubject<DiscoveredPrinter, Never>()

    public var onPrintJobChanged: AnyPublisher<PrintJobUpdate, Never> {
        _onPrintJobChanged.eraseToAnyPublisher()
    }
    public var onPrinterStatusChanged: AnyPublisher<PrinterStatus, Never> {
        _onPrinterStatusChanged.eraseToAnyPublisher()
    }
    public var onPrinterDiscovered: AnyPublisher<DiscoveredPrinter, Never> {
        _onPrinterDiscovered.eraseToAnyPublisher()
    }

    // MARK: - Printer repository (local system + mDNS network printers)

    private var _printerRepository: [PrinterInfo] = []
    private let _repoLock = NSLock()

    // MARK: - Discovery state

    private var netBrowser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []

    // MARK: - Raw print cancellation state

    private let _rawLock = NSLock()
    private var _activeRawConnection: NWConnection?
    private var _activeRawTask: URLSessionDataTask?
    private var _isRawCancelled = false

    // MARK: - Init

    override init() {
        super.init()
        _refreshLocalPrinters()
    }

    // MARK: - Synchronous quick-lookup

    public func isPrintingSupported() -> Bool { return true }

    public func getPrintersCount() -> Int64 {
        _repoLock.lock(); defer { _repoLock.unlock() }
        return Int64(_printerRepository.count)
    }

    public func getAllPrinters() -> [PrinterInfo] {
        _repoLock.lock(); defer { _repoLock.unlock() }
        return _printerRepository
    }

    public func getPrinterAt(index: Int64) -> PrinterInfo {
        _repoLock.lock(); defer { _repoLock.unlock() }
        guard index >= 0, Int(index) < _printerRepository.count else {
            return PrinterInfo(id: "unknown", name: "Unknown Printer", address: "",
                               isDefault: false, isAvailable: false)
        }
        return _printerRepository[Int(index)]
    }

    public func getDefaultPrinter() -> PrinterInfo {
        _repoLock.lock(); defer { _repoLock.unlock() }
        return _printerRepository.first(where: { $0.isDefault })
            ?? {
                let p = NSPrintInfo.shared.printer
                return PrinterInfo(id: p.name, name: p.name, address: "", isDefault: true, isAvailable: true)
            }()
    }

    public func getPrinterDriverVersion(printerId: String) -> String {
        return NSPrinter(name: printerId)?.type.rawValue ?? ""
    }

    public func getPrinterCapabilities(printerId: String) -> PrinterCapabilities {
        let supportsColor = true
        let trays = ""
        return PrinterCapabilities(
            supportsColor: supportsColor, supportsDuplex: true, supportsCopy: true,
            maxCopies: 999, minMarginTop: 0, minMarginBottom: 0, minMarginLeft: 0, minMarginRight: 0,
            supportsA4: true, supportsA5: true, supportsLetter: true, supportsLegal: true,
            supportsDraftQuality: true, supportsNormalQuality: true,
            supportsHighQuality: true, supportsBestQuality: true,
            maxResolutionDpi: 600, supportsCustomPaper: true, supportsBorderless: false,
            inputTrays: trays
        )
    }

    // MARK: - Print methods

    public func printText(text: String, settings: PrintSettings?) async throws -> PrintResult {
        let pps = Int(max(1, settings?.pagesPerSheet ?? 1))
        let cp  = Int(max(1, settings?.copies ?? 1))
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let info = self.buildPrintInfo(settings)
                if pps > 1 || cp > 1,
                   let srcDoc = self.renderTextToPDFDoc(text: text, pageSize: info.paperSize) {
                    self.printNUpPDF(self.makeNUpPDF(source: srcDoc, pagesPerSheet: pps, copies: cp),
                                      settings: settings, cont: cont)
                    return
                }
                let view = NSTextView(frame: NSRect(x: 0, y: 0,
                                                     width: info.paperSize.width, height: info.paperSize.height))
                view.string = text
                if let hdr = settings?.headerText, !hdr.isEmpty {
                    self.addHeaderFooter(to: view, header: hdr, footer: settings?.footerText ?? "", info: info)
                }
                let op = NSPrintOperation(view: view, printInfo: info)
                self.configureOperation(op, settings: settings)
                cont.resume(returning: self.makeResult(ok: op.run()))
            }
        }
    }

    public func printImage(imageData: Data, settings: PrintSettings?) async throws -> PrintResult {
        guard let image = NSImage(data: imageData) else {
            return PrintResult(success: false, jobId: "", errorMessage: "Invalid image data", errorCode: "INVALID_IMAGE")
        }
        let pps = Int(max(1, settings?.pagesPerSheet ?? 1))
        let cp  = Int(max(1, settings?.copies ?? 1))
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let info = self.buildPrintInfo(settings)
                if pps > 1 || cp > 1,
                   let srcDoc = self.renderImageToPDFDoc(image: image, pageSize: info.paperSize) {
                    self.printNUpPDF(self.makeNUpPDF(source: srcDoc, pagesPerSheet: pps, copies: cp),
                                      settings: settings, cont: cont)
                    return
                }
                let view = NSImageView(frame: NSRect(x: 0, y: 0,
                                                      width: info.paperSize.width, height: info.paperSize.height))
                view.image = image
                view.imageScaling = .scaleProportionallyUpOrDown
                let op = NSPrintOperation(view: view, printInfo: info)
                self.configureOperation(op, settings: settings)
                cont.resume(returning: self.makeResult(ok: op.run()))
            }
        }
    }

    public func printPdf(pdfData: Data, settings: PrintSettings?) async throws -> PrintResult {
        guard let srcDoc = PDFDocument(data: pdfData) else {
            return PrintResult(success: false, jobId: "", errorMessage: "Invalid PDF data", errorCode: "INVALID_PDF")
        }
        let pps = Int(max(1, settings?.pagesPerSheet ?? 1))
        let cp  = Int(max(1, settings?.copies ?? 1))
        let document = (pps > 1 || cp > 1) ? makeNUpPDF(source: srcDoc, pagesPerSheet: pps, copies: cp) : srcDoc
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                self.printNUpPDF(document, settings: settings, cont: cont)
            }
        }
    }

    public func printDocument(document: PrintDocument, settings: PrintSettings?) async throws -> PrintResult {
        switch document.type {
        case .plainText: return try await printText(text: String(data: document.data, encoding: .utf8) ?? "", settings: settings)
        case .html:      return try await printHtml(html: String(data: document.data, encoding: .utf8) ?? "", settings: settings)
        case .pdf:       return try await printPdf(pdfData: document.data, settings: settings)
        case .image:     return try await printImage(imageData: document.data, settings: settings)
        }
    }

    public func printFile(filePath: String, settings: PrintSettings?) async throws -> Bool {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let doc = PDFDocument(url: url) {
            return (try await printPdf(pdfData: doc.dataRepresentation() ?? Data(), settings: settings)).success
        } else if ["jpg", "jpeg", "png", "gif", "tiff", "bmp"].contains(ext), let data = try? Data(contentsOf: url) {
            return (try await printImage(imageData: data, settings: settings)).success
        } else {
            let text = (try? String(contentsOf: url)) ?? ""
            return (try await printText(text: text, settings: settings)).success
        }
    }

    // MARK: - Export / Virtual print

    public func renderPreview(document: PrintDocument, settings: PrintSettings?) async throws -> PreviewResult {
        let pdfData: Data
        if document.type == .pdf {
            pdfData = document.data
        } else {
            pdfData = try await withCheckedThrowingContinuation { cont in
                DispatchQueue.main.async {
                    let info = self.buildPrintInfo(settings)
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
                    info.jobDisposition = .save
                    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tempURL as NSURL
                    let view = self.makeView(for: document, info: info)
                    let op = NSPrintOperation(view: view, printInfo: info)
                    op.showsPrintPanel = false; op.showsProgressPanel = false
                    if op.run(), let data = try? Data(contentsOf: tempURL) {
                        try? FileManager.default.removeItem(at: tempURL)
                        cont.resume(returning: data)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
        }
        let count = pdfData.count
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        pdfData.copyBytes(to: ptr, count: count)
        return PreviewResult(bytes: ptr, length: Int64(count))
    }

    public func getPageCount(document: PrintDocument) async throws -> Int64 {
        if document.type == .pdf, let pdf = PDFDocument(data: document.data) {
            return Int64(pdf.pageCount)
        }
        return 1
    }

    public func printToFile(document: PrintDocument, outputPath: String, settings: PrintSettings?) async throws -> Bool {
        if document.type == .pdf {
            do { try document.data.write(to: URL(fileURLWithPath: outputPath)); return true }
            catch { return false }
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let info = self.buildPrintInfo(settings)
                let url = URL(fileURLWithPath: outputPath)
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url as NSURL
                let view = self.makeView(for: document, info: info)
                let op = NSPrintOperation(view: view, printInfo: info)
                op.showsPrintPanel = false; op.showsProgressPanel = false
                cont.resume(returning: op.run())
            }
        }
    }

    // MARK: - Job management

    public func cancelPrintJob(jobId: String) async throws -> Bool { return false }
    public func getPrintJobsCount() async throws -> Int64           { return 0 }

    public func getPrintJobAt(index: Int64) async throws -> PrintJob {
        throw NSError(domain: "NitroPrinting", code: 404, userInfo: [NSLocalizedDescriptionKey: "No tracked print jobs"])
    }
    public func getPrintJobStatus(jobId: String) async throws -> PrintJob {
        throw NSError(domain: "NitroPrinting", code: 404, userInfo: [NSLocalizedDescriptionKey: "No tracked print jobs"])
    }

    public func pausePrintJob(jobId: String) async throws -> Bool {
        return await runLpArgs(["-i", jobId, "-H", "hold"])
    }
    public func resumePrintJob(jobId: String) async throws -> Bool {
        return await runLpArgs(["-i", jobId, "-H", "resume"])
    }
    public func clearPrintQueue() async throws -> Bool {
        return await runShell("/usr/bin/cancel", args: ["-a"])
    }

    // MARK: - Discovery

    public func startPrinterDiscovery() async throws -> Bool {
        // Refresh local system printers, then emit each as DiscoveredPrinter.
        _refreshLocalPrinters()
        _repoLock.lock()
        let snapshot = _printerRepository
        _repoLock.unlock()
        for info in snapshot {
            let discovered = DiscoveredPrinter(id: info.id, name: info.name, host: "localhost",
                                                port: 631, serviceType: "local",
                                                uri: "ipp://localhost:631/\(info.id)", isAvailable: info.isAvailable)
            _onPrinterDiscovered.send(discovered)
        }
        // Browse mDNS for network printers.
        await MainActor.run {
            netBrowser?.stop(); resolvingServices.removeAll()
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: "_ipp._tcp.", inDomain: "local.")
            browser.searchForServices(ofType: "_ipps._tcp.", inDomain: "local.")
            netBrowser = browser
        }
        return true
    }

    public func stopPrinterDiscovery() async throws -> Bool {
        await MainActor.run {
            netBrowser?.stop(); netBrowser = nil; resolvingServices.removeAll()
        }
        return true
    }

    // MARK: - NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self; resolvingServices.append(service); service.resolve(withTimeout: 5)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolvingServices.removeAll { $0 === service }
    }

    // MARK: - NetServiceDelegate

    public func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName ?? sender.name
        let port = Int64(sender.port)
        let st = sender.type.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let scheme = st.contains("ipps") ? "ipps" : "ipp"
        var rp = "ipp/print"
        if let txt = sender.txtRecordData() {
            let d = NetService.dictionary(fromTXTRecord: txt)
            if let rpD = d["rp"], let rpS = String(data: rpD, encoding: .utf8) {
                rp = rpS.hasPrefix("/") ? String(rpS.dropFirst()) : rpS
            }
        }
        let uri = "\(scheme)://\(host):\(port)/\(rp)"
        // Add to repository (dedup by id)
        let info = PrinterInfo(id: uri, name: sender.name, address: host,
                               isDefault: false, isAvailable: true)
        _repoLock.lock()
        if !_printerRepository.contains(where: { $0.id == uri }) {
            _printerRepository.append(info)
        }
        _repoLock.unlock()
        _onPrinterDiscovered.send(DiscoveredPrinter(id: uri, name: sender.name, host: host,
                                                     port: port, serviceType: st, uri: uri, isAvailable: true))
        resolvingServices.removeAll { $0 === sender }
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolvingServices.removeAll { $0 === sender }
    }

    // MARK: - Connection

    public func testPrinterConnection(printerId: String, timeoutSeconds: Int64?) async throws -> Bool {
        let (host, port) = parseHostPort(printerId)
        guard !host.isEmpty else { return false }
        let deadline = Double((timeoutSeconds ?? 5) > 0 ? (timeoutSeconds ?? 5) : 5)
        return await withCheckedContinuation { cont in
            var done = false
            let finish = { (ok: Bool) in guard !done else { return }; done = true; cont.resume(returning: ok) }
            let conn = NWConnection(host: NWEndpoint.Host(host),
                                    port: NWEndpoint.Port(rawValue: UInt16(port)) ?? NWEndpoint.Port(integerLiteral: 631), using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:   conn.cancel(); finish(true)
                case .failed, .waiting: conn.cancel(); finish(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) { conn.cancel(); finish(false) }
        }
    }

    public func setDefaultPrinter(printerId: String) async throws -> Bool {
        guard !printerId.isEmpty else { return false }
        return await runShell("/usr/sbin/lpadmin", args: ["-d", printerId])
    }

    // MARK: - Platform UX

    public func openSystemPrintQueue(printerId: String) async throws -> Bool {
        return await MainActor.run {
            let urlStr: String
            if #available(macOS 13.0, *) {
                urlStr = "x-apple.systempreferences:com.apple.Print-Scan-Settings-Extension"
            } else {
                urlStr = "x-apple.systempreferences:com.apple.preference.printfax"
            }
            if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
            return true
        }
    }

    public func openPrinterProperties(printerId: String) async throws -> Bool {
        return try await openSystemPrintQueue(printerId: printerId)
    }

    // MARK: - Private helpers

    private func _refreshLocalPrinters() {
        let defaultName = NSPrintInfo.shared.printer.name
        let infos: [PrinterInfo] = NSPrinter.printerNames.map { name in
            PrinterInfo(id: name, name: name, address: "",
                        isDefault: name == defaultName,
                        isAvailable: NSPrinter(name: name) != nil)
        }
        _repoLock.lock()
        // Keep network-discovered printers (those whose ids are URIs), replace local ones.
        let networkPrinters = _printerRepository.filter { $0.id.contains("://") }
        _printerRepository = infos + networkPrinters.filter { net in
            !infos.contains(where: { $0.id == net.id })
        }
        _repoLock.unlock()
    }

    private func printHtml(html: String, settings: PrintSettings?) async throws -> PrintResult {
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let info = self.buildPrintInfo(settings)
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: info.paperSize.width, height: info.paperSize.height))
                var docAttrs: NSDictionary? = nil
                if let data = html.data(using: .utf8),
                   let attr = NSAttributedString(html: data,
                                                  options: [.documentType: NSAttributedString.DocumentType.html],
                                                  documentAttributes: &docAttrs) {
                    view.textStorage?.setAttributedString(attr)
                } else {
                    view.string = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                }
                let op = NSPrintOperation(view: view, printInfo: info)
                self.configureOperation(op, settings: settings)
                cont.resume(returning: self.makeResult(ok: op.run()))
            }
        }
    }

    private func makeView(for document: PrintDocument, info: NSPrintInfo) -> NSView {
        switch document.type {
        case .pdf:
            let v = PDFView(frame: NSRect(x: 0, y: 0, width: info.paperSize.width, height: info.paperSize.height))
            v.document = PDFDocument(data: document.data); v.autoScales = true; return v
        case .image:
            let v = NSImageView(frame: NSRect(x: 0, y: 0, width: info.paperSize.width, height: info.paperSize.height))
            if let img = NSImage(data: document.data) { v.image = img; v.imageScaling = .scaleProportionallyUpOrDown }
            return v
        default:
            let v = NSTextView(frame: NSRect(x: 0, y: 0, width: info.paperSize.width, height: info.paperSize.height))
            if document.type == .html {
                var a: NSDictionary? = nil
                if let attr = NSAttributedString(html: document.data, documentAttributes: &a) {
                    v.textStorage?.setAttributedString(attr)
                }
            } else {
                v.string = String(data: document.data, encoding: .utf8) ?? ""
            }
            return v
        }
    }

    private func addHeaderFooter(to view: NSTextView, header: String, footer: String, info: NSPrintInfo) {
        // NSTextView doesn't natively support headers/footers; prepend/append text as a simple approach.
        var full = ""
        if !header.isEmpty { full += header + "\n\n" }
        full += view.string
        if !footer.isEmpty { full += "\n\n" + footer }
        view.string = full
    }

    private func buildPrintInfo(_ settings: PrintSettings?) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as! NSPrintInfo)
        guard let s = settings else { return info }
        let (w, h): (CGFloat, CGFloat)
        switch s.paperSize {
        case .a4:     (w, h) = (595, 842)
        case .a5:     (w, h) = (420, 595)
        case .letter: (w, h) = (612, 792)
        case .legal:  (w, h) = (612, 1008)
        case .custom:
            let cw = s.customPaperWidth, ch = s.customPaperHeight
            (w, h) = (cw > 0 ? cw : 595, ch > 0 ? ch : 842)
        }
        info.paperSize = NSSize(width: w, height: h)
        let deg = s.orientationDegrees.truncatingRemainder(dividingBy: 360)
        info.orientation = (deg == 90 || deg == 270 || deg == -90 || deg == -270) ? .landscape : .portrait
        info.topMargin = s.marginTop; info.bottomMargin = s.marginBottom
        info.leftMargin = s.marginLeft; info.rightMargin = s.marginRight
        // Copies and N-up are baked into content PDFs; no dict keys needed here.
        return info
    }

    // MARK: - N-up + copies baking

    private func makeNUpPDF(source: PDFDocument, pagesPerSheet: Int, copies: Int) -> PDFDocument {
        let pps = max(1, pagesPerSheet), cp = max(1, copies)
        guard pps > 1 || cp > 1, source.pageCount > 0 else { return source }
        let cols = pagesAcross(pps), rows = pagesDown(pps)
        guard let firstPage = source.page(at: 0) else { return source }
        let srcBounds = firstPage.bounds(for: .mediaBox)
        let sheetSize = CGSize(width: srcBounds.width * CGFloat(cols),
                               height: srcBounds.height * CGFloat(rows))
        let srcCount = source.pageCount
        let sheetsPerCopy = (srcCount + pps - 1) / pps
        let result = PDFDocument()
        for _ in 0..<cp {
            for sheetIdx in 0..<sheetsPerCopy {
                let sheetData = NSMutableData()
                var box = CGRect(origin: .zero, size: sheetSize)
                guard let ctx = CGContext(consumer: CGDataConsumer(data: sheetData as CFMutableData)!,
                                          mediaBox: &box, nil) else { continue }
                ctx.beginPDFPage(nil)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box)
                for slot in 0..<pps {
                    let srcIdx = sheetIdx * pps + slot
                    guard srcIdx < srcCount, let page = source.page(at: srcIdx) else { continue }
                    let col = slot % cols
                    // PDF y=0 is bottom; top-left slot must be at highest y value
                    let row = rows - 1 - (slot / cols)
                    ctx.saveGState()
                    ctx.translateBy(x: CGFloat(col) * srcBounds.width,
                                    y: CGFloat(row) * srcBounds.height)
                    page.draw(with: .mediaBox, to: ctx)
                    ctx.restoreGState()
                }
                ctx.endPDFPage(); ctx.closePDF()
                if let sheetDoc = PDFDocument(data: sheetData as Data),
                   let sheetPage = sheetDoc.page(at: 0) {
                    result.insert(sheetPage, at: result.pageCount)
                }
            }
        }
        return result.pageCount > 0 ? result : source
    }

    private func renderTextToPDFDoc(text: String, pageSize: CGSize) -> PDFDocument? {
        let margin: CGFloat = 50, lineH: CGFloat = 18
        let linesPerPage = max(1, Int((pageSize.height - margin * 2) / lineH))
        let lines = text.components(separatedBy: "\n")
        let pageCount = max(1, (lines.count + linesPerPage - 1) / linesPerPage)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black
        ]
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!,
                                   mediaBox: &box, nil) else { return nil }
        for pageIdx in 0..<pageCount {
            ctx.beginPDFPage(nil)
            // PDF y=0 is bottom; flip so text draws top-to-bottom.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height); ctx.scaleBy(x: 1, y: -1)
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = nsCtx
            let startLine = pageIdx * linesPerPage
            for i in startLine..<min(startLine + linesPerPage, lines.count) {
                let y = margin + CGFloat(i - startLine) * lineH
                (lines[i] as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data)
    }

    private func renderImageToPDFDoc(image: NSImage, pageSize: CGSize) -> PDFDocument? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!,
                                   mediaBox: &box, nil),
              let cgImg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        ctx.beginPDFPage(nil)
        let margin: CGFloat = 50
        let drawRect = CGRect(x: margin, y: margin,
                              width: pageSize.width - margin*2, height: pageSize.height - margin*2)
        let scale = min(drawRect.width / CGFloat(cgImg.width), drawRect.height / CGFloat(cgImg.height))
        let dw = CGFloat(cgImg.width) * scale, dh = CGFloat(cgImg.height) * scale
        ctx.draw(cgImg, in: CGRect(x: drawRect.midX - dw/2, y: drawRect.midY - dh/2,
                                    width: dw, height: dh))
        ctx.endPDFPage(); ctx.closePDF()
        return PDFDocument(data: data as Data)
    }

    private func printNUpPDF(_ doc: PDFDocument, settings: PrintSettings?,
                              cont: CheckedContinuation<PrintResult, Error>) {
        let info = buildPrintInfo(settings)
        let view = PDFView(frame: NSRect(x: 0, y: 0,
                                         width: info.paperSize.width, height: info.paperSize.height))
        view.document = doc; view.autoScales = true
        let op = NSPrintOperation(view: view, printInfo: info)
        configureOperation(op, settings: settings)
        cont.resume(returning: makeResult(ok: op.run()))
    }

    private func configureOperation(_ op: NSPrintOperation, settings: PrintSettings?) {
        let show = settings?.showPrintDialog ?? true
        op.showsPrintPanel = show; op.showsProgressPanel = show
        if !show, let pid = settings?.printerId, !pid.isEmpty, let printer = NSPrinter(name: pid) {
            op.printInfo.printer = printer
        }
    }

    private func pagesAcross(_ n: Int) -> Int {
        switch n { case 2: return 2; case 4: return 2; case 6: return 3; case 8: return 4; case 16: return 4; default: return 1 }
    }
    private func pagesDown(_ n: Int) -> Int {
        let a = pagesAcross(n); return a == 0 ? 1 : Int(ceil(Double(n) / Double(a)))
    }

    private func makeResult(ok: Bool) -> PrintResult {
        PrintResult(success: ok, jobId: ok ? UUID().uuidString : "",
                    errorMessage: ok ? "" : "Print failed or was cancelled",
                    errorCode: ok ? "" : "CANCELLED")
    }

    private func parseHostPort(_ uri: String) -> (String, Int) {
        let stripped = uri
            .replacingOccurrences(of: "ipp://", with: "")
            .replacingOccurrences(of: "ipps://", with: "")
            .replacingOccurrences(of: "socket://", with: "")
        let hostPart = stripped.components(separatedBy: "/").first ?? stripped
        if let colon = hostPart.lastIndex(of: ":") {
            return (String(hostPart[..<colon]),
                    Int(String(hostPart[hostPart.index(after: colon)...])) ?? 631)
        }
        return (hostPart, 631)
    }

    private func parseSocketAddr(_ uri: String) -> (String, Int) {
        let stripped = uri.replacingOccurrences(of: "socket://", with: "")
        let last = stripped.lastIndex(of: ":") ?? stripped.endIndex
        if last < stripped.endIndex {
            return (String(stripped[..<last]), Int(String(stripped[stripped.index(after: last)...])) ?? 9100)
        }
        return (stripped, 9100)
    }

    private func performNWConnectionPrint(uri: String, data: Data, copies: Int, timeout: TimeInterval) -> PrintResult {
        let (host, port) = parseSocketAddr(uri)
        
        _rawLock.lock()
        _isRawCancelled = false
        _rawLock.unlock()

        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return PrintResult(success: false, jobId: "", errorMessage: "Invalid port \(port)", errorCode: "INVALID_PORT")
        }

        let connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        
        _rawLock.lock()
        if _isRawCancelled {
            _rawLock.unlock()
            return PrintResult(success: false, jobId: "", errorMessage: "Cancelled before connecting", errorCode: "CANCELLED")
        }
        _activeRawConnection = connection
        _rawLock.unlock()

        let sema = DispatchSemaphore(value: 0)
        var writeResult = PrintResult(success: false, jobId: "", errorMessage: "Socket timed out", errorCode: "TIMEOUT")
        var isConnected = false
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                isConnected = true
                sema.signal()
            case .failed(let error):
                writeResult = PrintResult(success: false, jobId: "", errorMessage: error.localizedDescription, errorCode: "SOCKET_ERROR")
                sema.signal()
            case .cancelled:
                writeResult = PrintResult(success: false, jobId: "", errorMessage: "Socket cancelled", errorCode: "CANCELLED")
                sema.signal()
            default:
                break
            }
        }
        
        connection.start(queue: .global(qos: .utility))
        
        let connectWait = sema.wait(timeout: .now() + timeout)
        if connectWait == .timedOut {
            connection.cancel()
            _rawLock.lock()
            if _activeRawConnection === connection { _activeRawConnection = nil }
            _rawLock.unlock()
            return PrintResult(success: false, jobId: "", errorMessage: "Socket connection timed out", errorCode: "TIMEOUT")
        }
        
        guard isConnected else {
            connection.cancel()
            _rawLock.lock()
            if _activeRawConnection === connection { _activeRawConnection = nil }
            _rawLock.unlock()
            return writeResult
        }
        
        var sendSuccess = true
        var sendErrorMsg = ""
        var sendErrorCode = ""
        
        for _ in 0..<max(1, copies) {
            _rawLock.lock()
            if _isRawCancelled {
                _rawLock.unlock()
                sendSuccess = false
                sendErrorMsg = "Socket cancelled"
                sendErrorCode = "CANCELLED"
                break
            }
            _rawLock.unlock()
            
            let sendSema = DispatchSemaphore(value: 0)
            connection.send(content: data, completion: .contentProcessed({ error in
                if let err = error {
                    sendSuccess = false
                    sendErrorMsg = err.localizedDescription
                    sendErrorCode = "SOCKET_WRITE_ERROR"
                }
                sendSema.signal()
            }))
            
            let sendWait = sendSema.wait(timeout: .now() + timeout)
            if sendWait == .timedOut {
                sendSuccess = false
                sendErrorMsg = "Socket write timed out"
                sendErrorCode = "TIMEOUT"
                break
            }
            
            if !sendSuccess {
                break
            }
        }
        
        connection.cancel()
        
        _rawLock.lock()
        if _activeRawConnection === connection { _activeRawConnection = nil }
        _rawLock.unlock()
        
        if sendSuccess {
            return PrintResult(success: true, jobId: UUID().uuidString, errorMessage: "", errorCode: "")
        } else {
            return PrintResult(success: false, jobId: "", errorMessage: sendErrorMsg, errorCode: sendErrorCode)
        }
    }

    private func socketPrint(uri: String, data: Data, copies: Int, timeout: TimeInterval = 30) -> PrintResult {
        return performNWConnectionPrint(uri: uri, data: data, copies: copies, timeout: timeout)
    }

    private func rawSocketPrint(uri: String, data: Data, copies: Int, timeout: TimeInterval) -> PrintResult {
        return performNWConnectionPrint(uri: uri, data: data, copies: copies, timeout: timeout)
    }

    private func rawIppPrint(uri: String, data: Data, mimeType: String, jobName: String, copies: Int, timeout: TimeInterval) -> PrintResult {
        let httpUrl = uri.replacingOccurrences(of: "ipp://", with: "http://")
                        .replacingOccurrences(of: "ipps://", with: "https://")
        guard let url = URL(string: httpUrl) else {
            return PrintResult(success: false, jobId: "", errorMessage: "Invalid IPP URI", errorCode: "INVALID_URI")
        }
        let ippRequest = buildIppPrintJobRequest(printerUri: uri, jobName: jobName,
                                                   mimeType: mimeType, copies: copies,
                                                   pagesPerSheet: 1, data: data)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        request.httpBody = ippRequest
        var result = PrintResult(success: false, jobId: "", errorMessage: "Timeout", errorCode: "TIMEOUT")
        let sema = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let err = error {
                let code = (err as NSError).code == NSURLErrorCancelled ? "CANCELLED" : "IPP_ERROR"
                result = PrintResult(success: false, jobId: "", errorMessage: err.localizedDescription, errorCode: code)
            } else if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                result = PrintResult(success: true, jobId: UUID().uuidString, errorMessage: "", errorCode: "")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                result = PrintResult(success: false, jobId: "", errorMessage: "HTTP \(code)", errorCode: "IPP_HTTP_ERROR")
            }
            sema.signal()
        }
        _rawLock.lock(); _activeRawTask = task; _rawLock.unlock()
        task.resume()
        sema.wait()
        _rawLock.lock(); _activeRawTask = nil; _rawLock.unlock()
        return result
    }

    private func ippPrint(uri: String, data: Data, mimeType: String, jobName: String, copies: Int, pagesPerSheet: Int = 1, timeout: TimeInterval = 30) -> PrintResult {
        let httpUrl = uri.replacingOccurrences(of: "ipp://", with: "http://")
                        .replacingOccurrences(of: "ipps://", with: "https://")
        guard let url = URL(string: httpUrl) else {
            return PrintResult(success: false, jobId: "", errorMessage: "Invalid IPP URI", errorCode: "INVALID_URI")
        }
        let reqBody = buildIppPrintJobRequest(printerUri: uri, jobName: jobName,
                                              mimeType: mimeType, copies: copies,
                                              pagesPerSheet: pagesPerSheet, data: data)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        request.httpBody = reqBody
        var result = PrintResult(success: false, jobId: "", errorMessage: "Timeout", errorCode: "TIMEOUT")
        let sema = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let err = error {
                let code = (err as NSError).code == NSURLErrorCancelled ? "CANCELLED" : "IPP_ERROR"
                result = PrintResult(success: false, jobId: "", errorMessage: err.localizedDescription, errorCode: code)
            } else if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                result = PrintResult(success: true, jobId: UUID().uuidString, errorMessage: "", errorCode: "")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                result = PrintResult(success: false, jobId: "", errorMessage: "HTTP \(code)", errorCode: "IPP_HTTP_ERROR")
            }
            sema.signal()
        }
        _rawLock.lock(); _activeRawTask = task; _rawLock.unlock()
        task.resume()
        sema.wait()
        _rawLock.lock(); _activeRawTask = nil; _rawLock.unlock()
        return result
    }

    private func buildIppPrintJobRequest(printerUri: String, jobName: String,
                                          mimeType: String, copies: Int, pagesPerSheet: Int, data: Data) -> Data {
        var buf = Data()
        func w2(_ v: Int) { buf.append(UInt8((v >> 8) & 0xFF)); buf.append(UInt8(v & 0xFF)) }
        func w4(_ v: Int) { w2((v >> 16) & 0xFFFF); w2(v & 0xFFFF) }
        func strAttr(_ tag: Int, _ name: String, _ value: String) {
            buf.append(UInt8(tag)); w2(name.utf8.count); buf.append(name.data(using: .utf8)!)
            let vd = value.data(using: .utf8)!; w2(vd.count); buf.append(vd)
        }
        func intAttr(_ name: String, _ value: Int) {
            buf.append(0x21); w2(name.utf8.count); buf.append(name.data(using: .utf8)!)
            w2(4); w4(value)
        }
        buf.append(1); buf.append(1); w2(0x0002); w4(1)
        buf.append(0x01)
        strAttr(0x47, "attributes-charset", "utf-8")
        strAttr(0x48, "attributes-natural-language", "en")
        strAttr(0x45, "printer-uri", printerUri)
        strAttr(0x42, "job-name", jobName.isEmpty ? "Document" : jobName)
        strAttr(0x42, "requesting-user-name", "Flutter")
        strAttr(0x49, "document-format", mimeType)
        buf.append(0x02)
        if copies > 1 { intAttr("copies", copies) }
        if pagesPerSheet > 1 { intAttr("number-up", pagesPerSheet) }
        buf.append(0x03)
        buf.append(data)
        return buf
    }

    // MARK: - Raw protocol printing

    public func printRaw(data: Data, settings: PrintSettings?) async throws -> PrintResult {
        guard let uri = settings?.printerId, !uri.isEmpty else {
            return PrintResult(success: false, jobId: "", errorMessage: "printerId required for raw print", errorCode: "NO_PRINTER")
        }
        let copies = Int(max(1, settings?.copies ?? 1))
        let timeout = TimeInterval(max(5, settings?.networkTimeoutSeconds ?? 30))
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                if uri.hasPrefix("ipp://") || uri.hasPrefix("ipps://") {
                    cont.resume(returning: self.rawIppPrint(uri: uri, data: data,
                                                             mimeType: "application/octet-stream",
                                                             jobName: settings?.jobName ?? "Raw",
                                                             copies: copies, timeout: timeout))
                } else {
                    cont.resume(returning: self.rawSocketPrint(uri: uri, data: data, copies: copies, timeout: timeout))
                }
            }
        }
    }

    public func printEscPos(escPosData: Data, settings: PrintSettings?) async throws -> PrintResult {
        guard let uri = settings?.printerId, !uri.isEmpty else {
            return PrintResult(success: false, jobId: "", errorMessage: "printerId required for ESC/POS print", errorCode: "NO_PRINTER")
        }
        let copies = Int(max(1, settings?.copies ?? 1))
        let timeout = TimeInterval(max(5, settings?.networkTimeoutSeconds ?? 30))
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                if uri.hasPrefix("ipp://") || uri.hasPrefix("ipps://") {
                    cont.resume(returning: self.rawIppPrint(uri: uri, data: escPosData,
                                                             mimeType: "application/vnd.epson.esc-p",
                                                             jobName: settings?.jobName ?? "Receipt",
                                                             copies: copies, timeout: timeout))
                } else {
                    cont.resume(returning: self.rawSocketPrint(uri: uri, data: escPosData, copies: copies, timeout: timeout))
                }
            }
        }
    }

    public func printZpl(zpl: String, settings: PrintSettings?) async throws -> PrintResult {
        guard let data = zpl.data(using: .utf8) else {
            return PrintResult(success: false, jobId: "", errorMessage: "ZPL encoding failed", errorCode: "ENCODE_ERROR")
        }
        guard let uri = settings?.printerId, !uri.isEmpty else {
            return PrintResult(success: false, jobId: "", errorMessage: "printerId required for ZPL print", errorCode: "NO_PRINTER")
        }
        let timeout = TimeInterval(max(5, settings?.networkTimeoutSeconds ?? 30))
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                if uri.hasPrefix("ipp://") || uri.hasPrefix("ipps://") {
                    cont.resume(returning: self.rawIppPrint(uri: uri, data: data,
                                                             mimeType: "application/vnd.zebra-zpl",
                                                             jobName: settings?.jobName ?? "ZPL Label",
                                                             copies: 1, timeout: timeout))
                } else {
                    cont.resume(returning: self.rawSocketPrint(uri: uri, data: data, copies: 1, timeout: timeout))
                }
            }
        }
    }

    public func cancelRawPrint() async throws -> Bool {
        _rawLock.lock(); defer { _rawLock.unlock() }
        _isRawCancelled = true
        var cancelled = false
        if let conn = _activeRawConnection {
            conn.cancel()
            _activeRawConnection = nil
            cancelled = true
        }
        if let task = _activeRawTask {
            task.cancel()
            _activeRawTask = nil
            cancelled = true
        }
        return cancelled
    }

    // MARK: - Detailed printer status

    public func getPrinterStatusDetail(printerId: String, timeoutSeconds: Int64?) async throws -> PrinterStatusDetail {
        let empty = PrinterStatusDetail(printerId: printerId, isOnline: false, isReady: false,
                                         hasPaperJam: false, isOutOfPaper: false, isOutOfInk: false,
                                         inkLevelBlack: -1, inkLevelCyan: -1, inkLevelMagenta: -1,
                                         inkLevelYellow: -1, tonerLevel: -1, paperLevel: -1,
                                         jobsInQueue: 0, isWarmingUp: false,
                                         printerState: "", stateReasons: "", statusMessage: "",
                                         errorCode: "", isDuplexSupported: false, isColorSupported: false)
        guard !printerId.isEmpty else { return empty }

        let timeout = TimeInterval(max(5, timeoutSeconds ?? 30))
        if printerId.hasPrefix("ipp://") || printerId.hasPrefix("ipps://") {
            return await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(returning: self.ippGetPrinterAttributes(uri: printerId, timeout: timeout))
                }
            }
        }
        // Plain IP / socket URI: TCP probe respecting timeout
        let (host, port) = parseSocketAddr(printerId)
        var inputStream: InputStream?, outputStream: OutputStream?
        var probeResult = false
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global(qos: .utility).async {
            Stream.getStreamsToHost(withName: host, port: port,
                                     inputStream: &inputStream, outputStream: &outputStream)
            probeResult = outputStream != nil
            outputStream?.close(); inputStream?.close()
            group.leave()
        }
        let _ = group.wait(timeout: .now() + timeout)
        let online = probeResult
        return PrinterStatusDetail(printerId: printerId, isOnline: online, isReady: online,
                                    hasPaperJam: false, isOutOfPaper: false, isOutOfInk: false,
                                    inkLevelBlack: -1, inkLevelCyan: -1, inkLevelMagenta: -1,
                                    inkLevelYellow: -1, tonerLevel: -1, paperLevel: -1,
                                    jobsInQueue: 0, isWarmingUp: false,
                                    printerState: online ? "idle" : "stopped",
                                    stateReasons: online ? "" : "offline-report",
                                    statusMessage: online ? "" : "Printer offline",
                                    errorCode: online ? "" : "OFFLINE",
                                    isDuplexSupported: false, isColorSupported: false)
    }

    private func ippGetPrinterAttributes(uri: String, timeout: TimeInterval = 15) -> PrinterStatusDetail {
        let httpUrl = uri.replacingOccurrences(of: "ipp://", with: "http://")
                        .replacingOccurrences(of: "ipps://", with: "https://")
        guard let url = URL(string: httpUrl) else {
            return PrinterStatusDetail(printerId: uri, isOnline: false, isReady: false,
                                        hasPaperJam: false, isOutOfPaper: false, isOutOfInk: false,
                                        inkLevelBlack: -1, inkLevelCyan: -1, inkLevelMagenta: -1,
                                        inkLevelYellow: -1, tonerLevel: -1, paperLevel: -1,
                                        jobsInQueue: 0, isWarmingUp: false,
                                        printerState: "", stateReasons: "", statusMessage: "",
                                        errorCode: "INVALID_URI", isDuplexSupported: false, isColorSupported: false)
        }
        let reqBody = buildIppGetPrinterAttributesRequest(printerUri: uri)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        request.httpBody = reqBody
        var respData: Data?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            respData = data; sema.signal()
        }.resume()
        sema.wait()
        guard let body = respData, body.count > 8 else {
            return PrinterStatusDetail(printerId: uri, isOnline: false, isReady: false,
                                        hasPaperJam: false, isOutOfPaper: false, isOutOfInk: false,
                                        inkLevelBlack: -1, inkLevelCyan: -1, inkLevelMagenta: -1,
                                        inkLevelYellow: -1, tonerLevel: -1, paperLevel: -1,
                                        jobsInQueue: 0, isWarmingUp: false,
                                        printerState: "", stateReasons: "", statusMessage: "",
                                        errorCode: "NO_RESPONSE", isDuplexSupported: false, isColorSupported: false)
        }
        return parseIppPrinterAttributes(uri: uri, data: body)
    }

    private func buildIppGetPrinterAttributesRequest(printerUri: String) -> Data {
        var buf = Data()
        func w2(_ v: Int) { buf.append(UInt8((v >> 8) & 0xFF)); buf.append(UInt8(v & 0xFF)) }
        func w4(_ v: Int) { w2((v >> 16) & 0xFFFF); w2(v & 0xFFFF) }
        func strAttr(_ tag: Int, _ name: String, _ value: String) {
            buf.append(UInt8(tag)); w2(name.utf8.count); buf.append(name.data(using: .utf8)!)
            let vd = value.data(using: .utf8)!; w2(vd.count); buf.append(vd)
        }
        buf.append(1); buf.append(1); w2(0x000B); w4(1)
        buf.append(0x01)
        strAttr(0x47, "attributes-charset", "utf-8")
        strAttr(0x48, "attributes-natural-language", "en")
        strAttr(0x45, "printer-uri", printerUri)
        buf.append(0x02)
        let attrs = ["printer-state","printer-state-reasons","printer-state-message",
                     "printer-is-accepting-jobs","queued-job-count",
                     "marker-levels","marker-names","marker-colors","marker-types",
                     "copies-supported","sides-supported","color-supported"]
        for (i, a) in attrs.enumerated() {
            let nameData = i == 0 ? "requested-attributes" : ""
            buf.append(0x44)
            w2(nameData.utf8.count)
            if !nameData.isEmpty { buf.append(nameData.data(using: .utf8)!) }
            let ad = a.data(using: .utf8)!; w2(ad.count); buf.append(ad)
        }
        buf.append(0x03)
        return buf
    }

    private func parseIppPrinterAttributes(uri: String, data: Data) -> PrinterStatusDetail {
        var idx = 8
        var printerState = ""
        var stateReasons = [String]()
        var stateMessage = ""
        var isAccepting = true
        var queuedJobs: Int64 = 0
        var markerLevels = [Int]()
        var markerTypes = [String]()
        var supportsColor = false
        var supportsDuplex = false

        func read2() -> Int {
            guard idx + 1 < data.count else { return 0 }
            let v = (Int(data[idx]) << 8) | Int(data[idx+1]); idx += 2; return v
        }
        func read4() -> Int {
            guard idx + 3 < data.count else { return 0 }
            let v = (Int(data[idx]) << 24) | (Int(data[idx+1]) << 16) | (Int(data[idx+2]) << 8) | Int(data[idx+3])
            idx += 4; return v
        }
        func readStr(_ n: Int) -> String {
            guard idx + n <= data.count else { idx += n; return "" }
            let s = String(data: data[idx..<(idx+n)], encoding: .utf8) ?? ""; idx += n; return s
        }

        while idx < data.count {
            let tag = Int(data[idx]); idx += 1
            if tag == 0x03 { break }
            if tag <= 0x0F { continue }
            let nameLen = read2()
            let attrName = readStr(nameLen)
            let valLen = read2()
            let valStart = idx
            if tag == 0x23 || tag == 0x21 {
                let v = read4()
                if attrName == "printer-state" {
                    printerState = v == 3 ? "idle" : v == 4 ? "processing" : "stopped"
                } else if attrName == "queued-job-count" {
                    queuedJobs = Int64(v)
                } else if attrName == "marker-levels" || attrName.isEmpty {
                    markerLevels.append(v)
                }
            } else if tag == 0x22 {
                let v = idx < data.count ? data[idx] != 0 : false; idx += valLen
                if attrName == "printer-is-accepting-jobs" { isAccepting = v }
                else if attrName == "color-supported" { supportsColor = v }
            } else {
                let v = readStr(valLen)
                if attrName == "printer-state-reasons" || attrName.isEmpty { stateReasons.append(v) }
                else if attrName == "printer-state-message" { stateMessage = v }
                else if attrName == "marker-types" || attrName.isEmpty { markerTypes.append(v) }
                else if attrName == "sides-supported" && v.contains("two-sided") { supportsDuplex = true }
                idx = valStart + valLen
            }
        }

        let reasons = stateReasons.filter { !$0.isEmpty }.joined(separator: ",")
        let hasPaperJam = reasons.contains("media-jam")
        let outOfPaper = reasons.contains("media-empty") || reasons.contains("media-needed")
        let outOfInk = reasons.contains("toner-empty") || reasons.contains("toner-low") ||
                       reasons.contains("marker-supply-empty")
        let isWarmingUp = reasons.contains("warming-up")
        let isReady = isAccepting && printerState != "stopped"
        var inkBlack: Int64 = -1, inkCyan: Int64 = -1, inkMagenta: Int64 = -1, inkYellow: Int64 = -1, toner: Int64 = -1
        for (i, level) in markerLevels.enumerated() {
            let typeLower = i < markerTypes.count ? markerTypes[i].lowercased() : ""
            let l = Int64(level)
            if typeLower.contains("toner") { toner = toner < 0 ? l : toner }
            else if typeLower.contains("cyan") { inkCyan = l }
            else if typeLower.contains("magenta") { inkMagenta = l }
            else if typeLower.contains("yellow") { inkYellow = l }
            else if typeLower.contains("black") || typeLower.contains("ink") { inkBlack = l }
        }
        return PrinterStatusDetail(printerId: uri, isOnline: true, isReady: isReady,
                                    hasPaperJam: hasPaperJam, isOutOfPaper: outOfPaper, isOutOfInk: outOfInk,
                                    inkLevelBlack: inkBlack, inkLevelCyan: inkCyan,
                                    inkLevelMagenta: inkMagenta, inkLevelYellow: inkYellow,
                                    tonerLevel: toner, paperLevel: -1,
                                    jobsInQueue: queuedJobs, isWarmingUp: isWarmingUp,
                                    printerState: printerState, stateReasons: reasons,
                                    statusMessage: stateMessage, errorCode: "",
                                    isDuplexSupported: supportsDuplex, isColorSupported: supportsColor)
    }

    private func runLpArgs(_ args: [String]) async -> Bool {
        return await runShell("/usr/bin/lp", args: args)
    }

    private func runShell(_ path: String, args: [String]) async -> Bool {
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                try? proc.run(); proc.waitUntilExit()
                cont.resume(returning: proc.terminationStatus == 0)
            }
        }
    }
}
