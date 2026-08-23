// HybridNitroPrinting — web (WASM/Emscripten) implementation.
//
// Compiled by web/build_web.sh into assets/web/nitro_printing.{js,wasm}.
//
// What the browser CAN do — and this backend implements:
//   • Document printing (text / HTML / image / PDF) through the browser's
//     print dialog: the document is staged in a hidden iframe and printed
//     with contentWindow.print() — the standard web printing path.
//   • showPrintDialog: same flow; `confirmed` reports that the dialog was
//     shown and closed (browsers cannot reveal Print-vs-Cancel).
//   • printToFile: hands the document to the user as a browser download.
//
// What the browser CANNOT do — honest failures/empties:
//   • Printer enumeration, capabilities, default printer (no such API).
//   • Raw TCP / ESC-POS / ZPL (no raw sockets in the sandbox).
//   • OS print queue, job management, driver info.
//
// Web constraint honored throughout: no threads — completions post inline or
// from JS callbacks; the Dart side still observes asynchronous completion
// because port delivery is microtask-deferred. Posting protocol mirrors the
// desktop impl (linux/src/HybridNitroPrinting.cpp).
#ifdef __EMSCRIPTEN__

#include "../lib/src/generated/cpp/nitro_printing.native.g.h"
#include "nitro_wasm_compat.h"

#include <emscripten/emscripten.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr const char* kUnsupportedMsg = "Not supported in the browser sandbox";
constexpr const char* kUnsupportedCode = "WEB_UNSUPPORTED";

// ── Dart-port posting helpers (same wire discipline as desktop) ──────────────

void postNull(int64_t port) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kNull;
    Dart_PostCObject_DL(port, &obj);
}

void postBool(int64_t port, bool v) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kBool;
    obj.value.as_bool = v;
    Dart_PostCObject_DL(port, &obj);
}

void postInt64(int64_t port, int64_t v) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = v;
    Dart_PostCObject_DL(port, &obj);
}

/// Posts a malloc'd blob's address as kInt64. Dart takes ownership and frees
/// it; if the post fails (page teardown / hot restart) we free it ourselves.
void postOwnedBlob(int64_t port, uint8_t* blob) {
    if (blob == nullptr) {
        postNull(port);
        return;
    }
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (int64_t)(intptr_t)blob;
    if (!Dart_PostCObject_DL(port, &obj)) {
        ::free(blob);
    }
}

void postRecord(int64_t port, const NitroRecordWriter& w) {
    postOwnedBlob(port, w.toNative());
}

std::string makeJobId() {
    static std::atomic<uint64_t> counter{0};
    return "web-print-" + std::to_string(++counter);
}

PrintResult failedResult(const char* msg, const char* code) {
    return PrintResult{false, "", msg, code};
}

void postPrintResult(int64_t port, const PrintResult& r) {
    NitroRecordWriter w;
    r.encodeInto(w);
    postRecord(port, w);
}

/// LazyRecordList wire format:
///   payload = [int32 count][int64 offsets×count][item bytes...]
/// offsets are relative to the payload start (first item at 4 + 8*count).
void postRecordList(int64_t port, const std::vector<std::vector<uint8_t>>& items) {
    NitroRecordWriter w;
    w.writeInt32((int32_t)items.size());
    int64_t pos = 4 + 8 * (int64_t)items.size();
    for (const auto& b : items) {
        w.writeInt(pos);
        pos += (int64_t)b.size();
    }
    for (const auto& b : items) {
        w.writeBytes(b.data(), b.size());
    }
    postRecord(port, w);
}

std::optional<PrintSettings> decodeSettings(NitroCppBuffer buf) {
    if (buf.data == nullptr || buf.size == 0) return std::nullopt;
    return PrintSettings::fromNative(buf);
}

PrintSettings defaultSettings() {
    PrintSettings s{}; // zero/empty everything, then set non-trivial defaults
    s.paperSize = PAPERSIZE_A4;
    s.quality = PRINTQUALITY_NORMAL;
    s.mediaType = MEDIATYPE_PLAIN;
    s.copies = 1;
    s.color = true;
    s.pagesPerSheet = 1;
    s.showPrintDialog = true;
    s.networkTimeoutSeconds = 30;
    return s;
}

const char* sniffImageMime(const uint8_t* d, size_t n) {
    if (n >= 4 && d[0] == 0x89 && d[1] == 'P' && d[2] == 'N' && d[3] == 'G') return "image/png";
    if (n >= 2 && d[0] == 0xFF && d[1] == 0xD8) return "image/jpeg";
    if (n >= 4 && d[0] == 'G' && d[1] == 'I' && d[2] == 'F' && d[3] == '8') return "image/gif";
    if (n >= 12 && d[0] == 'R' && d[1] == 'I' && d[2] == 'F' && d[3] == 'F' &&
        d[8] == 'W' && d[9] == 'E' && d[10] == 'B' && d[11] == 'P') return "image/webp";
    return "image/png";
}

// Completion kinds routed through nitro_printing_web_done().
enum WebDoneKind { kDonePrint = 0, kDoneDialog = 1 };

// showPrintDialog settings held until the JS flow calls back, keyed by the
// (unique per call) Dart port.
std::map<int64_t, PrintSettings> g_pendingDialogs;

} // namespace

// ── JS print/download flows ──────────────────────────────────────────────────
// The shared frame helper is installed once on globalThis. Every flow ends by
// calling back into wasm: nitro_printing_web_done / nitro_printing_web_batch_done.

EM_JS(void, js_ensure_helpers, (), {
  if (globalThis.__nitroPrintFrame) return;
  // setup(frame, ready) stages content; ready() prints and reports. done is
  // idempotent and always fires — a load that never happens hits the timeout.
  globalThis.__nitroPrintFrame = function(port, kind, timeoutMs, setup) {
    var fired = false;
    var frame = null;
    var done = function(ok) {
      if (fired) return;
      fired = true;
      setTimeout(function() { try { if (frame) frame.remove(); } catch (e) {} }, 500);
      wasmExports.nitro_printing_web_done(port, kind, ok ? 1 : 0);
    };
    try {
      frame = document.createElement('iframe');
      frame.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden;';
      document.body.appendChild(frame);
      setTimeout(function() { done(0); }, timeoutMs);
      setup(frame, function() {
        try {
          frame.contentWindow.focus();
          frame.contentWindow.print(); // blocks while the dialog is open
          done(1);
        } catch (e) { done(0); }
      });
    } catch (e) { done(0); }
  };
  globalThis.__nitroPrintHtml = function(port, kind, html) {
    globalThis.__nitroPrintFrame(port, kind, 5000, function(frame, ready) {
      frame.onload = ready;
      frame.srcdoc = html;
    });
  };
  globalThis.__nitroPrintBlobUrl = function(port, kind, url, asImage) {
    globalThis.__nitroPrintFrame(port, kind, 8000, function(frame, ready) {
      frame.onload = function() {
        setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
        ready();
      };
      if (asImage) {
        frame.srcdoc = '<html><body style="margin:0"><img src="' + url +
            '" style="max-width:100%"></body></html>';
      } else {
        frame.src = url; // PDF — rendered by the browser's PDF viewer
      }
    });
  };
  globalThis.__nitroTextHtml = function(text) {
    var pre = document.createElement('pre');
    pre.textContent = text;
    return '<html><body style="margin:24px;font:14px/1.4 monospace;white-space:pre-wrap">' +
        pre.outerHTML + '</body></html>';
  };
});

EM_JS(void, js_print_text, (int64_t port, int kind, const char* text), {
  js_ensure_helpers();
  globalThis.__nitroPrintHtml(port, kind, globalThis.__nitroTextHtml(UTF8ToString(text)));
});

EM_JS(void, js_print_html, (int64_t port, int kind, const char* html), {
  js_ensure_helpers();
  globalThis.__nitroPrintHtml(port, kind, UTF8ToString(html));
});

EM_JS(void, js_print_blob, (int64_t port, int kind, const uint8_t* data, int len, const char* mime, int asImage), {
  js_ensure_helpers();
  var bytes = HEAPU8.slice(data, data + len); // copy — blob outlives wasm heap views
  var url = URL.createObjectURL(new Blob([bytes], { type: UTF8ToString(mime) }));
  globalThis.__nitroPrintBlobUrl(port, kind, url, asImage);
});

EM_JS(void, js_download, (const uint8_t* data, int len, const char* mime, const char* name), {
  var bytes = HEAPU8.slice(data, data + len);
  var url = URL.createObjectURL(new Blob([bytes], { type: UTF8ToString(mime) }));
  var a = document.createElement('a');
  a.href = url;
  a.download = UTF8ToString(name);
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
});

// Sequential batch: items are staged from C++, then run one after another so
// the print dialogs don't race. Reports a per-item success bitmask.
EM_JS(void, js_batch_add, (int type, const uint8_t* data, int len), {
  js_ensure_helpers();
  if (!globalThis.__nitroBatch) globalThis.__nitroBatch = [];
  globalThis.__nitroBatch.push({ type: type, bytes: HEAPU8.slice(data, data + len) });
});

EM_JS(void, js_batch_run, (int64_t port, int stopOnError), {
  js_ensure_helpers();
  var items = globalThis.__nitroBatch || [];
  globalThis.__nitroBatch = [];
  var mask = 0n;
  var ran = 0;
  var runOne = function(i) {
    if (i >= items.length) {
      wasmExports.nitro_printing_web_batch_done(port, mask, ran);
      return;
    }
    var item = items[i];
    var localPort = -1n - BigInt(i); // sentinel — routed to __nitroBatchDone
    globalThis.__nitroBatchDone = function(ok) {
      ran++;
      if (ok) mask |= (1n << BigInt(i));
      if (!ok && stopOnError) {
        wasmExports.nitro_printing_web_batch_done(port, mask, ran);
      } else {
        runOne(i + 1);
      }
    };
    var td = new TextDecoder();
    if (item.type === 0) {        // plainText
      globalThis.__nitroPrintHtml(localPort, 2, globalThis.__nitroTextHtml(td.decode(item.bytes)));
    } else if (item.type === 1) { // html
      globalThis.__nitroPrintHtml(localPort, 2, td.decode(item.bytes));
    } else {                       // pdf (2) / image (3)
      var mime = item.type === 2 ? 'application/pdf' : 'image/png';
      var url = URL.createObjectURL(new Blob([item.bytes], { type: mime }));
      globalThis.__nitroPrintBlobUrl(localPort, 2, url, item.type === 3 ? 1 : 0);
    }
  };
  runOne(0);
});

// ── Wasm-exported completion callbacks (invoked from the JS flows) ───────────

extern "C" {

EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_done(int64_t port, int kind, int ok) {
    if (kind == 2) {
        // Batch item sentinel — forwarded to the JS-side batch driver.
        EM_ASM({ if (globalThis.__nitroBatchDone) globalThis.__nitroBatchDone($0); }, ok);
        return;
    }
    if (kind == kDoneDialog) {
        PrintDialogResult result{};
        auto it = g_pendingDialogs.find(port);
        result.confirmedSettings = (it != g_pendingDialogs.end()) ? it->second : defaultSettings();
        if (it != g_pendingDialogs.end()) g_pendingDialogs.erase(it);
        // Browsers cannot reveal Print-vs-Cancel: confirmed means the dialog
        // was shown and closed.
        result.confirmed = ok != 0;
        result.errorMessage = ok ? "" : "Browser print dialog failed to open";
        NitroRecordWriter w;
        result.encodeInto(w);
        postRecord(port, w);
        return;
    }
    if (ok) {
        postPrintResult(port, PrintResult{true, makeJobId(), "", ""});
    } else {
        postPrintResult(port, failedResult("Browser print failed or timed out", "WEB_PRINT_FAILED"));
    }
}

EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_batch_done(int64_t port, int64_t mask, int ran) {
    std::vector<std::vector<uint8_t>> blobs;
    blobs.reserve((size_t)ran);
    for (int i = 0; i < ran; i++) {
        bool ok = (mask >> i) & 1;
        NitroRecordWriter w;
        PrintResult r = ok ? PrintResult{true, makeJobId(), "", ""}
                           : failedResult("Browser print failed or timed out", "WEB_PRINT_FAILED");
        r.encodeInto(w);
        blobs.push_back(std::move(w._buf));
    }
    postRecordList(port, blobs);
}

} // extern "C"

namespace {

class HybridNitroPrintingImpl final : public HybridNitroPrinting {
public:
    // ── Synchronous quick-lookup ─────────────────────────────────────────

    // The browser CAN print (via its print dialog) — that is what this
    // backend drives, so printing is supported even though enumeration isn't.
    bool isPrintingSupported() override { return true; }

    int64_t getPrintersCount() override { return 0; } // no enumeration API

    std::string getPrinterDriverVersion(const std::string& printerId) override {
        (void)printerId;
        return "";
    }

    // ── @NitroResult sync-buffer methods — honest error results ─────────
    // Throwing lets the generated shim encode the tagged error blob that
    // Dart decodes into NitroErr(message).

    NitroCppBuffer getPrinterAt(int64_t index) override {
        (void)index;
        throw std::runtime_error(kUnsupportedMsg);
    }

    NitroCppBuffer getDefaultPrinter() override {
        throw std::runtime_error(kUnsupportedMsg);
    }

    NitroCppBuffer getPrinterCapabilities(const std::string& printerId) override {
        (void)printerId;
        throw std::runtime_error(kUnsupportedMsg);
    }

    NitroCppBuffer getPrintJobAt(int64_t index) override {
        (void)index;
        throw std::runtime_error(kUnsupportedMsg);
    }

    NitroCppBuffer getPrintJobStatus(const std::string& jobId) override {
        (void)jobId;
        throw std::runtime_error(kUnsupportedMsg);
    }

    NitroCppBuffer getPrinterStatusDetail(const std::string& printerId,
                                          std::optional<int64_t> timeoutSeconds) override {
        (void)printerId;
        (void)timeoutSeconds;
        throw std::runtime_error(kUnsupportedMsg);
    }

    // ── Printer enumeration / discovery (no browser API) ─────────────────

    void getAllPrinters(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postRecordList(dartPort, {}); // empty List<PrinterInfo>
    }

    void startPrinterDiscovery(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    void stopPrinterDiscovery(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    // ── Document printing — browser print dialog ─────────────────────────

    void printText(const std::string& text, NitroCppBuffer settings,
                   NitroError* _nitro_err, int64_t dartPort) override {
        (void)settings; (void)_nitro_err;
        js_print_text(dartPort, kDonePrint, text.c_str());
    }

    void printImage(const uint8_t* imageData, size_t imageData_length, NitroCppBuffer settings,
                    NitroError* _nitro_err, int64_t dartPort) override {
        (void)settings; (void)_nitro_err;
        js_print_blob(dartPort, kDonePrint, imageData, (int)imageData_length,
                      sniffImageMime(imageData, imageData_length), 1);
    }

    void printPdf(const uint8_t* pdfData, size_t pdfData_length, NitroCppBuffer settings,
                  NitroError* _nitro_err, int64_t dartPort) override {
        (void)settings; (void)_nitro_err;
        js_print_blob(dartPort, kDonePrint, pdfData, (int)pdfData_length, "application/pdf", 0);
    }

    void printDocument(NitroCppBuffer document, NitroCppBuffer settings,
                       NitroError* _nitro_err, int64_t dartPort) override {
        (void)settings; (void)_nitro_err;
        PrintDocument doc = PrintDocument::fromNative(document);
        dispatchDoc(doc, dartPort, kDonePrint);
    }

    void printBatch(NitroCppBuffer documents, bool stopOnError, NitroCppBuffer settings,
                    NitroError* _nitro_err, int64_t dartPort) override {
        (void)settings; (void)_nitro_err;
        // Param wire format: [int32 count][int64 offsets×count][item bytes...]
        NitroRecordReader r(documents);
        int32_t count = r.readInt32();
        if (count < 0) throw std::runtime_error("printBatch: malformed document list");
        // ponytail: per-item success is a 64-bit mask — batches beyond 64 docs
        // report items past 64 as failed; widen to a byte array if ever needed.
        std::vector<int64_t> offsets((size_t)count);
        for (int32_t i = 0; i < count; i++) offsets[(size_t)i] = r.readInt();
        for (int32_t i = 0; i < count; i++) {
            int64_t off = offsets[(size_t)i];
            if (off < 0 || (size_t)off > documents.size) {
                throw std::runtime_error("printBatch: document offset out of range");
            }
            NitroRecordReader itemReader(documents.data + off, documents.size - (size_t)off);
            PrintDocument doc = PrintDocument::fromReader(itemReader);
            js_batch_add((int)doc.type, doc.data.data(), (int)doc.data.size());
        }
        js_batch_run(dartPort, stopOnError ? 1 : 0);
    }

    void printFile(const std::string& filePath, NitroCppBuffer settings,
                   NitroError* _nitro_err, int64_t dartPort) override {
        // No local filesystem in the browser sandbox.
        (void)filePath; (void)settings; (void)_nitro_err;
        postBool(dartPort, false);
    }

    // ── Dialog / preview / page count ────────────────────────────────────

    void showPrintDialog(NitroCppBuffer document, NitroCppBuffer initialSettings,
                         NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        auto s = decodeSettings(initialSettings);
        g_pendingDialogs[dartPort] = s ? *s : defaultSettings();
        PrintDocument doc = PrintDocument::fromNative(document);
        dispatchDoc(doc, dartPort, kDoneDialog);
    }

    void renderPreview(NitroCppBuffer document, NitroCppBuffer settings,
                       NitroError* _nitro_err, int64_t dartPort) override {
        (void)document; (void)settings;
        // No PDF renderer in the sandbox — an empty preview. Dart expects a
        // malloc'd PreviewResult shell { uint8_t* bytes; int64_t length; }
        // and frees only the shell, so the bytes pointer must stay valid.
        static uint8_t emptyPreviewByte = 0;
        PreviewResult* pv = (PreviewResult*)::malloc(sizeof(PreviewResult));
        if (pv == nullptr) {
            if (_nitro_err != nullptr) {
                _nitro_err->hasError = 1;
                _nitro_err->name = strdup("CppException");
                _nitro_err->message = strdup("Out of memory");
                _nitro_err->code = nullptr;
                _nitro_err->stackTrace = nullptr;
            }
            postNull(dartPort);
            return;
        }
        pv->bytes = &emptyPreviewByte;
        pv->length = 0;
        postOwnedBlob(dartPort, (uint8_t*)pv);
    }

    void getPageCount(NitroCppBuffer document, NitroError* _nitro_err, int64_t dartPort) override {
        (void)document; (void)_nitro_err;
        postInt64(dartPort, 0); // unknown without a layout engine
    }

    void printToFile(NitroCppBuffer document, const std::string& outputPath, NitroCppBuffer settings,
                     NitroError* _nitro_err, int64_t dartPort) override {
        (void)settings; (void)_nitro_err;
        // The web analog of a virtual print: hand the bytes to the user as a
        // download named after outputPath's basename.
        PrintDocument doc = PrintDocument::fromNative(document);
        std::string name = outputPath;
        size_t slash = name.find_last_of("/\\");
        if (slash != std::string::npos) name = name.substr(slash + 1);
        if (name.empty()) name = doc.title.empty() ? "document" : doc.title;
        const char* mime =
            doc.type == DOCUMENTTYPE_PDF   ? "application/pdf" :
            doc.type == DOCUMENTTYPE_HTML  ? "text/html" :
            doc.type == DOCUMENTTYPE_IMAGE ? sniffImageMime(doc.data.data(), doc.data.size())
                                           : "text/plain";
        js_download(doc.data.data(), (int)doc.data.size(), mime, name.c_str());
        postBool(dartPort, true);
    }

    // ── Job management (no queue in the browser) ─────────────────────────

    void cancelPrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)jobId; (void)_nitro_err;
        postBool(dartPort, false);
    }

    void pausePrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)jobId; (void)_nitro_err;
        postBool(dartPort, false);
    }

    void resumePrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)jobId; (void)_nitro_err;
        postBool(dartPort, false);
    }

    void clearPrintQueue(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    void getPrintJobsCount(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postInt64(dartPort, 0);
    }

    // ── Connection / admin (no sockets / OS UI in the sandbox) ───────────

    void testPrinterConnection(const std::string& printerId, std::optional<int64_t> timeoutSeconds,
                               NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId; (void)timeoutSeconds; (void)_nitro_err;
        postBool(dartPort, false);
    }

    void setDefaultPrinter(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId; (void)_nitro_err;
        postBool(dartPort, false);
    }

    void openSystemPrintQueue(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId; (void)_nitro_err;
        postBool(dartPort, false);
    }

    void openPrinterProperties(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId; (void)_nitro_err;
        postBool(dartPort, false);
    }

    // ── Raw protocol printing (no TCP in the browser) ────────────────────

    void printRaw(const uint8_t* data, size_t data_length, NitroCppBuffer settings,
                  NitroError* _nitro_err, int64_t dartPort) override {
        (void)data; (void)data_length; (void)settings; (void)_nitro_err;
        postPrintResult(dartPort, failedResult(kUnsupportedMsg, kUnsupportedCode));
    }

    void printEscPos(const uint8_t* escPosData, size_t escPosData_length, NitroCppBuffer settings,
                     NitroError* _nitro_err, int64_t dartPort) override {
        (void)escPosData; (void)escPosData_length; (void)settings; (void)_nitro_err;
        postPrintResult(dartPort, failedResult(kUnsupportedMsg, kUnsupportedCode));
    }

    void printZpl(const std::string& zpl, NitroCppBuffer settings,
                  NitroError* _nitro_err, int64_t dartPort) override {
        (void)zpl; (void)settings; (void)_nitro_err;
        postPrintResult(dartPort, failedResult(kUnsupportedMsg, kUnsupportedCode));
    }

    void cancelRawPrint(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    // Streams (onPrintJobChanged / onPrinterStatusChanged /
    // onPrinterDiscovered): this backend never emits, so subscribers simply
    // see no events.

private:
    /// Routes a PrintDocument to the matching JS print flow.
    static void dispatchDoc(const PrintDocument& doc, int64_t port, int kind) {
        switch (doc.type) {
            case DOCUMENTTYPE_PLAIN_TEXT: {
                std::string text(doc.data.begin(), doc.data.end());
                js_print_text(port, kind, text.c_str());
                break;
            }
            case DOCUMENTTYPE_HTML: {
                std::string html(doc.data.begin(), doc.data.end());
                js_print_html(port, kind, html.c_str());
                break;
            }
            case DOCUMENTTYPE_PDF:
                js_print_blob(port, kind, doc.data.data(), (int)doc.data.size(),
                              "application/pdf", 0);
                break;
            case DOCUMENTTYPE_IMAGE:
            default:
                js_print_blob(port, kind, doc.data.data(), (int)doc.data.size(),
                              sniffImageMime(doc.data.data(), doc.data.size()), 1);
                break;
        }
    }
};

// Registration runs during module instantiation (__wasm_call_ctors), before
// any Dart call reaches the bridge. The generated C++ dispatch path uses the
// single-instance register_impl API (same as the desktop backends).
HybridNitroPrintingImpl g_nitro_printing_impl;

__attribute__((constructor))
void nitro_printing_auto_register() {
    nitro_printing_register_impl(&g_nitro_printing_impl);
}

} // namespace

#endif // __EMSCRIPTEN__
