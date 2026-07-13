import Foundation
import UIKit
import Combine
import Network
import PDFKit

public class NitroPrintingImpl: NSObject, HybridNitroPrintingProtocol,
                                 UIPrintInteractionControllerDelegate,
                                 NetServiceBrowserDelegate, NetServiceDelegate {

    // MARK: - Streams

    private let _onPrintJobChanged     = PassthroughSubject<PrintJobUpdate, Never>()
    private let _onPrinterStatusChanged = PassthroughSubject<PrinterStatus, Never>()
    private let _onPrinterDiscovered   = PassthroughSubject<DiscoveredPrinter, Never>()

    public var onPrintJobChanged: AnyPublisher<PrintJobUpdate, Never> {
        _onPrintJobChanged.eraseToAnyPublisher()
    }
    public var onPrinterStatusChanged: AnyPublisher<PrinterStatus, Never> {
        _onPrinterStatusChanged.eraseToAnyPublisher()
    }
    public var onPrinterDiscovered: AnyPublisher<DiscoveredPrinter, Never> {
        _onPrinterDiscovered.eraseToAnyPublisher()
    }

    // MARK: - Printer repository (populated by discovery)

    private var _printerRepository: [PrinterInfo] = []
    private let _repoLock = NSLock()

    // MARK: - Discovery state

    private var netBrowser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []

    // MARK: - Pending paper size for choosePaper delegate

    private var pendingPaperSize: PaperSize = .a4
    private var pendingCustomSize: CGSize = CGSize(width: 595, height: 842)

    // MARK: - Raw print cancellation state

    private let _rawLock = NSLock()
    private var _activeRawConnection: NWConnection?
    private var _activeRawTask: URLSessionDataTask?
    private var _isRawCancelled = false

    // MARK: - UIPrintInteractionControllerDelegate

    public func printInteractionController(
        _ printInteractionController: UIPrintInteractionController,
        choosePaper paperList: [UIPrintPaper]
    ) -> UIPrintPaper {
        return UIPrintPaper.bestPaper(forPageSize: pendingCustomSize, withPapersFrom: paperList)
    }

    // MARK: - Synchronous quick-lookup (no Isolate overhead)

    public func isPrintingSupported() -> Bool {
        return UIPrintInteractionController.isPrintingAvailable
    }

    public func getPrintersCount() -> Int64 {
        _repoLock.lock(); defer { _repoLock.unlock() }
        return Int64(_printerRepository.count)
    }

    public func getAllPrinters() -> [PrinterInfo] {
        _repoLock.lock(); defer { _repoLock.unlock() }
        return _printerRepository
    }

    public func getPrinterAt(index: Int64) throws -> PrinterInfo {
        _repoLock.lock(); defer { _repoLock.unlock() }
        guard index >= 0, Int(index) < _printerRepository.count else {
            throw NSError(domain: "NitroPrinting", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Index \(index) out of range (count: \(_printerRepository.count))"])
        }
        return _printerRepository[Int(index)]
    }

    public func getDefaultPrinter() -> PrinterInfo {
        _repoLock.lock(); defer { _repoLock.unlock() }
        return _printerRepository.first(where: { $0.isDefault })
            ?? PrinterInfo(id: "default", name: "Default Printer", address: "",
                           isDefault: true, isAvailable: true)
    }

    public func getPrinterDriverVersion(printerId: String) -> String { return "" }

    public func getPrinterCapabilities(printerId: String) throws -> PrinterCapabilities {
        _repoLock.lock(); defer { _repoLock.unlock() }
        guard _printerRepository.contains(where: { $0.id == printerId }) else {
            throw NSError(domain: "NitroPrinting", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Printer '\(printerId)' not found"])
        }
        return PrinterCapabilities(
            supportsColor: true, supportsDuplex: false, supportsCopy: false,
            maxCopies: 99, minMarginTop: 0, minMarginBottom: 0, minMarginLeft: 0, minMarginRight: 0,
            supportsA4: true, supportsA5: true, supportsLetter: true, supportsLegal: true,
            supportsDraftQuality: true, supportsNormalQuality: true,
            supportsHighQuality: true, supportsBestQuality: true,
            maxResolutionDpi: 600, supportsCustomPaper: true, supportsBorderless: false,
            inputTrays: ""
        )
    }

    // MARK: - Print methods

    public func printText(text: String, settings: PrintSettings?) async throws -> PrintResult {
        guard UIPrintInteractionController.isPrintingAvailable else { return unavailableResult() }
        if settings?.showPrintDialog == false {
            return try await directPrint(data: renderTextToPdfData(text: text, settings: settings),
                                          mimeType: "application/pdf", settings: settings)
        }
        let copies = Int(max(1, settings?.copies ?? 1))
        let pps = Int(max(1, settings?.pagesPerSheet ?? 1))
        if copies > 1 || pps > 1,
           let pdfDoc = PDFDocument(data: renderTextToPdfData(text: text, settings: settings)) {
            return try await withCheckedThrowingContinuation { cont in
                DispatchQueue.main.async {
                    let c = UIPrintInteractionController.shared
                    self.prepareController(c, settings: settings, outputType: .general)
                    c.printPageRenderer = _PDFPrintPageRenderer(document: pdfDoc, copies: copies, pagesPerSheet: pps)
                    self.dispatchPrint(c, settings: settings, cont: cont)
                }
            }
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let c = UIPrintInteractionController.shared
                self.prepareController(c, settings: settings, outputType: .general)
                c.printFormatter = UISimpleTextPrintFormatter(text: text)
                self.dispatchPrint(c, settings: settings, cont: cont)
            }
        }
    }

    public func printImage(imageData: Data, settings: PrintSettings?) async throws -> PrintResult {
        guard let image = UIImage(data: imageData) else {
            return PrintResult(success: false, jobId: "", errorMessage: "Invalid image data", errorCode: "INVALID_IMAGE")
        }
        guard UIPrintInteractionController.isPrintingAvailable else { return unavailableResult() }
        if settings?.showPrintDialog == false {
            guard let pdf = renderImageToPdfData(image: image, settings: settings) else { return unavailableResult() }
            return try await directPrint(data: pdf, mimeType: "application/pdf", settings: settings)
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let c = UIPrintInteractionController.shared
                self.prepareController(c, settings: settings, outputType: .photo)
                c.printPageRenderer = self.makeImageRenderer(image: image, settings: settings)
                self.dispatchPrint(c, settings: settings, cont: cont)
            }
        }
    }

    public func printPdf(pdfData: Data, settings: PrintSettings?) async throws -> PrintResult {
        guard UIPrintInteractionController.isPrintingAvailable else { return unavailableResult() }
        if settings?.showPrintDialog == false {
            return try await directPrint(data: pdfData, mimeType: "application/pdf", settings: settings)
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let c = UIPrintInteractionController.shared
                self.prepareController(c, settings: settings, outputType: .general)
                let copies = Int(max(1, settings?.copies ?? 1))
                let pps = Int(max(1, settings?.pagesPerSheet ?? 1))
                if let pdfDoc = PDFDocument(data: pdfData) {
                    c.printPageRenderer = _PDFPrintPageRenderer(document: pdfDoc, copies: copies, pagesPerSheet: pps)
                } else {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
                    try? pdfData.write(to: url)
                    c.printingItem = url
                }
                self.dispatchPrint(c, settings: settings) { [weak self] _, completed, error in
                    guard let self else { cont.resume(returning: .init(success: false, jobId: "", errorMessage: "Deallocated", errorCode: "INTERNAL")); return }
                    cont.resume(returning: self.makeResult(completed: completed, error: error))
                }
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

    public func printBatch(
        documents: [PrintDocument],
        stopOnError: Bool,
        settings: PrintSettings?
    ) async throws -> [PrintResult] {
        var results: [PrintResult] = []
        for doc in documents {
            let result = try await printDocument(document: doc, settings: settings)
            results.append(result)
            if stopOnError && !result.success { break }
        }
        return results
    }

    public func showPrintDialog(
        document: PrintDocument,
        initialSettings: PrintSettings?
    ) async throws -> PrintDialogResult {
        let confirmedSettings = initialSettings ?? PrintSettings(
            printerId: "", paperSize: .a4, orientationDegrees: 0, quality: .normal,
            copies: 1, collate: false, duplex: false, color: true,
            marginTop: 0, marginBottom: 0, marginLeft: 0, marginRight: 0,
            jobName: "", pagesPerSheet: 1, showPrintDialog: true,
            pageRangeFrom: 0, pageRangeTo: 0, customPaperWidth: 0, customPaperHeight: 0,
            fitToPage: false, mediaType: .plain, headerText: "", footerText: "",
            inputTray: "", networkTimeoutSeconds: 30
        )
        guard UIPrintInteractionController.isPrintingAvailable else {
            return PrintDialogResult(confirmed: false, confirmedSettings: confirmedSettings,
                                    errorMessage: "Printing not available on this device.")
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let c = UIPrintInteractionController.shared
                self.prepareController(c, settings: initialSettings, outputType: .general)
                switch document.type {
                case .plainText:
                    c.printFormatter = UISimpleTextPrintFormatter(
                        text: String(data: document.data, encoding: .utf8) ?? ""
                    )
                case .html:
                    c.printFormatter = UIMarkupTextPrintFormatter(
                        markupText: String(data: document.data, encoding: .utf8) ?? ""
                    )
                case .pdf:
                    if let pdfDoc = PDFDocument(data: document.data) {
                        let copies = Int(max(1, initialSettings?.copies ?? 1))
                        let pps = Int(max(1, initialSettings?.pagesPerSheet ?? 1))
                        c.printPageRenderer = _PDFPrintPageRenderer(document: pdfDoc, copies: copies, pagesPerSheet: pps)
                    } else {
                        c.printingItem = document.data
                    }
                case .image:
                    if let image = UIImage(data: document.data) {
                        c.printPageRenderer = self.makeImageRenderer(image: image, settings: initialSettings)
                    }
                }
                self.dispatchPrint(c, settings: initialSettings) { [weak self] _, completed, error in
                    guard self != nil else {
                        cont.resume(returning: PrintDialogResult(
                            confirmed: false, confirmedSettings: confirmedSettings,
                            errorMessage: "Deallocated"))
                        return
                    }
                    if let err = error {
                        cont.resume(returning: PrintDialogResult(
                            confirmed: false, confirmedSettings: confirmedSettings,
                            errorMessage: err.localizedDescription))
                    } else {
                        cont.resume(returning: PrintDialogResult(
                            confirmed: completed, confirmedSettings: confirmedSettings,
                            errorMessage: completed ? "" : "User cancelled the print dialog."))
                    }
                }
            }
        }
    }

    public func printFile(filePath: String, settings: PrintSettings?) async throws -> Bool {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath),
              UIPrintInteractionController.canPrint(url) else { return false }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let c = UIPrintInteractionController.shared
                self.prepareController(c, settings: settings, outputType: .general)
                c.printingItem = url
                self.dispatchPrint(c, settings: settings) { _, completed, error in
                    cont.resume(returning: completed && error == nil)
                }
            }
        }
    }

    // MARK: - Export / Virtual print

    public func renderPreview(document: PrintDocument, settings: PrintSettings?) async throws -> PreviewResult {
        let pdf: Data
        switch document.type {
        case .pdf:
            pdf = document.data
        case .plainText:
            pdf = renderTextToPdfData(text: String(data: document.data, encoding: .utf8) ?? "", settings: settings)
        case .image:
            guard let image = UIImage(data: document.data),
                  let d = renderImageToPdfData(image: image, settings: settings) else {
                return PreviewResult(bytes: nil, length: 0)
            }
            pdf = d
        case .html:
            let html = String(data: document.data, encoding: .utf8) ?? ""
            pdf = renderTextToPdfData(text: html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), settings: settings)
        }
        let count = pdf.count
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        pdf.copyBytes(to: ptr, count: count)
        return PreviewResult(bytes: ptr, length: Int64(count))
    }

    public func getPageCount(document: PrintDocument) async throws -> Int64 {
        switch document.type {
        case .pdf:
            return Int64(PDFDocument(data: document.data)?.pageCount ?? 1)
        case .image:
            return 1
        default:
            return 1
        }
    }

    public func printToFile(document: PrintDocument, outputPath: String, settings: PrintSettings?) async throws -> Bool {
        let pdf: Data
        switch document.type {
        case .pdf:        pdf = document.data
        case .plainText:  pdf = renderTextToPdfData(text: String(data: document.data, encoding: .utf8) ?? "", settings: settings)
        case .image:
            guard let img = UIImage(data: document.data),
                  let d = renderImageToPdfData(image: img, settings: settings) else { return false }
            pdf = d
        case .html:
            let html = String(data: document.data, encoding: .utf8) ?? ""
            pdf = renderTextToPdfData(text: html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), settings: settings)
        }
        do { try pdf.write(to: URL(fileURLWithPath: outputPath)); return true }
        catch { return false }
    }

    // MARK: - Job management

    public func cancelPrintJob(jobId: String) async throws -> Bool { return false }
    public func pausePrintJob(jobId: String) async throws -> Bool   { return false }
    public func resumePrintJob(jobId: String) async throws -> Bool  { return false }
    public func clearPrintQueue() async throws -> Bool              { return false }
    public func getPrintJobsCount() async throws -> Int64           { return 0 }

    public func getPrintJobAt(index: Int64) async throws -> PrintJob {
        throw NSError(domain: "NitroPrinting", code: 404, userInfo: [NSLocalizedDescriptionKey: "No tracked print jobs"])
    }
    public func getPrintJobStatus(jobId: String) async throws -> PrintJob {
        throw NSError(domain: "NitroPrinting", code: 404, userInfo: [NSLocalizedDescriptionKey: "No tracked print jobs"])
    }

    // MARK: - Discovery

    public func startPrinterDiscovery() async throws -> Bool {
        _repoLock.lock(); _printerRepository.removeAll(); _repoLock.unlock()
        await MainActor.run {
            netBrowser?.stop()
            resolvingServices.removeAll()
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
            netBrowser?.stop()
            netBrowser = nil
            resolvingServices.removeAll()
        }
        return true
    }

    // MARK: - NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolvingServices.removeAll { $0 === service }
    }

    // MARK: - NetServiceDelegate

    public func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName ?? sender.name
        let port = Int64(sender.port)
        let serviceType = sender.type.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let scheme = serviceType.contains("ipps") ? "ipps" : "ipp"
        var rp = "ipp/print"
        if let txtData = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txtData)
            if let rpData = dict["rp"], let rpStr = String(data: rpData, encoding: .utf8) {
                rp = rpStr.hasPrefix("/") ? String(rpStr.dropFirst()) : rpStr
            }
        }
        let uri = "\(scheme)://\(host):\(port)/\(rp)"
        let discovered = DiscoveredPrinter(id: uri, name: sender.name, host: host,
                                            port: port, serviceType: serviceType, uri: uri, isAvailable: true)
        // Add to repository (dedup by id)
        let info = PrinterInfo(id: uri, name: sender.name, address: host,
                               isDefault: false, isAvailable: true)
        _repoLock.lock()
        if !_printerRepository.contains(where: { $0.id == uri }) {
            _printerRepository.append(info)
        }
        _repoLock.unlock()
        _onPrinterDiscovered.send(discovered)
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
                                    port: NWEndpoint.Port(rawValue: UInt16(port)) ?? NWEndpoint.Port(integerLiteral: 631),
                                    using: .tcp)
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

    public func setDefaultPrinter(printerId: String) async throws -> Bool { return false }

    // MARK: - Platform UX

    public func openSystemPrintQueue(printerId: String) async throws -> Bool { return false }
    public func openPrinterProperties(printerId: String) async throws -> Bool { return false }

    // MARK: - Private helpers

    private func printHtml(html: String, settings: PrintSettings?) async throws -> PrintResult {
        // Direct dispatch: render the markup to PDF and send it over the
        // network transport — parity with printText/printPdf/printImage.
        if settings?.showPrintDialog == false {
            return try await directPrint(data: renderHtmlToPdfData(html: html, settings: settings),
                                          mimeType: "application/pdf", settings: settings)
        }
        guard UIPrintInteractionController.isPrintingAvailable else { return unavailableResult() }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                let c = UIPrintInteractionController.shared
                self.prepareController(c, settings: settings, outputType: .general)
                c.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
                self.dispatchPrint(c, settings: settings, cont: cont)
            }
        }
    }

    private func prepareController(_ c: UIPrintInteractionController, settings: PrintSettings?,
                                    outputType: UIPrintInfo.OutputType) {
        c.printFormatter = nil; c.printPageRenderer = nil
        c.printingItem = nil; c.printingItems = nil
        c.delegate = self
        c.printInfo = buildPrintInfo(settings, outputType: outputType)
        pendingPaperSize = settings?.paperSize ?? .a4
        pendingCustomSize = paperSizeToCGSize(pendingPaperSize, settings: settings)
    }

    private func dispatchPrint(_ c: UIPrintInteractionController, settings: PrintSettings?,
                                 completion: @escaping (UIPrintInteractionController, Bool, Error?) -> Void) {
        if settings?.showPrintDialog == false,
           let idStr = settings?.printerId, !idStr.isEmpty,
           let url = URL(string: idStr) {
            c.print(to: UIPrinter(url: url), completionHandler: completion)
        } else {
            c.present(animated: true, completionHandler: completion)
        }
    }

    private func dispatchPrint(_ c: UIPrintInteractionController, settings: PrintSettings?,
                                 cont: CheckedContinuation<PrintResult, Error>) {
        let jobId = UUID().uuidString
        _onPrintJobChanged.send(PrintJobUpdate(jobId: jobId, state: .idle, progress: 0, message: ""))
        dispatchPrint(c, settings: settings) { [weak self] _, completed, error in
            guard let self else { cont.resume(returning: .init(success: false, jobId: "", errorMessage: "Deallocated", errorCode: "INTERNAL")); return }
            cont.resume(returning: self.makeResult(completed: completed, error: error))
        }
    }

    // Direct print (no dialog) via raw socket or IPP
    private func directPrint(data: Data, mimeType: String, settings: PrintSettings?) async throws -> PrintResult {
        guard let uri = settings?.printerId, !uri.isEmpty else {
            return PrintResult(success: false, jobId: "",
                               errorMessage: "printerId required for direct print (e.g. ipp://host/ipp/print or socket://host:9100)",
                               errorCode: "NO_PRINTER")
        }
        let copies = Int(max(1, settings?.copies ?? 1))
        let pagesPerSheet = Int(max(1, settings?.pagesPerSheet ?? 1))
        let timeout = TimeInterval(max(5, settings?.networkTimeoutSeconds ?? 30))
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                if uri.hasPrefix("ipp://") || uri.hasPrefix("ipps://") {
                    cont.resume(returning: self.ippPrint(uri: uri, data: data, mimeType: mimeType,
                                                          jobName: settings?.jobName ?? "Document",
                                                          copies: copies, pagesPerSheet: pagesPerSheet,
                                                          timeout: timeout))
                } else {
                    cont.resume(returning: self.socketPrint(uri: uri, data: data, copies: copies, timeout: timeout))
                }
            }
        }
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

    private func ippPrint(uri: String, data: Data, mimeType: String, jobName: String, copies: Int, pagesPerSheet: Int = 1, timeout: TimeInterval = 30) -> PrintResult {
        let httpUrl = uri.replacingOccurrences(of: "ipp://", with: "http://")
                        .replacingOccurrences(of: "ipps://", with: "https://")
        guard let url = URL(string: httpUrl) else {
            return PrintResult(success: false, jobId: "", errorMessage: "Invalid IPP URI", errorCode: "INVALID_URI")
        }
        let ippRequest = buildIppPrintJobRequest(printerUri: uri, jobName: jobName,
                                                   mimeType: mimeType, copies: copies,
                                                   pagesPerSheet: pagesPerSheet, data: data)
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

    // Raw-print socket helper — tracks active stream for cancelRawPrint()
    private func rawSocketPrint(uri: String, data: Data, copies: Int, timeout: TimeInterval) -> PrintResult {
        return performNWConnectionPrint(uri: uri, data: data, copies: copies, timeout: timeout)
    }

    // Raw-print IPP helper — tracks active URLSessionDataTask for cancelRawPrint()
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

    private func buildIppPrintJobRequest(printerUri: String, jobName: String,
                                          mimeType: String, copies: Int, pagesPerSheet: Int = 1, data: Data) -> Data {
        var buf = Data()
        func w2(_ v: Int) { buf.append(UInt8((v >> 8) & 0xFF)); buf.append(UInt8(v & 0xFF)) }
        func w4(_ v: Int) { w2((v >> 16) & 0xFFFF); w2(v & 0xFFFF) }
        func attr(_ tag: Int, _ name: String, _ value: Data) {
            buf.append(UInt8(tag)); w2(name.utf8.count); buf.append(name.data(using: .utf8)!)
            w2(value.count); buf.append(value)
        }
        func strAttr(_ tag: Int, _ name: String, _ value: String) { attr(tag, name, value.data(using: .utf8)!) }
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

    private func buildPrintInfo(_ settings: PrintSettings?, outputType: UIPrintInfo.OutputType) -> UIPrintInfo {
        let info = UIPrintInfo.printInfo()
        info.outputType = outputType
        guard let s = settings else { return info }
        info.jobName = s.jobName.isEmpty ? "Document" : s.jobName
        info.duplex = s.duplex ? .longEdge : .none
        let deg = s.orientationDegrees.truncatingRemainder(dividingBy: 360)
        info.orientation = (deg == 90 || deg == 270 || deg == -90 || deg == -270) ? .landscape : .portrait
        if !s.printerId.isEmpty { info.printerID = s.printerId }
        return info
    }

    private func makeImageRenderer(image: UIImage, settings: PrintSettings?) -> UIPrintPageRenderer {
        let paperPts = paperSizeToCGSize(settings?.paperSize ?? .a4, settings: settings)
        let deg = settings?.orientationDegrees ?? 0.0
        let norm = deg.truncatingRemainder(dividingBy: 360)
        let isLandscape = norm == 90 || norm == 270 || norm == -90 || norm == -270
        let pageSize = isLandscape ? CGSize(width: paperPts.height, height: paperPts.width) : paperPts
        let copies = Int(max(1, settings?.copies ?? 1))
        let pps = Int(max(1, settings?.pagesPerSheet ?? 1))
        return _ImagePageRenderer(image: image, pageSize: pageSize, copies: copies, pagesPerSheet: pps)
    }

    private func paperSizeToCGSize(_ size: PaperSize, settings: PrintSettings? = nil) -> CGSize {
        switch size {
        case .a4:     return CGSize(width: 595.28, height: 841.89)
        case .a5:     return CGSize(width: 419.53, height: 595.28)
        case .letter: return CGSize(width: 612.00, height: 792.00)
        case .legal:  return CGSize(width: 612.00, height: 1008.00)
        case .custom:
            let w = settings?.customPaperWidth ?? 0
            let h = settings?.customPaperHeight ?? 0
            return CGSize(width: w > 0 ? w : 595.28, height: h > 0 ? h : 841.89)
        }
    }

    private func renderTextToPdfData(text: String, settings: PrintSettings?) -> Data {
        let paperPts = paperSizeToCGSize(settings?.paperSize ?? .a4, settings: settings)
        // Apply orientationDegrees the same way makeImageRenderer does —
        // landscape swaps the page dimensions (parity with Android's
        // pageDimensions()).
        let deg = (settings?.orientationDegrees ?? 0.0).truncatingRemainder(dividingBy: 360)
        let isLandscape = deg == 90 || deg == 270 || deg == -90 || deg == -270
        let pageSize = isLandscape ? CGSize(width: paperPts.height, height: paperPts.width) : paperPts
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let margin: CGFloat = 50
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        return renderer.pdfData { ctx in
            let lines = text.components(separatedBy: "\n")
            let lineH: CGFloat = 18
            let drawH = pageRect.height - margin * 2
            let linesPerPage = max(1, Int(drawH / lineH))
            let pages = max(1, (lines.count + linesPerPage - 1) / linesPerPage)
            for p in 0..<pages {
                ctx.beginPage()
                let start = p * linesPerPage
                var y = margin
                for i in start..<min(start + linesPerPage, lines.count) {
                    lines[i].draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
                    y += lineH
                }
            }
        }
    }

    private func renderHtmlToPdfData(html: String, settings: PrintSettings?) -> Data {
        let paperPts = paperSizeToCGSize(settings?.paperSize ?? .a4, settings: settings)
        let deg = (settings?.orientationDegrees ?? 0.0).truncatingRemainder(dividingBy: 360)
        let isLandscape = deg == 90 || deg == 270 || deg == -90 || deg == -270
        let pageSize = isLandscape ? CGSize(width: paperPts.height, height: paperPts.width) : paperPts
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let margin: CGFloat = 50
        let printable = pageRect.insetBy(dx: margin, dy: margin)

        // UIMarkupTextPrintFormatter paginates the HTML; a UIPrintPageRenderer
        // draws each page into a PDF graphics context.
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: pageRect), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, pageRect, nil)
        let pageCount = max(1, renderer.numberOfPages)
        for i in 0..<pageCount {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: pageRect)
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    private func renderImageToPdfData(image: UIImage, settings: PrintSettings?) -> Data? {
        let pageSize = paperSizeToCGSize(settings?.paperSize ?? .a4, settings: settings)
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let margin: CGFloat = 50
            let drawRect = pageRect.insetBy(dx: margin, dy: margin)
            let scale = min(drawRect.width / image.size.width, drawRect.height / image.size.height)
            let w = image.size.width * scale, h = image.size.height * scale
            image.draw(in: CGRect(x: drawRect.minX + (drawRect.width - w) / 2,
                                   y: drawRect.minY + (drawRect.height - h) / 2,
                                   width: w, height: h))
        }
    }

    private func makeResult(completed: Bool, error: Error?) -> PrintResult {
        let jobId = UUID().uuidString
        if let err = error {
            _onPrintJobChanged.send(PrintJobUpdate(jobId: jobId, state: .failed, progress: 0, message: err.localizedDescription))
            return PrintResult(success: false, jobId: "", errorMessage: err.localizedDescription, errorCode: "PRINT_ERROR")
        }
        let state: PrintState = completed ? .completed : .cancelled
        _onPrintJobChanged.send(PrintJobUpdate(jobId: jobId, state: state, progress: completed ? 100 : 0, message: completed ? "" : "Print was cancelled"))
        return PrintResult(success: completed, jobId: completed ? jobId : "",
                           errorMessage: completed ? "" : "Print was cancelled",
                           errorCode: completed ? "" : "CANCELLED")
    }

    private func unavailableResult() -> PrintResult {
        return PrintResult(success: false, jobId: "", errorMessage: "Printing not available", errorCode: "UNAVAILABLE")
    }

    private func parseHostPort(_ uri: String) -> (String, Int) {
        let stripped = uri
            .replacingOccurrences(of: "ipp://", with: "")
            .replacingOccurrences(of: "ipps://", with: "")
            .replacingOccurrences(of: "socket://", with: "")
        let hostPart = stripped.components(separatedBy: "/").first ?? stripped
        if let colon = hostPart.lastIndex(of: ":") {
            let host = String(hostPart[..<colon])
            let portStr = String(hostPart[hostPart.index(after: colon)...])
            return (host, Int(portStr) ?? 631)
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
            return PrintResult(success: false, jobId: "",
                               errorMessage: "printerId required for ZPL (e.g. socket://192.168.1.100:9100)",
                               errorCode: "NO_PRINTER")
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
        // Socket / plain IP: TCP probe using NWConnection for proper reachability check
        let (host, port) = parseSocketAddr(printerId)
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(clamping: port))
        let online: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let probeQ = DispatchQueue(label: "nitro.tcp.probe")
            let connection = NWConnection(
                to: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
                using: .tcp)
            var resumed = false
            let deadline = DispatchTime.now() + timeout
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume(returning: true); connection.cancel() }
                case .failed, .cancelled:
                    if !resumed { resumed = true; cont.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: probeQ)
            probeQ.asyncAfter(deadline: deadline) {
                if !resumed { resumed = true; cont.resume(returning: false); connection.cancel() }
            }
        }
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
        func keyAttr(_ name: String, _ value: String) { strAttr(0x44, name, value) }
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
        var idx = 8 // skip version(2) + status(2) + requestId(4)
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
            if tag == 0x03 { break }  // end-of-attributes
            if tag <= 0x0F { continue } // group delimiter
            let nameLen = read2()
            let attrName = readStr(nameLen)
            let valLen = read2()
            let valStart = idx
            if tag == 0x23 || tag == 0x21 { // enum or integer
                let v = read4()
                if attrName == "printer-state" {
                    printerState = v == 3 ? "idle" : v == 4 ? "processing" : "stopped"
                } else if attrName == "queued-job-count" {
                    queuedJobs = Int64(v)
                } else if attrName == "marker-levels" || attrName.isEmpty {
                    markerLevels.append(v)
                }
            } else if tag == 0x22 { // boolean
                let v = idx < data.count ? data[idx] != 0 : false; idx += valLen
                if attrName == "printer-is-accepting-jobs" { isAccepting = v }
                else if attrName == "color-supported" { supportsColor = v }
            } else if tag == 0x44 || tag == 0x41 || tag == 0x47 || tag == 0x48 || tag == 0x49 { // keyword/octetString/text
                let v = readStr(valLen)
                if attrName == "printer-state-reasons" || attrName.isEmpty { stateReasons.append(v) }
                else if attrName == "printer-state-message" { stateMessage = v }
                else if attrName == "marker-types" || attrName.isEmpty { markerTypes.append(v) }
                else if attrName == "sides-supported" && v.contains("two-sided") { supportsDuplex = true }
                idx = valStart + valLen
            } else {
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
                                    printerState: printerState,
                                    stateReasons: reasons,
                                    statusMessage: stateMessage,
                                    errorCode: "",
                                    isDuplexSupported: supportsDuplex, isColorSupported: supportsColor)
    }
}

// MARK: - Image page renderer (supports copies + N-up)

private final class _ImagePageRenderer: UIPrintPageRenderer {
    private let image: UIImage
    private let pageSize: CGSize
    private let copies: Int
    private let pagesPerSheet: Int

    init(image: UIImage, pageSize: CGSize, copies: Int = 1, pagesPerSheet: Int = 1) {
        self.image = image; self.pageSize = pageSize
        self.copies = max(1, copies); self.pagesPerSheet = max(1, pagesPerSheet)
        super.init()
    }

    override var numberOfPages: Int { copies }

    override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        if pagesPerSheet == 1 {
            let scale = min(printableRect.width / image.size.width, printableRect.height / image.size.height)
            let dw = image.size.width * scale, dh = image.size.height * scale
            image.draw(in: CGRect(x: printableRect.midX - dw / 2, y: printableRect.midY - dh / 2,
                                   width: dw, height: dh))
        } else {
            let cols = pagesPerSheet <= 2 ? pagesPerSheet : 2
            let rows = (pagesPerSheet + cols - 1) / cols
            let cellW = printableRect.width / CGFloat(cols)
            let cellH = printableRect.height / CGFloat(rows)
            for slot in 0..<pagesPerSheet {
                let col = slot % cols, row = slot / cols
                let cellRect = CGRect(x: printableRect.minX + CGFloat(col) * cellW,
                                      y: printableRect.minY + CGFloat(row) * cellH,
                                      width: cellW, height: cellH)
                let scale = min(cellRect.width / image.size.width, cellRect.height / image.size.height)
                let dw = image.size.width * scale, dh = image.size.height * scale
                image.draw(in: CGRect(x: cellRect.midX - dw / 2, y: cellRect.midY - dh / 2,
                                       width: dw, height: dh))
            }
        }
    }
}

// MARK: - PDF page renderer (supports copies + N-up)

private final class _PDFPrintPageRenderer: UIPrintPageRenderer {
    private let document: PDFDocument
    private let copies: Int
    private let pagesPerSheet: Int

    init(document: PDFDocument, copies: Int, pagesPerSheet: Int) {
        self.document = document
        self.copies = max(1, copies)
        self.pagesPerSheet = max(1, pagesPerSheet)
        super.init()
    }

    override var numberOfPages: Int {
        let sheetsPerCopy = (document.pageCount + pagesPerSheet - 1) / pagesPerSheet
        return sheetsPerCopy * copies
    }

    override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        let sheetsPerCopy = (document.pageCount + pagesPerSheet - 1) / pagesPerSheet
        let sheetInCopy = pageIndex % sheetsPerCopy
        let firstSrcIdx = sheetInCopy * pagesPerSheet
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        if pagesPerSheet == 1 {
            guard firstSrcIdx < document.pageCount, let page = document.page(at: firstSrcIdx) else { return }
            _drawPdfPage(page, in: printableRect, context: ctx)
        } else {
            let cols = pagesPerSheet <= 2 ? pagesPerSheet : 2
            let rows = (pagesPerSheet + cols - 1) / cols
            let cellW = printableRect.width / CGFloat(cols)
            let cellH = printableRect.height / CGFloat(rows)
            for slot in 0..<pagesPerSheet {
                let srcIdx = firstSrcIdx + slot
                guard srcIdx < document.pageCount, let page = document.page(at: srcIdx) else { continue }
                let col = slot % cols, row = slot / cols
                let cellRect = CGRect(x: printableRect.minX + CGFloat(col) * cellW,
                                      y: printableRect.minY + CGFloat(row) * cellH,
                                      width: cellW, height: cellH)
                _drawPdfPage(page, in: cellRect, context: ctx)
            }
        }
    }

    private func _drawPdfPage(_ page: PDFPage, in rect: CGRect, context ctx: CGContext) {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let drawW = bounds.width * scale, drawH = bounds.height * scale
        let x = rect.minX + (rect.width - drawW) / 2
        let y = rect.minY + (rect.height - drawH) / 2
        ctx.saveGState()
        ctx.translateBy(x: x, y: y + drawH)
        ctx.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
    }
}
