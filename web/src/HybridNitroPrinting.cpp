// HybridNitroPrinting — web (WASM) implementation. Seeded once by nitrogen link
// from lib/src/generated/cpp/nitro_printing.impl.g.cpp; never overwritten.
//
// TODO: implement all pure-virtual methods declared in HybridNitroPrinting
//   While the line above exists, web keeps compiling the shared
//   src/HybridNitroPrinting.cpp. Implement the methods, delete that line, and
//   re-run `nitrogen link` to build the module from this file instead.
//   The module is single-threaded: never block; post async results from
//   emscripten_async_call or a JS callback, not from a std::thread.
//
// Ownership conventions:
//   • Record/variant/tuple RETURNS, **emit_* stream items**, and record/
//     variant CALLBACK arguments you invoke a callback with: pass
//     writer.toNativeBuffer() (or nitro_<Variant>_to_native) — a malloc'd
//     [4B len][payload] block whose ownership transfers to the bridge/Dart.
//     Returning or emitting a non-owning writer.toBuffer() view is wrong:
//     Dart would decode-and-free a live local buffer.
//   • Record/variant PARAMS are non-owning payload views (no length prefix)
//     — copy if you need them after the call.
//   • TypedData RETURNS use NitroCppBuffer{ data, size } where size is in
//     BYTES, not elements (Float32List: count * sizeof(float)). A wrong
//     unit silently truncates the list Dart sees (bytes / elemSize).
//   • @zeroCopy TypedData returns are NOT copied by the bridge: return a
//     malloc'd buffer — ownership transfers, and the bridge frees it (via
//     <lib>_release_typed_data_return) when Dart's view is GC'd. Never
//     return a pointer to a member or stack buffer: it would be free()d.

#include "nitro_printing.native.g.h"
#include <stdexcept>

// ── Implementation ───────────────────────────────────────────────────────────

class NitroPrintingImpl final : public HybridNitroPrinting {
public:
    NitroPrintingImpl() = default;
    ~NitroPrintingImpl() override = default;

    // ── Methods ──────────────────────────────────────────────────────────────

    bool isPrintingSupported() override {
        // TODO: implement isPrintingSupported
        throw std::runtime_error("Not implemented: isPrintingSupported");
        // return false;
    }

    int64_t getPrintersCount() override {
        // TODO: implement getPrintersCount
        throw std::runtime_error("Not implemented: getPrintersCount");
        // return 0;
    }

    std::string getPrinterDriverVersion(const std::string& printerId) override {
        // TODO: implement getPrinterDriverVersion
        throw std::runtime_error("Not implemented: getPrinterDriverVersion");
        // return "";
    }

    void getAllPrinters(NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: getAllPrinters");
    }

    NitroCppBuffer getPrinterAt(int64_t index) override {
        // TODO: implement getPrinterAt
        throw std::runtime_error("Not implemented: getPrinterAt");
        // return { nullptr, 0 };
    }

    NitroCppBuffer getDefaultPrinter() override {
        // TODO: implement getDefaultPrinter
        throw std::runtime_error("Not implemented: getDefaultPrinter");
        // return { nullptr, 0 };
    }

    NitroCppBuffer getPrinterCapabilities(const std::string& printerId) override {
        // TODO: implement getPrinterCapabilities
        throw std::runtime_error("Not implemented: getPrinterCapabilities");
        // return { nullptr, 0 };
    }

    void printText(const std::string& text, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printText");
    }

    void printImage(const uint8_t* imageData, size_t imageData_length, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printImage");
    }

    void printPdf(const uint8_t* pdfData, size_t pdfData_length, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printPdf");
    }

    void printDocument(NitroCppBuffer document, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printDocument");
    }

    void printFile(const std::string& filePath, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printFile");
    }

    void printBatch(NitroCppBuffer documents, bool stopOnError, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printBatch");
    }

    void showPrintDialog(NitroCppBuffer document, NitroCppBuffer initialSettings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: showPrintDialog");
    }

    void renderPreview(NitroCppBuffer document, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: renderPreview");
    }

    void getPageCount(NitroCppBuffer document, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: getPageCount");
    }

    void printToFile(NitroCppBuffer document, const std::string& outputPath, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printToFile");
    }

    void cancelPrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: cancelPrintJob");
    }

    void pausePrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: pausePrintJob");
    }

    void resumePrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: resumePrintJob");
    }

    void clearPrintQueue(NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: clearPrintQueue");
    }

    void getPrintJobsCount(NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: getPrintJobsCount");
    }

    NitroCppBuffer getPrintJobAt(int64_t index) override {
        // TODO: implement getPrintJobAt
        throw std::runtime_error("Not implemented: getPrintJobAt");
        // return { nullptr, 0 };
    }

    NitroCppBuffer getPrintJobStatus(const std::string& jobId) override {
        // TODO: implement getPrintJobStatus
        throw std::runtime_error("Not implemented: getPrintJobStatus");
        // return { nullptr, 0 };
    }

    void startPrinterDiscovery(NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: startPrinterDiscovery");
    }

    void stopPrinterDiscovery(NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: stopPrinterDiscovery");
    }

    void testPrinterConnection(const std::string& printerId, std::optional<int64_t> timeoutSeconds, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: testPrinterConnection");
    }

    void setDefaultPrinter(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: setDefaultPrinter");
    }

    void openSystemPrintQueue(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: openSystemPrintQueue");
    }

    void openPrinterProperties(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: openPrinterProperties");
    }

    void printRaw(const uint8_t* data, size_t data_length, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printRaw");
    }

    void printEscPos(const uint8_t* escPosData, size_t escPosData_length, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printEscPos");
    }

    void printZpl(const std::string& zpl, NitroCppBuffer settings, NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: printZpl");
    }

    void cancelRawPrint(NitroError* _nitro_err, int64_t dartPort) override {
        // TODO: on error, populate _nitro_err (hasError/name/message via strdup) before posting.
        // TODO: post result via Dart_PostCObject_DL(dartPort, ...)
        // Nullable result? Post EITHER Dart_CObject_kNull OR kInt64 with
        // value 0 — both decode to Dart null. Non-nullable results must
        // always post a real encoded value.
        throw std::runtime_error("Not implemented: cancelRawPrint");
    }

    NitroCppBuffer getPrinterStatusDetail(const std::string& printerId, std::optional<int64_t> timeoutSeconds) override {
        // TODO: implement getPrinterStatusDetail
        throw std::runtime_error("Not implemented: getPrinterStatusDetail");
        // return { nullptr, 0 };
    }

    // ── Streams ──────────────────────────────────────────────────────────────
    // Call emit_<name>(item) from any thread to push items to Dart.
    // emit_* helpers are defined in the generated bridge.
    // Record/variant items: pass record.toNativeBuffer() — ownership of the
    // heap [4B len][payload] block transfers to the bridge (same convention
    // as record returns). Never emit a non-owning writer.toBuffer() view.
    // Example — start emitting from a background thread:
    //
    //   std::thread([this]{ emit_onPrintJobChanged(/* NitroCppBuffer value */); }).detach();
    //   std::thread([this]{ emit_onPrinterStatusChanged(/* NitroCppBuffer value */); }).detach();
    //   std::thread([this]{ emit_onPrinterDiscovered(/* NitroCppBuffer value */); }).detach();
};

// ── Registration ─────────────────────────────────────────────────────────────
//
// Create a single instance and register it during plugin/app initialisation:
//
//   static NitroPrintingImpl g_impl;
//   nitro_printing_register_impl(&g_impl);   // in your plugin init
//   nitro_printing_register_impl(nullptr);   // in your plugin dispose
//
// On Flutter desktop (Windows / Linux / macOS with NativeImpl.cpp) add the
// registration call to your Flutter plugin's RegisterWithRegistrar:
//
//   void NitroPrintingPlugin::RegisterWithRegistrar(PluginRegistrar* registrar) {
//       static NitroPrintingImpl impl;
//       nitro_printing_register_impl(&impl);
//   }

// Registered when the wasm module instantiates.
namespace {
  struct _AutoRegister {
    _AutoRegister() { nitro_printing_register_impl(new NitroPrintingImpl()); }
  };
  static _AutoRegister _auto_register_instance;
}
