package dev.shreeman.nitro_printing

import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.graphics.pdf.PdfRenderer
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.provider.Settings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.withContext
import nitro.nitro_printing_module.DiscoveredPrinter
import nitro.nitro_printing_module.DocumentType
import nitro.nitro_printing_module.HybridNitroPrintingSpec
import nitro.nitro_printing_module.MediaType
import nitro.nitro_printing_module.PaperSize
import nitro.nitro_printing_module.PreviewResult
import nitro.nitro_printing_module.PrintDocument
import nitro.nitro_printing_module.PrintJob
import nitro.nitro_printing_module.PrintJobUpdate
import nitro.nitro_printing_module.PrintQuality
import nitro.nitro_printing_module.PrintResult
import nitro.nitro_printing_module.PrintSettings
import nitro.nitro_printing_module.PrintState
import nitro.nitro_printing_module.PrinterCapabilities
import nitro.nitro_printing_module.PrinterInfo
import nitro.nitro_printing_module.PrinterStatus
import nitro.nitro_printing_module.PrintDialogResult
import nitro.nitro_printing_module.PrintDialogState
import nitro.nitro_printing_module.PrinterStatusDetail
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.util.UUID

class NitroPrintingImpl : HybridNitroPrintingSpec {

    // MARK: - Streams

    private val _onPrintJobChanged     = MutableSharedFlow<PrintJobUpdate>(extraBufferCapacity = 16)
    private val _onPrinterStatusChanged = MutableSharedFlow<PrinterStatus>(extraBufferCapacity = 16)
    private val _onPrinterDiscovered   = MutableSharedFlow<DiscoveredPrinter>(extraBufferCapacity = 64)

    override val onPrintJobChanged: Flow<PrintJobUpdate>     = _onPrintJobChanged
    override val onPrinterStatusChanged: Flow<PrinterStatus> = _onPrinterStatusChanged
    override val onPrinterDiscovered: Flow<DiscoveredPrinter> = _onPrinterDiscovered

    // Printer repository — populated by NSD discovery, read by sync quick-lookup methods.
    // CopyOnWriteArrayList gives safe concurrent reads with no locking on the Flutter thread.
    private val _printerRepository = java.util.concurrent.CopyOnWriteArrayList<PrinterInfo>()

    // MARK: - Raw print cancellation state
    @Volatile private var _rawSocket: Socket? = null
    @Volatile private var _rawConn: HttpURLConnection? = null
    @Volatile private var _rawCancelled = false

    // MARK: - Discovery state

    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    // MARK: - PrintManager accessor

    private val printManager: PrintManager
        get() {
            val context = activity ?: applicationContext
            return context.getSystemService(android.content.Context.PRINT_SERVICE) as PrintManager
        }

    // MARK: - Synchronous quick-lookup (no Isolate overhead)

    override fun isPrintingSupported(): Boolean = true

    override fun getPrintersCount(): Long = _printerRepository.size.toLong()
    override suspend fun getAllPrinters(): List<PrinterInfo> = _printerRepository.toList()

    override suspend fun getPrinterAt(index: Long): PrinterInfo {
        val repo = _printerRepository
        if (index < 0 || index >= repo.size)
            throw IndexOutOfBoundsException("Index $index out of range (count: ${repo.size})")
        return repo[index.toInt()]
    }

    override suspend fun getDefaultPrinter(): PrinterInfo =
        _printerRepository.firstOrNull { it.isDefault }
            ?: PrinterInfo(id = "", name = "System Default", address = "", isDefault = true, isAvailable = true)

    override fun getPrinterDriverVersion(printerId: String): String = ""

    override suspend fun getPrinterCapabilities(printerId: String): PrinterCapabilities {
        if (_printerRepository.none { it.id == printerId })
            throw NoSuchElementException("Printer '$printerId' not found")
        return PrinterCapabilities(
            supportsColor = true, supportsDuplex = false, supportsCopy = true,
            maxCopies = 99L, minMarginTop = 0.0, minMarginBottom = 0.0,
            minMarginLeft = 0.0, minMarginRight = 0.0,
            supportsA4 = true, supportsA5 = true, supportsLetter = true, supportsLegal = true,
            supportsDraftQuality = true, supportsNormalQuality = true,
            supportsHighQuality = true, supportsBestQuality = true,
            maxResolutionDpi = 600L, supportsCustomPaper = false,
            supportsBorderless = false, inputTrays = ""
        )
    }

    // MARK: - Print methods

    private fun emitJobUpdate(jobId: String, state: PrintState, progress: Long = 0, message: String = "") {
        _onPrintJobChanged.tryEmit(PrintJobUpdate(jobId = jobId, state = state, progress = progress, message = message))
    }

    override suspend fun printText(text: String, settings: PrintSettings?): PrintResult {
        if (settings?.showPrintDialog == false) {
            return directPrint(textToPdf(text, settings), "application/pdf", settings)
        }
        val jobName = settings?.jobName?.takeIf { it.isNotEmpty() } ?: "Document"
        val jobId = UUID.randomUUID().toString()
        return try {
            emitJobUpdate(jobId, PrintState.IDLE)
            printManager.print(jobName, textAdapter(jobName, text, settings), buildAttributes(settings))
            emitJobUpdate(jobId, PrintState.PRINTING, 50)
            PrintResult(success = true, jobId = jobId, errorMessage = "", errorCode = "")
        } catch (e: Exception) {
            emitJobUpdate(jobId, PrintState.FAILED, 0, e.message ?: "Unknown error")
            PrintResult(success = false, jobId = "", errorMessage = e.message ?: "Unknown error", errorCode = "PRINT_FAILED")
        }
    }

    override suspend fun printImage(imageData: ByteArray, settings: PrintSettings?): PrintResult {
        val bitmap = BitmapFactory.decodeByteArray(imageData, 0, imageData.size)
            ?: return PrintResult(success = false, jobId = "", errorMessage = "Failed to decode image", errorCode = "INVALID_IMAGE")

        if (settings?.showPrintDialog == false) {
            return directPrint(bitmapToPdf(bitmap, settings), "application/pdf", settings)
        }

        val jobName = settings?.jobName?.takeIf { it.isNotEmpty() } ?: "Image"
        val jobId = UUID.randomUUID().toString()
        val pagesPerSheet = settings?.pagesPerSheet?.toInt()?.coerceAtLeast(1) ?: 1
        val copies = settings?.copies?.toInt()?.coerceAtLeast(1) ?: 1
        val isLandscape = isLandscapeDeg(settings?.orientationDegrees ?: 0.0)
        return try {
            val adapter = object : PrintDocumentAdapter() {
                override fun onLayout(old: PrintAttributes?, new: PrintAttributes?, cancel: CancellationSignal?, cb: LayoutResultCallback?, extras: Bundle?) {
                    if (cancel?.isCanceled == true) { cb?.onLayoutCancelled(); return }
                    cb?.onLayoutFinished(
                        PrintDocumentInfo.Builder(jobName)
                            .setContentType(PrintDocumentInfo.CONTENT_TYPE_PHOTO)
                            .setPageCount(copies)
                            .build(), old != new
                    )
                }
                override fun onWrite(pages: Array<out PageRange>?, dest: ParcelFileDescriptor?, cancel: CancellationSignal?, cb: WriteResultCallback?) {
                    if (cancel?.isCanceled == true) { cb?.onWriteCancelled(); return }
                    try {
                        val doc = PdfDocument()
                        val (pgW, pgH) = pageDimensions(settings, isLandscape)
                        for (copyIdx in 1..copies) {
                            val pg = doc.startPage(PdfDocument.PageInfo.Builder(pgW, pgH, copyIdx).create())
                            drawBitmapNUp(pg.canvas, bitmap, pagesPerSheet, pgW, pgH)
                            doc.finishPage(pg)
                        }
                        dest?.let { doc.writeTo(java.io.FileOutputStream(it.fileDescriptor)) }
                        doc.close()
                        cb?.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
                    } catch (e: IOException) { cb?.onWriteFailed(e.message) }
                }
            }
            printManager.print(jobName, adapter, buildAttributes(settings))
            PrintResult(success = true, jobId = jobId, errorMessage = "", errorCode = "")
        } catch (e: Exception) {
            PrintResult(success = false, jobId = "", errorMessage = e.message ?: "Unknown error", errorCode = "PRINT_FAILED")
        }
    }

    override suspend fun printPdf(pdfData: ByteArray, settings: PrintSettings?): PrintResult {
        if (settings?.showPrintDialog == false) {
            return directPrint(pdfData, "application/pdf", settings)
        }
        val jobName = settings?.jobName?.takeIf { it.isNotEmpty() } ?: "PDF Document"
        val jobId = UUID.randomUUID().toString()
        val pdfCopies = settings?.copies?.toInt()?.coerceAtLeast(1) ?: 1
        val pdfPps = settings?.pagesPerSheet?.toInt()?.coerceAtLeast(1) ?: 1
        val pdfLandscape = isLandscapeDeg(settings?.orientationDegrees ?: 0.0)
        return try {
            val adapter = object : PrintDocumentAdapter() {
                override fun onLayout(old: PrintAttributes?, new: PrintAttributes?, cancel: CancellationSignal?, cb: LayoutResultCallback?, extras: Bundle?) {
                    if (cancel?.isCanceled == true) { cb?.onLayoutCancelled(); return }
                    cb?.onLayoutFinished(
                        PrintDocumentInfo.Builder(jobName)
                            .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                            .setPageCount(PrintDocumentInfo.PAGE_COUNT_UNKNOWN)
                            .build(), old != new
                    )
                }
                override fun onWrite(pages: Array<out PageRange>?, dest: ParcelFileDescriptor?, cancel: CancellationSignal?, cb: WriteResultCallback?) {
                    if (cancel?.isCanceled == true) { cb?.onWriteCancelled(); return }
                    if (pdfCopies == 1 && pdfPps == 1) {
                        try {
                            dest?.let { java.io.FileOutputStream(it.fileDescriptor).use { out -> out.write(pdfData) } }
                            cb?.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
                        } catch (e: IOException) { cb?.onWriteFailed(e.message) }
                        return
                    }
                    val tmp = java.io.File.createTempFile("nitro_src", ".pdf")
                    try {
                        tmp.writeBytes(pdfData)
                        val pfd = ParcelFileDescriptor.open(tmp, ParcelFileDescriptor.MODE_READ_ONLY)
                        val renderer = PdfRenderer(pfd)
                        val doc = PdfDocument()
                        val (pgW, pgH) = pageDimensions(settings, pdfLandscape)
                        val srcCount = renderer.pageCount
                        val sheetsPerCopy = (srcCount + pdfPps - 1) / pdfPps
                        val cols = if (pdfPps <= 2) pdfPps else 2
                        val rows = (pdfPps + cols - 1) / cols
                        val cellW = pgW / cols; val cellH = pgH / rows
                        var pageNum = 0
                        repeat(pdfCopies) {
                            repeat(sheetsPerCopy) { sheetIdx ->
                                pageNum++
                                val pg = doc.startPage(PdfDocument.PageInfo.Builder(pgW, pgH, pageNum).create())
                                pg.canvas.drawColor(android.graphics.Color.WHITE)
                                for (slot in 0 until pdfPps) {
                                    val srcIdx = sheetIdx * pdfPps + slot
                                    if (srcIdx >= srcCount) break
                                    val srcPage = renderer.openPage(srcIdx)
                                    val bmp = android.graphics.Bitmap.createBitmap(cellW, cellH, android.graphics.Bitmap.Config.ARGB_8888)
                                    bmp.eraseColor(android.graphics.Color.WHITE)
                                    srcPage.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                                    srcPage.close()
                                    val col = slot % cols; val row = slot / cols
                                    val m = android.graphics.Matrix()
                                    m.postTranslate((col * cellW).toFloat(), (row * cellH).toFloat())
                                    pg.canvas.drawBitmap(bmp, m, android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG))
                                    bmp.recycle()
                                }
                                doc.finishPage(pg)
                            }
                        }
                        renderer.close(); pfd.close()
                        dest?.let { doc.writeTo(java.io.FileOutputStream(it.fileDescriptor)) }
                        doc.close()
                        cb?.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
                    } catch (e: IOException) { cb?.onWriteFailed(e.message) }
                    finally { tmp.delete() }
                }
            }
            printManager.print(jobName, adapter, buildAttributes(settings))
            PrintResult(success = true, jobId = jobId, errorMessage = "", errorCode = "")
        } catch (e: Exception) {
            PrintResult(success = false, jobId = "", errorMessage = e.message ?: "Unknown error", errorCode = "PRINT_FAILED")
        }
    }

    override suspend fun printDocument(document: PrintDocument, settings: PrintSettings?): PrintResult =
        when (document.type) {
            DocumentType.PLAINTEXT ->
                printText(String(document.data, Charsets.UTF_8), settings)
            DocumentType.HTML -> {
                val plain = android.text.Html.fromHtml(
                    String(document.data, Charsets.UTF_8), android.text.Html.FROM_HTML_MODE_LEGACY
                ).toString()
                printText(plain, settings)
            }
            DocumentType.PDF   -> printPdf(document.data, settings)
            DocumentType.IMAGE -> printImage(document.data, settings)
        }

    @Suppress("UNCHECKED_CAST")
    override suspend fun printBatch(
        documents: Any?,
        stopOnError: Boolean,
        settings: PrintSettings?
    ): List<PrintResult> {
        val docs = documents as? List<PrintDocument> ?: emptyList()
        val results = mutableListOf<PrintResult>()
        for (doc in docs) {
            val result = printDocument(doc, settings)
            results.add(result)
            if (stopOnError && !result.success) break
        }
        return results
    }

    override suspend fun showPrintDialog(
        document: PrintDocument,
        initialSettings: PrintSettings?
    ): PrintDialogResult {
        val confirmedSettings = initialSettings ?: PrintSettings(
            printerId = "", paperSize = PaperSize.A4, orientationDegrees = 0.0,
            quality = PrintQuality.NORMAL, copies = 1, collate = false, duplex = false,
            color = true, marginTop = 0.0, marginBottom = 0.0, marginLeft = 0.0, marginRight = 0.0,
            jobName = "", pagesPerSheet = 1, showPrintDialog = true,
            pageRangeFrom = 0, pageRangeTo = 0, customPaperWidth = 0.0, customPaperHeight = 0.0,
            fitToPage = false, mediaType = MediaType.PLAIN,
            headerText = "", footerText = "", inputTray = "", networkTimeoutSeconds = 30,
        )
        // Android doesn't have a synchronous system print dialog that returns a result.
        // We open the print activity and immediately return a confirmed=false result
        // since we can't block waiting for user interaction on Android.
        return PrintDialogResult(
            confirmed = false,
            confirmedSettings = confirmedSettings,
            errorMessage = "Android print dialogs are non-blocking. Use printDocument() with showPrintDialog=true instead.",
        )
    }

    override suspend fun printFile(filePath: String, settings: PrintSettings?): Boolean {
        val file = java.io.File(filePath)
        if (!file.exists()) return false
        val data = file.readBytes()
        val ext = file.extension.lowercase()
        return when {
            ext == "pdf" -> printPdf(data, settings).success
            ext in setOf("jpg", "jpeg", "png", "gif", "bmp", "webp") -> printImage(data, settings).success
            else -> printText(String(data, Charsets.UTF_8), settings).success
        }
    }

    // MARK: - Export / Virtual print

    override suspend fun renderPreview(document: PrintDocument, settings: PrintSettings?): PreviewResult {
        val pdf = documentToPdf(document, settings)
        val direct = java.nio.ByteBuffer.allocateDirect(pdf.size).put(pdf).also { it.flip() }
        return PreviewResult(bytes = direct, length = pdf.size.toLong())
    }

    override suspend fun getPageCount(document: PrintDocument): Long {
        if (document.type != DocumentType.PDF) return 1L
        return withContext(Dispatchers.IO) {
            val tmp = java.io.File.createTempFile("nitro_pdf", ".pdf")
            try {
                tmp.writeBytes(document.data)
                ParcelFileDescriptor.open(tmp, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
                    PdfRenderer(pfd).use { renderer -> renderer.pageCount.toLong() }
                }
            } catch (_: Exception) { 1L }
            finally { tmp.delete() }
        }
    }

    override suspend fun printToFile(document: PrintDocument, outputPath: String, settings: PrintSettings?): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val pdf = documentToPdf(document, settings)
                java.io.File(outputPath).writeBytes(pdf)
                true
            } catch (_: Exception) { false }
        }
    }

    // MARK: - Job management

    override suspend fun cancelPrintJob(jobId: String): Boolean {
        val job = printManager.printJobs.firstOrNull { it.id.toString() == jobId } ?: return false
        return try { job.cancel(); true } catch (_: Exception) { false }
    }

    override suspend fun pausePrintJob(jobId: String): Boolean = false

    override suspend fun resumePrintJob(jobId: String): Boolean = false

    override suspend fun clearPrintQueue(): Boolean {
        return try {
            printManager.printJobs.forEach { if (!it.isCompleted) it.cancel() }
            true
        } catch (_: Exception) { false }
    }

    override suspend fun getPrintJobsCount(): Long = printManager.printJobs.size.toLong()

    override suspend fun getPrintJobAt(index: Long): PrintJob {
        val jobs = printManager.printJobs
        if (index < 0 || index >= jobs.size) throw IndexOutOfBoundsException("No print job at index $index")
        return jobs[index.toInt()].toNitroPrintJob()
    }

    override suspend fun getPrintJobStatus(jobId: String): PrintJob {
        return printManager.printJobs.firstOrNull { it.id.toString() == jobId }?.toNitroPrintJob()
            ?: throw NoSuchElementException("No print job with id $jobId")
    }

    // MARK: - Discovery

    override suspend fun startPrinterDiscovery(): Boolean {
        _printerRepository.clear()
        return withContext(Dispatchers.IO) {
            try {
                val ctx = activity ?: applicationContext
                val mgr = ctx.getSystemService(android.content.Context.NSD_SERVICE) as NsdManager
                nsdManager = mgr

                val listener = object : NsdManager.DiscoveryListener {
                    override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
                    override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
                    override fun onDiscoveryStarted(serviceType: String) {}
                    override fun onDiscoveryStopped(serviceType: String) {}

                    override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                        @Suppress("DEPRECATION")
                        mgr.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                            override fun onResolveFailed(si: NsdServiceInfo, errorCode: Int) {}
                            override fun onServiceResolved(si: NsdServiceInfo) {
                                val host = si.host?.hostAddress ?: return
                                val port = si.port.takeIf { it > 0 } ?: 631
                                val name = si.serviceName ?: return
                                val uri = "ipp://$host:$port/ipp/print"
                                // Add to repository (dedup by id)
                                if (_printerRepository.none { it.id == uri }) {
                                    _printerRepository.add(PrinterInfo(
                                        id = uri, name = name, address = host,
                                        isDefault = false, isAvailable = true
                                    ))
                                }
                                val printer = DiscoveredPrinter(
                                    id = uri, name = name, host = host,
                                    port = port.toLong(), serviceType = si.serviceType ?: "_ipp._tcp",
                                    uri = uri, isAvailable = true
                                )
                                _onPrinterDiscovered.tryEmit(printer)
                            }
                        })
                    }

                    override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
                }

                discoveryListener = listener
                mgr.discoverServices("_ipp._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
                true
            } catch (_: Exception) { false }
        }
    }

    override suspend fun stopPrinterDiscovery(): Boolean {
        return try {
            discoveryListener?.let { nsdManager?.stopServiceDiscovery(it) }
            discoveryListener = null
            nsdManager = null
            true
        } catch (_: Exception) { false }
    }

    // MARK: - Connection / admin

    override suspend fun testPrinterConnection(printerId: String, timeoutSeconds: Long?): Boolean {
        val timeoutMs = ((timeoutSeconds?.takeIf { it > 0 } ?: 5L) * 1000L).toInt()
        return withContext(Dispatchers.IO) {
            try {
                val (host, port) = parseSocketAddr(printerId)
                Socket().use { sock ->
                    sock.connect(InetSocketAddress(host, port), timeoutMs)
                    true
                }
            } catch (_: Exception) { false }
        }
    }

    override suspend fun setDefaultPrinter(printerId: String): Boolean = false

    // MARK: - Platform UX

    override suspend fun openSystemPrintQueue(printerId: String): Boolean {
        return try {
            val ctx = activity ?: return false
            ctx.startActivity(Intent(Settings.ACTION_PRINT_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            true
        } catch (_: Exception) { false }
    }

    override suspend fun openPrinterProperties(printerId: String): Boolean = false

    // MARK: - Direct print

    private suspend fun directPrint(data: ByteArray, mimeType: String, settings: PrintSettings?): PrintResult {
        val printerUri = settings?.printerId?.takeIf { it.isNotEmpty() }
            ?: return PrintResult(success = false, jobId = "", errorMessage = "No printer URI for direct print", errorCode = "NO_PRINTER")
        val timeoutS = (settings.networkTimeoutSeconds.takeIf { it > 0 } ?: 30L).toInt()
        val connectMs = minOf(timeoutS * 1000, 15_000)
        val readMs = timeoutS * 1000
        return withContext(Dispatchers.IO) {
            try {
                val copies = settings.copies.toInt().coerceAtLeast(1)
                val pagesPerSheet = settings.pagesPerSheet.toInt().coerceAtLeast(1)
                val jobName = settings.jobName.takeIf { it.isNotEmpty() } ?: "Document"
                when {
                    printerUri.startsWith("ipp://") || printerUri.startsWith("ipps://") ->
                        ippPrint(printerUri, data, mimeType, jobName, copies, pagesPerSheet, connectMs, readMs)
                    else ->
                        socketPrint(printerUri, data, copies, connectMs, readMs)
                }
            } catch (e: Exception) {
                PrintResult(success = false, jobId = "", errorMessage = e.message ?: "Direct print failed", errorCode = "DIRECT_PRINT_FAILED")
            }
        }
    }

    private fun socketPrint(uri: String, data: ByteArray, copies: Int,
                             connectMs: Int = 15_000, soTimeoutMs: Int = 30_000): PrintResult {
        val (host, port) = parseSocketAddr(uri)
        Socket().use { sock ->
            sock.soTimeout = soTimeoutMs
            sock.connect(InetSocketAddress(host, port), connectMs)
            sock.getOutputStream().use { out ->
                repeat(copies) { out.write(data) }
                out.flush()
            }
        }
        return PrintResult(success = true, jobId = UUID.randomUUID().toString(), errorMessage = "", errorCode = "")
    }

    private fun rawSocketPrint(uri: String, data: ByteArray, copies: Int,
                                connectMs: Int, soTimeoutMs: Int): PrintResult {
        val (host, port) = parseSocketAddr(uri)
        _rawCancelled = false
        val sock = Socket()
        _rawSocket = sock
        return try {
            sock.soTimeout = soTimeoutMs
            sock.connect(InetSocketAddress(host, port), connectMs)
            sock.getOutputStream().use { out ->
                repeat(copies) {
                    if (_rawCancelled) throw java.io.IOException("Cancelled")
                    out.write(data)
                }
                out.flush()
            }
            PrintResult(success = true, jobId = UUID.randomUUID().toString(), errorMessage = "", errorCode = "")
        } catch (e: Exception) {
            val code = if (_rawCancelled) "CANCELLED" else "SOCKET_ERROR"
            PrintResult(success = false, jobId = "", errorMessage = e.message ?: "Socket error", errorCode = code)
        } finally {
            _rawSocket = null
            try { sock.close() } catch (_: Exception) {}
        }
    }

    private fun ippPrint(printerUri: String, data: ByteArray, mimeType: String, jobName: String, copies: Int,
                          pagesPerSheet: Int = 1, connectMs: Int = 15_000, readMs: Int = 30_000): PrintResult {
        val httpUrl = printerUri.replaceFirst("ipp://", "http://").replaceFirst("ipps://", "https://")
        val ippRequest = buildIppRequest(printerUri, jobName, mimeType, copies, data, pagesPerSheet)
        val conn = URL(httpUrl).openConnection() as HttpURLConnection
        return try {
            conn.requestMethod = "POST"
            conn.connectTimeout = connectMs; conn.readTimeout = readMs
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/ipp")
            conn.setRequestProperty("Content-Length", ippRequest.size.toString())
            conn.outputStream.use { it.write(ippRequest) }
            val code = conn.responseCode
            if (code in 200..299) PrintResult(success = true, jobId = UUID.randomUUID().toString(), errorMessage = "", errorCode = "")
            else PrintResult(success = false, jobId = "", errorMessage = "IPP HTTP $code", errorCode = "IPP_HTTP_ERROR")
        } finally { conn.disconnect() }
    }

    private fun rawIppPrint(printerUri: String, data: ByteArray, mimeType: String, jobName: String,
                             copies: Int, connectMs: Int, readMs: Int): PrintResult {
        val httpUrl = printerUri.replaceFirst("ipp://", "http://").replaceFirst("ipps://", "https://")
        val ippRequest = buildIppRequest(printerUri, jobName, mimeType, copies, data, 1)
        _rawCancelled = false
        val conn = URL(httpUrl).openConnection() as HttpURLConnection
        _rawConn = conn
        return try {
            conn.requestMethod = "POST"
            conn.connectTimeout = connectMs; conn.readTimeout = readMs
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/ipp")
            conn.outputStream.use { it.write(ippRequest) }
            val code = conn.responseCode
            if (code in 200..299) PrintResult(success = true, jobId = UUID.randomUUID().toString(), errorMessage = "", errorCode = "")
            else PrintResult(success = false, jobId = "", errorMessage = "IPP HTTP $code", errorCode = "IPP_HTTP_ERROR")
        } catch (e: Exception) {
            val code = if (_rawCancelled) "CANCELLED" else "IPP_ERROR"
            PrintResult(success = false, jobId = "", errorMessage = e.message ?: "IPP error", errorCode = code)
        } finally {
            _rawConn = null
            conn.disconnect()
        }
    }

    private fun buildIppRequest(printerUri: String, jobName: String, mimeType: String, copies: Int, data: ByteArray, pagesPerSheet: Int = 1): ByteArray {
        val buf = ByteArrayOutputStream()
        fun w2(v: Int) { buf.write(v ushr 8 and 0xFF); buf.write(v and 0xFF) }
        fun w4(v: Int) { w2(v ushr 16 and 0xFFFF); w2(v and 0xFFFF) }
        fun strAttr(tag: Int, name: String, value: String) {
            buf.write(tag); w2(name.length); buf.write(name.toByteArray()); w2(value.length); buf.write(value.toByteArray())
        }
        fun intAttr(name: String, value: Int) {
            buf.write(0x21); w2(name.length); buf.write(name.toByteArray()); w2(4); w4(value)
        }
        buf.write(1); buf.write(1); w2(0x0002); w4(1)
        buf.write(0x01)
        strAttr(0x47, "attributes-charset", "utf-8")
        strAttr(0x48, "attributes-natural-language", "en")
        strAttr(0x45, "printer-uri", printerUri)
        strAttr(0x42, "job-name", jobName.ifEmpty { "Document" })
        strAttr(0x42, "requesting-user-name", "Flutter")
        strAttr(0x49, "document-format", mimeType)
        buf.write(0x02)
        if (copies > 1) intAttr("copies", copies)
        if (pagesPerSheet > 1) intAttr("number-up", pagesPerSheet)
        buf.write(0x03)
        buf.write(data)
        return buf.toByteArray()
    }

    // MARK: - PDF helpers

    private fun documentToPdf(document: PrintDocument, settings: PrintSettings?): ByteArray =
        when (document.type) {
            DocumentType.PDF   -> document.data
            DocumentType.IMAGE -> {
                val bmp = BitmapFactory.decodeByteArray(document.data, 0, document.data.size)
                if (bmp != null) bitmapToPdf(bmp, settings) else ByteArray(0)
            }
            DocumentType.HTML -> {
                val plain = android.text.Html.fromHtml(
                    String(document.data, Charsets.UTF_8), android.text.Html.FROM_HTML_MODE_LEGACY
                ).toString()
                textToPdf(plain, settings)
            }
            DocumentType.PLAINTEXT -> textToPdf(String(document.data, Charsets.UTF_8), settings)
        }

    private fun textToPdf(text: String, settings: PrintSettings?): ByteArray {
        val isLandscape = isLandscapeDeg(settings?.orientationDegrees ?: 0.0)
        val copies = settings?.copies?.toInt()?.coerceAtLeast(1) ?: 1
        val (pgW, pgH) = pageDimensions(settings, isLandscape)
        val paint = Paint().apply { textSize = 12f; color = Color.BLACK }
        val margin = 50f; val lineHeight = paint.textSize * 1.5f
        val linesPerPage = ((pgH - margin * 2) / lineHeight).toInt().coerceAtLeast(1)
        val lines = text.lines()
        val pagesPerCopy = ((lines.size + linesPerPage - 1) / linesPerPage).coerceAtLeast(1)
        val doc = PdfDocument(); var pageNum = 0
        repeat(copies) {
            repeat(pagesPerCopy) { pageIdx ->
                pageNum++
                val pg = doc.startPage(PdfDocument.PageInfo.Builder(pgW, pgH, pageNum).create())
                var y = margin + paint.textSize
                val startLine = pageIdx * linesPerPage
                for (i in startLine until minOf(startLine + linesPerPage, lines.size)) {
                    pg.canvas.drawText(lines[i], margin, y, paint); y += lineHeight
                }
                doc.finishPage(pg)
            }
        }
        if (settings?.headerText?.isNotEmpty() == true || settings?.footerText?.isNotEmpty() == true) {
            // Headers/footers would require re-rendering pages; omit for simplicity
        }
        val baos = ByteArrayOutputStream(); doc.writeTo(baos); doc.close()
        return baos.toByteArray()
    }

    private fun bitmapToPdf(bitmap: android.graphics.Bitmap, settings: PrintSettings?): ByteArray {
        val isLandscape = isLandscapeDeg(settings?.orientationDegrees ?: 0.0)
        val copies = settings?.copies?.toInt()?.coerceAtLeast(1) ?: 1
        val pagesPerSheet = settings?.pagesPerSheet?.toInt()?.coerceAtLeast(1) ?: 1
        val (pgW, pgH) = pageDimensions(settings, isLandscape)
        val doc = PdfDocument()
        repeat(copies) { idx ->
            val pg = doc.startPage(PdfDocument.PageInfo.Builder(pgW, pgH, idx + 1).create())
            drawBitmapNUp(pg.canvas, bitmap, pagesPerSheet, pgW, pgH)
            doc.finishPage(pg)
        }
        val baos = ByteArrayOutputStream(); doc.writeTo(baos); doc.close()
        return baos.toByteArray()
    }

    // MARK: - Helpers

    private fun isLandscapeDeg(deg: Double): Boolean {
        val norm = ((deg % 360) + 360) % 360
        return norm == 90.0 || norm == 270.0
    }

    private fun pageDimensions(settings: PrintSettings?, isLandscape: Boolean): Pair<Int, Int> {
        val (w, h) = when (settings?.paperSize) {
            PaperSize.A5     -> Pair(420, 595)
            PaperSize.LETTER -> Pair(612, 792)
            PaperSize.LEGAL  -> Pair(612, 1008)
            PaperSize.CUSTOM -> {
                val cw = settings.customPaperWidth.toInt().takeIf { it > 0 } ?: 595
                val ch = settings.customPaperHeight.toInt().takeIf { it > 0 } ?: 842
                Pair(cw, ch)
            }
            else -> Pair(595, 842)
        }
        return if (isLandscape) Pair(h, w) else Pair(w, h)
    }

    private fun drawBitmapNUp(canvas: Canvas, bitmap: android.graphics.Bitmap, n: Int, pgW: Int, pgH: Int) {
        val effectiveN = n.coerceAtLeast(1)
        val cellW = pgW / effectiveN
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        for (i in 0 until effectiveN) {
            val scale = minOf(cellW.toFloat() / bitmap.width, pgH.toFloat() / bitmap.height)
            val drawW = bitmap.width * scale; val drawH = bitmap.height * scale
            val x = i * cellW + (cellW - drawW) / 2f; val y = (pgH - drawH) / 2f
            val m = Matrix(); m.postScale(scale, scale); m.postTranslate(x, y)
            canvas.drawBitmap(bitmap, m, paint)
        }
    }

    private fun textAdapter(jobName: String, text: String, settings: PrintSettings?) = object : PrintDocumentAdapter() {
        val pagesPerSheet = settings?.pagesPerSheet?.toInt()?.coerceAtLeast(1) ?: 1
        val copies = settings?.copies?.toInt()?.coerceAtLeast(1) ?: 1
        val isLandscape = isLandscapeDeg(settings?.orientationDegrees ?: 0.0)

        override fun onLayout(old: PrintAttributes?, new: PrintAttributes?, cancel: CancellationSignal?, cb: LayoutResultCallback?, extras: Bundle?) {
            if (cancel?.isCanceled == true) { cb?.onLayoutCancelled(); return }
            cb?.onLayoutFinished(
                PrintDocumentInfo.Builder(jobName).setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                    .setPageCount(PrintDocumentInfo.PAGE_COUNT_UNKNOWN).build(), old != new
            )
        }

        override fun onWrite(pages: Array<out PageRange>?, dest: ParcelFileDescriptor?, cancel: CancellationSignal?, cb: WriteResultCallback?) {
            if (cancel?.isCanceled == true) { cb?.onWriteCancelled(); return }
            try {
                val (pgW, pgH) = pageDimensions(settings, isLandscape)
                val cellW = if (pagesPerSheet > 1) pgW / pagesPerSheet else pgW
                val doc = PdfDocument()
                val paint = Paint().apply { textSize = 12f; color = Color.BLACK }
                val lines = text.lines(); val margin = 50f; val lineHeight = paint.textSize * 1.5f
                val linesPerCell = ((pgH - margin * 2) / lineHeight).toInt().coerceAtLeast(1)
                val totalVirtualPages = ((lines.size + linesPerCell - 1) / linesPerCell).coerceAtLeast(1)
                val sheets = (totalVirtualPages + pagesPerSheet - 1) / pagesPerSheet
                var pageNum = 0
                repeat(copies) {
                    repeat(sheets) { sheetIdx ->
                        pageNum++
                        val pg = doc.startPage(PdfDocument.PageInfo.Builder(pgW, pgH, pageNum).create())
                        repeat(pagesPerSheet) { slot ->
                            val virtualPage = sheetIdx * pagesPerSheet + slot
                            if (virtualPage < totalVirtualPages) {
                                val offsetX = slot * cellW.toFloat(); var y = margin + paint.textSize
                                val startLine = virtualPage * linesPerCell
                                for (i in startLine until minOf(startLine + linesPerCell, lines.size)) {
                                    pg.canvas.drawText(lines[i], offsetX + margin, y, paint); y += lineHeight
                                }
                            }
                        }
                        doc.finishPage(pg)
                    }
                }
                dest?.let { doc.writeTo(java.io.FileOutputStream(it.fileDescriptor)) }
                doc.close(); cb?.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
            } catch (e: IOException) { cb?.onWriteFailed(e.message) }
        }
    }

    private fun buildAttributes(s: PrintSettings?): PrintAttributes? {
        s ?: return null
        val b = PrintAttributes.Builder()
        val isLandscape = isLandscapeDeg(s.orientationDegrees)
        val mediaSize = when (s.paperSize) {
            PaperSize.A4     -> PrintAttributes.MediaSize.ISO_A4
            PaperSize.A5     -> PrintAttributes.MediaSize.ISO_A5
            PaperSize.LETTER -> PrintAttributes.MediaSize.NA_LETTER
            PaperSize.LEGAL  -> PrintAttributes.MediaSize.NA_LEGAL
            else             -> PrintAttributes.MediaSize.ISO_A4
        }
        b.setMediaSize(if (isLandscape) mediaSize.asLandscape() else mediaSize.asPortrait())
        b.setResolution(when (s.quality) {
            PrintQuality.DRAFT -> PrintAttributes.Resolution("draft", "Draft", 150, 150)
            PrintQuality.HIGH  -> PrintAttributes.Resolution("high",  "High",  600, 600)
            PrintQuality.BEST  -> PrintAttributes.Resolution("best",  "Best",  1200, 1200)
            else               -> PrintAttributes.Resolution("normal", "Normal", 300, 300)
        })
        b.setColorMode(if (s.color) PrintAttributes.COLOR_MODE_COLOR else PrintAttributes.COLOR_MODE_MONOCHROME)
        if (s.duplex) b.setDuplexMode(PrintAttributes.DUPLEX_MODE_LONG_EDGE)
        return b.build()
    }

    private fun parseSocketAddr(uri: String): Pair<String, Int> {
        val stripped = uri.removePrefix("socket://").removePrefix("ipp://").removePrefix("ipps://")
            .substringBefore("/")
        val lastColon = stripped.lastIndexOf(':')
        return if (lastColon > 0)
            Pair(stripped.substring(0, lastColon), stripped.substring(lastColon + 1).toIntOrNull() ?: 9100)
        else Pair(stripped, 9100)
    }

    private fun android.print.PrintJob.toNitroPrintJob() = PrintJob(
        id = id.toString(), printerId = "",
        documentTitle = info?.label?.toString() ?: "",
        state = when {
            isQueued    -> PrintState.IDLE
            isStarted   -> PrintState.PRINTING
            isCompleted -> PrintState.COMPLETED
            isCancelled -> PrintState.CANCELLED
            isFailed    -> PrintState.FAILED
            isBlocked   -> PrintState.PAUSED
            else        -> PrintState.IDLE
        },
        progress = 0L, createdAtMillis = 0L, completedAtMillis = 0L,
        errorMessage = "", pagesPrinted = 0L
    )

    // ── Raw protocol printing ─────────────────────────────────────────────────

    override suspend fun printRaw(data: ByteArray, settings: PrintSettings?): PrintResult {
        val uri = settings?.printerId?.takeIf { it.isNotEmpty() }
            ?: return PrintResult(success = false, jobId = "", errorMessage = "printerId required for raw print", errorCode = "NO_PRINTER")
        val copies = settings.copies.toInt().coerceAtLeast(1)
        val timeoutS = (settings.networkTimeoutSeconds.takeIf { it > 0 } ?: 30L).toInt()
        val connectMs = minOf(timeoutS * 1000, 15_000)
        val readMs = timeoutS * 1000
        return withContext(Dispatchers.IO) {
            try {
                when {
                    uri.startsWith("ipp://") || uri.startsWith("ipps://") ->
                        rawIppPrint(uri, data, "application/octet-stream",
                                    settings.jobName.ifEmpty { "Raw" }, copies, connectMs, readMs)
                    else -> rawSocketPrint(uri, data, copies, connectMs, readMs)
                }
            } catch (e: Exception) {
                PrintResult(success = false, jobId = "", errorMessage = e.message ?: "Raw print failed", errorCode = "RAW_PRINT_FAILED")
            }
        }
    }

    override suspend fun printEscPos(escPosData: ByteArray, settings: PrintSettings?): PrintResult {
        val uri = settings?.printerId?.takeIf { it.isNotEmpty() }
            ?: return PrintResult(success = false, jobId = "", errorMessage = "printerId required for ESC/POS print", errorCode = "NO_PRINTER")
        val copies = settings.copies.toInt().coerceAtLeast(1)
        val timeoutS = (settings.networkTimeoutSeconds.takeIf { it > 0 } ?: 30L).toInt()
        val connectMs = minOf(timeoutS * 1000, 15_000)
        val readMs = timeoutS * 1000
        return withContext(Dispatchers.IO) {
            try {
                when {
                    uri.startsWith("ipp://") || uri.startsWith("ipps://") ->
                        rawIppPrint(uri, escPosData, "application/vnd.epson.esc-p",
                                    settings.jobName.ifEmpty { "Receipt" }, copies, connectMs, readMs)
                    else -> rawSocketPrint(uri, escPosData, copies, connectMs, readMs)
                }
            } catch (e: Exception) {
                PrintResult(success = false, jobId = "", errorMessage = e.message ?: "ESC/POS print failed", errorCode = "ESCPOS_FAILED")
            }
        }
    }

    override suspend fun printZpl(zpl: String, settings: PrintSettings?): PrintResult {
        val data = zpl.toByteArray(Charsets.UTF_8)
        val uri = settings?.printerId?.takeIf { it.isNotEmpty() }
            ?: return PrintResult(success = false, jobId = "", errorMessage = "printerId required for ZPL print", errorCode = "NO_PRINTER")
        val timeoutS = (settings?.networkTimeoutSeconds?.takeIf { it > 0 } ?: 30L).toInt()
        val connectMs = minOf(timeoutS * 1000, 15_000)
        val readMs = timeoutS * 1000
        return withContext(Dispatchers.IO) {
            try {
                when {
                    uri.startsWith("ipp://") || uri.startsWith("ipps://") ->
                        rawIppPrint(uri, data, "application/vnd.zebra-zpl",
                                    settings?.jobName?.ifEmpty { "ZPL Label" } ?: "ZPL Label",
                                    1, connectMs, readMs)
                    else -> rawSocketPrint(uri, data, 1, connectMs, readMs)
                }
            } catch (e: Exception) {
                PrintResult(success = false, jobId = "", errorMessage = e.message ?: "ZPL print failed", errorCode = "ZPL_FAILED")
            }
        }
    }

    override suspend fun cancelRawPrint(): Boolean {
        _rawCancelled = true
        var cancelled = false
        _rawSocket?.let { it.close(); _rawSocket = null; cancelled = true }
        _rawConn?.let { it.disconnect(); _rawConn = null; cancelled = true }
        return cancelled
    }

    // ── Detailed printer status ───────────────────────────────────────────────

    override suspend fun getPrinterStatusDetail(printerId: String, timeoutSeconds: Long?): PrinterStatusDetail {
        val timeoutMs = ((timeoutSeconds?.takeIf { it > 0 } ?: 30L) * 1000L).toInt()
        val offline = PrinterStatusDetail(
            printerId = printerId, isOnline = false, isReady = false,
            hasPaperJam = false, isOutOfPaper = false, isOutOfInk = false,
            inkLevelBlack = -1L, inkLevelCyan = -1L, inkLevelMagenta = -1L,
            inkLevelYellow = -1L, tonerLevel = -1L, paperLevel = -1L,
            jobsInQueue = 0L, isWarmingUp = false,
            printerState = "stopped", stateReasons = "offline-report",
            statusMessage = "Printer offline", errorCode = "OFFLINE",
            isDuplexSupported = false, isColorSupported = false
        )
        if (printerId.isEmpty()) return offline

        return withContext(Dispatchers.IO) {
            try {
                if (printerId.startsWith("ipp://") || printerId.startsWith("ipps://")) {
                    ippGetPrinterAttributes(printerId, connectMs = minOf(timeoutMs, 10_000), readMs = timeoutMs)
                } else {
                    val (host, port) = parseSocketAddr(printerId)
                    val online = try { java.net.Socket().use { s -> s.connect(java.net.InetSocketAddress(host, port), timeoutMs); true } } catch (_: Exception) { false }
                    if (online) PrinterStatusDetail(
                        printerId = printerId, isOnline = true, isReady = true,
                        hasPaperJam = false, isOutOfPaper = false, isOutOfInk = false,
                        inkLevelBlack = -1L, inkLevelCyan = -1L, inkLevelMagenta = -1L,
                        inkLevelYellow = -1L, tonerLevel = -1L, paperLevel = -1L,
                        jobsInQueue = 0L, isWarmingUp = false,
                        printerState = "idle", stateReasons = "",
                        statusMessage = "", errorCode = "",
                        isDuplexSupported = false, isColorSupported = false
                    ) else offline
                }
            } catch (e: Exception) { offline }
        }
    }

    private fun ippGetPrinterAttributes(uri: String, connectMs: Int = 10_000, readMs: Int = 15_000): PrinterStatusDetail {
        val httpUrl = uri.replaceFirst("ipp://", "http://").replaceFirst("ipps://", "https://")
        val req = buildIppGetPrinterAttributesRequest(uri)
        val conn = try { java.net.URL(httpUrl).openConnection() as java.net.HttpURLConnection } catch (e: Exception) {
            return PrinterStatusDetail(printerId = uri, isOnline = false, isReady = false,
                hasPaperJam = false, isOutOfPaper = false, isOutOfInk = false,
                inkLevelBlack = -1L, inkLevelCyan = -1L, inkLevelMagenta = -1L, inkLevelYellow = -1L,
                tonerLevel = -1L, paperLevel = -1L, jobsInQueue = 0L, isWarmingUp = false,
                printerState = "", stateReasons = "", statusMessage = "", errorCode = "CONNECT_ERROR",
                isDuplexSupported = false, isColorSupported = false)
        }
        return try {
            conn.requestMethod = "POST"
            conn.connectTimeout = connectMs; conn.readTimeout = readMs
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/ipp")
            conn.outputStream.use { it.write(req) }
            val body = conn.inputStream.use { it.readBytes() }
            parseIppPrinterAttributes(uri, body)
        } catch (e: Exception) {
            PrinterStatusDetail(printerId = uri, isOnline = false, isReady = false,
                hasPaperJam = false, isOutOfPaper = false, isOutOfInk = false,
                inkLevelBlack = -1L, inkLevelCyan = -1L, inkLevelMagenta = -1L, inkLevelYellow = -1L,
                tonerLevel = -1L, paperLevel = -1L, jobsInQueue = 0L, isWarmingUp = false,
                printerState = "", stateReasons = "", statusMessage = e.message ?: "", errorCode = "IPP_ERROR",
                isDuplexSupported = false, isColorSupported = false)
        } finally { conn.disconnect() }
    }

    private fun buildIppGetPrinterAttributesRequest(printerUri: String): ByteArray {
        val buf = java.io.ByteArrayOutputStream()
        fun w2(v: Int) { buf.write(v ushr 8 and 0xFF); buf.write(v and 0xFF) }
        fun w4(v: Int) { w2(v ushr 16 and 0xFFFF); w2(v and 0xFFFF) }
        fun strAttr(tag: Int, name: String, value: String) {
            buf.write(tag); w2(name.length); buf.write(name.toByteArray())
            val vb = value.toByteArray(); w2(vb.size); buf.write(vb)
        }
        buf.write(1); buf.write(1); w2(0x000B); w4(1)
        buf.write(0x01)
        strAttr(0x47, "attributes-charset", "utf-8")
        strAttr(0x48, "attributes-natural-language", "en")
        strAttr(0x45, "printer-uri", printerUri)
        buf.write(0x02)
        val attrs = listOf("printer-state","printer-state-reasons","printer-state-message",
            "printer-is-accepting-jobs","queued-job-count",
            "marker-levels","marker-names","marker-colors","marker-types",
            "copies-supported","sides-supported","color-supported")
        attrs.forEachIndexed { i, a ->
            val nameBytes = if (i == 0) "requested-attributes".toByteArray() else ByteArray(0)
            buf.write(0x44); w2(nameBytes.size); buf.write(nameBytes)
            val ab = a.toByteArray(); w2(ab.size); buf.write(ab)
        }
        buf.write(0x03)
        return buf.toByteArray()
    }

    private fun parseIppPrinterAttributes(uri: String, data: ByteArray): PrinterStatusDetail {
        var idx = 8
        var printerState = ""
        val stateReasons = mutableListOf<String>()
        var stateMessage = ""
        var isAccepting = true
        var queuedJobs = 0L
        val markerLevels = mutableListOf<Int>()
        val markerTypes = mutableListOf<String>()
        var supportsColor = false
        var supportsDuplex = false

        fun read2(): Int { if (idx + 1 >= data.size) return 0; val v = (data[idx].toInt() and 0xFF shl 8) or (data[idx+1].toInt() and 0xFF); idx += 2; return v }
        fun read4(): Int { if (idx + 3 >= data.size) return 0; val v = (data[idx].toInt() and 0xFF shl 24) or (data[idx+1].toInt() and 0xFF shl 16) or (data[idx+2].toInt() and 0xFF shl 8) or (data[idx+3].toInt() and 0xFF); idx += 4; return v }
        fun readStr(n: Int): String { if (idx + n > data.size) { idx += n; return "" }; val s = String(data, idx, n, Charsets.UTF_8); idx += n; return s }

        while (idx < data.size) {
            val tag = data[idx++].toInt() and 0xFF
            if (tag == 0x03) break
            if (tag <= 0x0F) continue
            val nameLen = read2()
            val attrName = readStr(nameLen)
            val valLen = read2()
            val valStart = idx
            when (tag) {
                0x23, 0x21 -> { // enum or integer
                    val v = read4()
                    when (attrName) {
                        "printer-state" -> printerState = if (v == 3) "idle" else if (v == 4) "processing" else "stopped"
                        "queued-job-count" -> queuedJobs = v.toLong()
                        "marker-levels", "" -> markerLevels.add(v)
                    }
                }
                0x22 -> { // boolean
                    val v = if (idx < data.size) data[idx] != 0.toByte() else false; idx += valLen
                    when (attrName) {
                        "printer-is-accepting-jobs" -> isAccepting = v
                        "color-supported" -> supportsColor = v
                    }
                }
                else -> {
                    val v = readStr(valLen)
                    when (attrName) {
                        "printer-state-reasons", "" -> stateReasons.add(v)
                        "printer-state-message" -> stateMessage = v
                        "marker-types", "" -> markerTypes.add(v)
                        "sides-supported" -> if (v.contains("two-sided")) supportsDuplex = true
                    }
                    idx = valStart + valLen
                }
            }
        }

        val reasons = stateReasons.filter { it.isNotEmpty() }.joinToString(",")
        val hasPaperJam = reasons.contains("media-jam")
        val outOfPaper = reasons.contains("media-empty") || reasons.contains("media-needed")
        val outOfInk = reasons.contains("toner-empty") || reasons.contains("toner-low") || reasons.contains("marker-supply-empty")
        val isWarmingUp = reasons.contains("warming-up")
        val isReady = isAccepting && printerState != "stopped"
        var inkBlack = -1L; var inkCyan = -1L; var inkMagenta = -1L; var inkYellow = -1L; var toner = -1L
        markerLevels.forEachIndexed { i, level ->
            val t = if (i < markerTypes.size) markerTypes[i].lowercase() else ""
            val l = level.toLong()
            when {
                t.contains("toner") && toner < 0 -> toner = l
                t.contains("cyan") -> inkCyan = l
                t.contains("magenta") -> inkMagenta = l
                t.contains("yellow") -> inkYellow = l
                t.contains("black") || t.contains("ink") -> inkBlack = l
            }
        }
        return PrinterStatusDetail(
            printerId = uri, isOnline = true, isReady = isReady,
            hasPaperJam = hasPaperJam, isOutOfPaper = outOfPaper, isOutOfInk = outOfInk,
            inkLevelBlack = inkBlack, inkLevelCyan = inkCyan, inkLevelMagenta = inkMagenta,
            inkLevelYellow = inkYellow, tonerLevel = toner, paperLevel = -1L,
            jobsInQueue = queuedJobs, isWarmingUp = isWarmingUp,
            printerState = printerState, stateReasons = reasons,
            statusMessage = stateMessage, errorCode = "",
            isDuplexSupported = supportsDuplex, isColorSupported = supportsColor
        )
    }
}
