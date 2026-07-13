// HybridNitroPrinting — Windows C++ implementation (WindowsNativeImpl.cpp)
// Compiled via src/CMakeLists.txt (if(NOT ANDROID)) and
// pulled into both platform builds through add_subdirectory(../src).
//
// Scope:
//   • REAL cross-platform TCP socket transport for raw network printing
//     (printRaw / printEscPos / printZpl / testPrinterConnection and the
//     direct-dispatch path of printText / printImage / printPdf /
//     printDocument / printBatch when a printer URI is given and
//     showPrintDialog == false).
//   • Honest, graceful failure results for OS-print-stack features that are
//     not implemented on these platforms yet (dialogs, queues, discovery,
//     printer enumeration, previews). Nothing crashes, nothing hangs: every
//     native-async method posts exactly one message to its Dart port.
//
// Wire conventions (verified against lib/src/nitro_printing.g.dart and the
// desktop branch of lib/src/generated/cpp/nitro_printing.bridge.g.cpp):
//   • record returns  → post malloc'd [4B len][payload] address as kInt64
//                       (Dart decodes then malloc.free's it).
//   • bool returns    → Dart_CObject_kBool.
//   • int returns     → Dart_CObject_kInt64 (the value itself).
//   • list returns    → malloc'd [4B len][int32 count][int64 offsets×n][items]
//                       address as kInt64 (LazyRecordList.decode; offsets are
//                       relative to the payload start, first = 4 + 8*n).
//   • PreviewResult   → malloc'd PreviewResult struct address as kInt64
//                       (Dart frees the shell; the zero-copy `bytes` pointer
//                       stays native-owned, so it points at a static byte).
//   • errors          → fill *_nitro_err (strdup'd name/message) and still
//                       post a single kNull so the port always fires.
//   • record/list PARAMS arrive as non-owning payload views (the bridge
//     strips the 4-byte length prefix) — copy before going async.

#if defined(_WIN32) || (defined(__linux__) && !defined(__ANDROID__))

#include "nitro_printing.native.g.h"
#include "dart_api_dl.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #ifndef NOMINMAX
    #define NOMINMAX  // keep <windows.h> from defining min()/max() macros,
                      // which otherwise break std::min/std::max (MSVC C2589).
  #endif
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #ifdef _MSC_VER
    #pragma comment(lib, "ws2_32.lib")
  #endif
#else
  #include <sys/types.h>
  #include <sys/socket.h>
  #include <sys/select.h>
  #include <sys/time.h>
  #include <netdb.h>
  #include <netinet/in.h>
  #include <unistd.h>
  #include <fcntl.h>
  #include <cerrno>
#endif

namespace {

// ── Socket primitives (POSIX / Winsock kept small and symmetric) ─────────────

#ifdef _WIN32
using nitro_socket_t = SOCKET;
const nitro_socket_t kInvalidSocket = INVALID_SOCKET;
#else
using nitro_socket_t = int;
const nitro_socket_t kInvalidSocket = -1;
#endif

#ifdef MSG_NOSIGNAL
const int kSendFlags = MSG_NOSIGNAL; // Linux: don't SIGPIPE on broken pipe
#else
const int kSendFlags = 0;            // Windows / macOS (harness) have no MSG_NOSIGNAL
#endif

void socketsInit() {
#ifdef _WIN32
    static std::once_flag once;
    std::call_once(once, [] {
        WSADATA wsa;
        WSAStartup(MAKEWORD(2, 2), &wsa);
    });
#endif
}

void closeSocket(nitro_socket_t s) {
#ifdef _WIN32
    closesocket(s);
#else
    ::close(s);
#endif
}

void shutdownSocket(nitro_socket_t s) {
#ifdef _WIN32
    ::shutdown(s, SD_BOTH);
#else
    ::shutdown(s, SHUT_RDWR);
#endif
}

bool setNonBlocking(nitro_socket_t s, bool nonBlocking) {
#ifdef _WIN32
    u_long mode = nonBlocking ? 1 : 0;
    return ioctlsocket(s, FIONBIO, &mode) == 0;
#else
    int flags = fcntl(s, F_GETFL, 0);
    if (flags < 0) return false;
    flags = nonBlocking ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK);
    return fcntl(s, F_SETFL, flags) == 0;
#endif
}

void setIoTimeout(nitro_socket_t s, int timeoutMs) {
#ifdef _WIN32
    DWORD t = (DWORD)timeoutMs;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&t, sizeof(t));
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&t, sizeof(t));
#else
    timeval tv;
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
#endif
}

/// "socket://host:port", "ipp://host:631/path" or bare "host[:port]"
/// → host + port (default 9100). Mirrors NitroPrintingImpl.kt parseSocketAddr.
struct SocketAddr {
    std::string host;
    int port;
};

SocketAddr parseSocketAddr(const std::string& uri) {
    std::string s = uri;
    for (const char* prefix : {"socket://", "ipp://", "ipps://"}) {
        size_t n = std::strlen(prefix);
        if (s.compare(0, n, prefix) == 0) { s.erase(0, n); break; }
    }
    size_t slash = s.find('/');
    if (slash != std::string::npos) s.erase(slash);
    size_t colon = s.rfind(':');
    if (colon != std::string::npos && colon > 0) {
        int port = 9100;
        try {
            port = std::stoi(s.substr(colon + 1));
        } catch (...) {
            port = 9100;
        }
        return {s.substr(0, colon), port};
    }
    return {s, 9100};
}

/// Non-blocking connect with a select()-based timeout.
/// Returns a connected blocking socket or kInvalidSocket (error filled in).
nitro_socket_t tcpConnect(const std::string& host, int port, int connectTimeoutMs, std::string& error) {
    socketsInit();
    if (host.empty()) {
        error = "Empty host in printer URI";
        return kInvalidSocket;
    }

    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    char portStr[16];
    std::snprintf(portStr, sizeof(portStr), "%d", port);
    addrinfo* res = nullptr;
    if (getaddrinfo(host.c_str(), portStr, &hints, &res) != 0 || res == nullptr) {
        error = "Failed to resolve host '" + host + "'";
        if (res) freeaddrinfo(res);
        return kInvalidSocket;
    }

    nitro_socket_t connectedSock = kInvalidSocket;
    error = "Connection failed";
    for (addrinfo* ai = res; ai != nullptr; ai = ai->ai_next) {
        nitro_socket_t s = ::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == kInvalidSocket) continue;
#ifdef SO_NOSIGPIPE // BSD/macOS: suppress SIGPIPE at socket level
        {
            int one = 1;
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        }
#endif
        if (!setNonBlocking(s, true)) {
            closeSocket(s);
            continue;
        }
        bool connected = (::connect(s, ai->ai_addr, (int)ai->ai_addrlen) == 0);
        if (!connected) {
#ifdef _WIN32
            bool inProgress = (WSAGetLastError() == WSAEWOULDBLOCK);
#else
            bool inProgress = (errno == EINPROGRESS);
#endif
            if (inProgress) {
                fd_set wfds;
                FD_ZERO(&wfds);
                FD_SET(s, &wfds);
                fd_set efds; // Winsock signals connect failure via exceptfds
                FD_ZERO(&efds);
                FD_SET(s, &efds);
                timeval tv;
                tv.tv_sec = connectTimeoutMs / 1000;
                tv.tv_usec = (connectTimeoutMs % 1000) * 1000;
                int sel = ::select((int)(s + 1), nullptr, &wfds, &efds, &tv);
                if (sel > 0 && FD_ISSET(s, &wfds)) {
                    int soErr = 0;
#ifdef _WIN32
                    int len = (int)sizeof(soErr);
                    getsockopt(s, SOL_SOCKET, SO_ERROR, (char*)&soErr, &len);
#else
                    socklen_t len = sizeof(soErr);
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &len);
#endif
                    connected = (soErr == 0);
                    if (!connected) error = "Connection refused (errno " + std::to_string(soErr) + ")";
                } else if (sel == 0) {
                    error = "Connection timed out after " + std::to_string(connectTimeoutMs) + " ms";
                } else {
                    error = "Connection failed (select error)";
                }
            }
        }
        if (connected) {
            setNonBlocking(s, false);
            connectedSock = s;
            break;
        }
        closeSocket(s);
    }
    freeaddrinfo(res);
    return connectedSock;
}

bool sendAll(nitro_socket_t s, const uint8_t* data, size_t len, std::string& error) {
    size_t sent = 0;
    while (sent < len) {
#ifdef _WIN32
        int chunk = (int)std::min<size_t>(len - sent, 1u << 20);
        int n = ::send(s, (const char*)(data + sent), chunk, kSendFlags);
        if (n == SOCKET_ERROR) {
            error = "Socket send failed (WSA error " + std::to_string(WSAGetLastError()) + ")";
            return false;
        }
#else
        ssize_t n = ::send(s, data + sent, len - sent, kSendFlags);
        if (n < 0) {
            if (errno == EINTR) continue;
            error = std::string("Socket send failed: ") + std::strerror(errno);
            return false;
        }
#endif
        if (n == 0) {
            error = "Socket closed during send";
            return false;
        }
        sent += (size_t)n;
    }
    return true;
}

// ── Raw-job cancellation state (cancelRawPrint) ──────────────────────────────

std::mutex g_rawMutex;
nitro_socket_t g_rawSocket = kInvalidSocket; // active raw-print socket, if any
bool g_rawCancelled = false;

// ── Print transport ──────────────────────────────────────────────────────────

struct Timeouts {
    int connectMs;
    int ioMs;
};

/// networkTimeoutSeconds (default 30, clamped to [1, 3600]);
/// connect timeout is additionally capped at 15 s — mirrors the Kotlin impl.
Timeouts timeoutsFrom(const std::optional<PrintSettings>& s) {
    int64_t t = (s && s->networkTimeoutSeconds > 0) ? s->networkTimeoutSeconds : 30;
    t = std::min<int64_t>(std::max<int64_t>(t, 1), 3600);
    int ioMs = (int)(t * 1000);
    return {std::min<int>(ioMs, 15000), ioMs};
}

std::string makeJobId() {
    static std::atomic<uint64_t> counter{0};
    return "cpp-raw-" + std::to_string(++counter);
}

/// Connects, writes [data] `copies` times on one connection, closes.
/// When [trackForCancel] the socket is registered so cancelRawPrint() can
/// abort it from another thread.
PrintResult socketPrint(const std::string& uri, const std::vector<uint8_t>& data, int64_t copies,
                        const Timeouts& t, bool trackForCancel, const char* failCode) {
    SocketAddr addr = parseSocketAddr(uri);
    std::string error;
    nitro_socket_t s = tcpConnect(addr.host, addr.port, t.connectMs, error);
    if (s == kInvalidSocket) {
        return PrintResult{false, "", error, failCode};
    }
    if (trackForCancel) {
        std::lock_guard<std::mutex> lock(g_rawMutex);
        g_rawCancelled = false;
        g_rawSocket = s;
    }
    setIoTimeout(s, t.ioMs);

    bool ok = true;
    std::string sendError;
    if (copies < 1) copies = 1;
    for (int64_t i = 0; i < copies && ok; i++) {
        if (trackForCancel) {
            std::lock_guard<std::mutex> lock(g_rawMutex);
            if (g_rawCancelled) {
                ok = false;
                sendError = "Cancelled";
                break;
            }
        }
        ok = sendAll(s, data.data(), data.size(), sendError);
    }

    bool cancelled = false;
    if (trackForCancel) {
        std::lock_guard<std::mutex> lock(g_rawMutex);
        cancelled = g_rawCancelled;
        g_rawSocket = kInvalidSocket;
    }
    closeSocket(s);

    if (!ok) {
        return PrintResult{false, "",
                           cancelled ? "Cancelled" : sendError,
                           cancelled ? "CANCELLED" : failCode};
    }
    return PrintResult{true, makeJobId(), "", ""};
}

// ── Decoding helpers (params are non-owning payload views) ───────────────────

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

// ── Dart-port posting helpers ────────────────────────────────────────────────

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
/// it; if the post fails (port closed / hot restart) we free it ourselves.
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

/// Fills the per-call NitroError slot Dart allocated. Dart frees the strdup'd
/// strings (they must be malloc-backed) after the port message arrives.
void reportAsyncError(NitroError* err, const char* name, const char* message) {
    if (err == nullptr) return;
    err->hasError = 1;
    err->name = strdup(name);
    err->message = strdup(message);
    err->code = nullptr;
    err->stackTrace = nullptr;
}

/// Runs [fn] on a detached worker thread. On any exception, reports it via
/// the error slot and still posts exactly one kNull so the port fires.
template <typename F>
void runAsync(NitroError* err, int64_t port, F&& fn) {
    std::thread([err, port, fn = std::forward<F>(fn)]() mutable {
        try {
            fn();
        } catch (const std::exception& e) {
            reportAsyncError(err, "CppException", e.what());
            postNull(port);
        } catch (...) {
            reportAsyncError(err, "CppException", "Unknown C++ exception");
            postNull(port);
        }
    }).detach();
}

// ── Print routing ────────────────────────────────────────────────────────────

PrintResult unsupportedDialogResult() {
    return PrintResult{false, "",
                       "OS print dialog is not implemented on this platform yet",
                       "UNSUPPORTED_PLATFORM"};
}

/// Document-style direct dispatch (printText / printImage / printPdf /
/// printDocument / printBatch items): requires a printer URI and
/// showPrintDialog == false; otherwise reports UNSUPPORTED_PLATFORM.
PrintResult directPrint(const std::vector<uint8_t>& payload, const std::optional<PrintSettings>& s) {
    if (!s || s->showPrintDialog || s->printerId.empty()) {
        return unsupportedDialogResult();
    }
    Timeouts t = timeoutsFrom(s);
    int64_t copies = std::max<int64_t>(1, s->copies);
    return socketPrint(s->printerId, payload, copies, t, /*trackForCancel=*/false, "DIRECT_PRINT_FAILED");
}

/// Raw-protocol dispatch (printRaw / printEscPos / printZpl): requires a
/// printer URI; NO_PRINTER otherwise. Mirrors the Kotlin raw path.
PrintResult rawPrint(const std::vector<uint8_t>& payload, const std::optional<PrintSettings>& s,
                     int64_t copies, const char* noPrinterMessage) {
    if (!s || s->printerId.empty()) {
        return PrintResult{false, "", noPrinterMessage, "NO_PRINTER"};
    }
    Timeouts t = timeoutsFrom(s);
    return socketPrint(s->printerId, payload, copies, t, /*trackForCancel=*/true, "SOCKET_ERROR");
}

// ── Implementation ───────────────────────────────────────────────────────────

class HybridNitroPrintingImpl final : public HybridNitroPrinting {
public:
    HybridNitroPrintingImpl() = default;
    ~HybridNitroPrintingImpl() override = default;

    // ── Sync methods ─────────────────────────────────────────────────────

    bool isPrintingSupported() override { return false; }

    int64_t getPrintersCount() override { return 0; }

    std::string getPrinterDriverVersion(const std::string& printerId) override {
        (void)printerId;
        return "";
    }

    // ── @NitroResult sync-buffer methods — honest error results ─────────
    // Throwing lets the generated desktop shim encode the tagged error blob
    // ([1B tag=1][4B len][string]) that Dart decodes into NitroErr(message).

    NitroCppBuffer getPrinterAt(int64_t index) override {
        (void)index;
        throw std::runtime_error("Not supported on this platform");
    }

    NitroCppBuffer getDefaultPrinter() override {
        throw std::runtime_error("Not supported on this platform");
    }

    NitroCppBuffer getPrinterCapabilities(const std::string& printerId) override {
        (void)printerId;
        throw std::runtime_error("Not supported on this platform");
    }

    NitroCppBuffer getPrintJobAt(int64_t index) override {
        (void)index;
        throw std::runtime_error("Not supported on this platform");
    }

    NitroCppBuffer getPrintJobStatus(const std::string& jobId) override {
        (void)jobId;
        throw std::runtime_error("Not supported on this platform");
    }

    NitroCppBuffer getPrinterStatusDetail(const std::string& printerId,
                                          std::optional<int64_t> timeoutSeconds) override {
        (void)printerId;
        (void)timeoutSeconds;
        throw std::runtime_error("Not supported on this platform");
    }

    // ── Printer enumeration / discovery (not available here) ────────────

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

    // ── Document printing (direct socket dispatch or honest failure) ────

    void printText(const std::string& text, NitroCppBuffer settings,
                   NitroError* _nitro_err, int64_t dartPort) override {
        std::vector<uint8_t> payload(text.begin(), text.end()); // UTF-8 bytes
        auto s = decodeSettings(settings);
        runAsync(_nitro_err, dartPort, [payload = std::move(payload), s = std::move(s), dartPort]() {
            postPrintResult(dartPort, directPrint(payload, s));
        });
    }

    void printImage(const uint8_t* imageData, size_t imageData_length, NitroCppBuffer settings,
                    NitroError* _nitro_err, int64_t dartPort) override {
        std::vector<uint8_t> payload(imageData, imageData + imageData_length);
        auto s = decodeSettings(settings);
        runAsync(_nitro_err, dartPort, [payload = std::move(payload), s = std::move(s), dartPort]() {
            postPrintResult(dartPort, directPrint(payload, s));
        });
    }

    void printPdf(const uint8_t* pdfData, size_t pdfData_length, NitroCppBuffer settings,
                  NitroError* _nitro_err, int64_t dartPort) override {
        std::vector<uint8_t> payload(pdfData, pdfData + pdfData_length);
        auto s = decodeSettings(settings);
        runAsync(_nitro_err, dartPort, [payload = std::move(payload), s = std::move(s), dartPort]() {
            postPrintResult(dartPort, directPrint(payload, s));
        });
    }

    void printDocument(NitroCppBuffer document, NitroCppBuffer settings,
                       NitroError* _nitro_err, int64_t dartPort) override {
        PrintDocument doc = PrintDocument::fromNative(document);
        auto s = decodeSettings(settings);
        runAsync(_nitro_err, dartPort, [payload = std::move(doc.data), s = std::move(s), dartPort]() {
            postPrintResult(dartPort, directPrint(payload, s));
        });
    }

    void printBatch(NitroCppBuffer documents, bool stopOnError, NitroCppBuffer settings,
                    NitroError* _nitro_err, int64_t dartPort) override {
        // Param wire format: [int32 count][int64 offsets×count][item bytes...]
        // (RecordWriter.encodeIndexedList; offsets relative to payload start).
        std::vector<std::vector<uint8_t>> payloads;
        NitroRecordReader r(documents);
        int32_t count = r.readInt32();
        if (count < 0) throw std::runtime_error("printBatch: malformed document list");
        std::vector<int64_t> offsets((size_t)count);
        for (int32_t i = 0; i < count; i++) offsets[(size_t)i] = r.readInt();
        payloads.reserve((size_t)count);
        for (int32_t i = 0; i < count; i++) {
            int64_t off = offsets[(size_t)i];
            if (off < 0 || (size_t)off > documents.size) {
                throw std::runtime_error("printBatch: document offset out of range");
            }
            NitroRecordReader itemReader(documents.data + off, documents.size - (size_t)off);
            PrintDocument doc = PrintDocument::fromReader(itemReader);
            payloads.push_back(std::move(doc.data));
        }
        auto s = decodeSettings(settings);
        runAsync(_nitro_err, dartPort,
                 [payloads = std::move(payloads), s = std::move(s), stopOnError, dartPort]() {
            std::vector<std::vector<uint8_t>> resultBlobs;
            resultBlobs.reserve(payloads.size());
            for (const auto& payload : payloads) {
                PrintResult res = directPrint(payload, s);
                NitroRecordWriter w;
                res.encodeInto(w);
                resultBlobs.push_back(std::move(w._buf));
                if (stopOnError && !res.success) break;
            }
            postRecordList(dartPort, resultBlobs);
        });
    }

    void printFile(const std::string& filePath, NitroCppBuffer settings,
                   NitroError* _nitro_err, int64_t dartPort) override {
        (void)filePath;
        (void)settings;
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    // ── Dialog / preview / page count (no OS print stack here) ──────────

    void showPrintDialog(NitroCppBuffer document, NitroCppBuffer initialSettings,
                         NitroError* _nitro_err, int64_t dartPort) override {
        (void)document;
        (void)_nitro_err;
        PrintDialogResult result{};
        result.confirmed = false;
        auto s = decodeSettings(initialSettings);
        result.confirmedSettings = s ? *s : defaultSettings();
        result.errorMessage = "Print dialog not implemented on this platform";
        NitroRecordWriter w;
        result.encodeInto(w);
        postRecord(dartPort, w);
    }

    void renderPreview(NitroCppBuffer document, NitroCppBuffer settings,
                       NitroError* _nitro_err, int64_t dartPort) override {
        (void)document;
        (void)settings;
        (void)_nitro_err;
        // Dart expects a malloc'd PreviewResult struct { uint8_t* bytes;
        // int64_t length; } and frees only the shell (freeFields is a no-op),
        // so the zero-copy bytes pointer must stay valid: use a static byte.
        static uint8_t emptyPreviewByte = 0;
        PreviewResult* pv = (PreviewResult*)::malloc(sizeof(PreviewResult));
        if (pv == nullptr) {
            reportAsyncError(_nitro_err, "CppException", "Out of memory");
            postNull(dartPort);
            return;
        }
        pv->bytes = &emptyPreviewByte;
        pv->length = 0;
        Dart_CObject obj;
        obj.type = Dart_CObject_kInt64;
        obj.value.as_int64 = (int64_t)(intptr_t)pv;
        if (!Dart_PostCObject_DL(dartPort, &obj)) {
            ::free(pv);
        }
    }

    void getPageCount(NitroCppBuffer document, NitroError* _nitro_err, int64_t dartPort) override {
        (void)document;
        (void)_nitro_err;
        postInt64(dartPort, 0);
    }

    void printToFile(NitroCppBuffer document, const std::string& outputPath, NitroCppBuffer settings,
                     NitroError* _nitro_err, int64_t dartPort) override {
        (void)document;
        (void)outputPath;
        (void)settings;
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    // ── Job management (no queue on this backend) ────────────────────────

    void cancelPrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)jobId;
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    void pausePrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)jobId;
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    void resumePrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)jobId;
        (void)_nitro_err;
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

    // ── Connection / admin ───────────────────────────────────────────────

    void testPrinterConnection(const std::string& printerId, std::optional<int64_t> timeoutSeconds,
                               NitroError* _nitro_err, int64_t dartPort) override {
        int64_t t = (timeoutSeconds && *timeoutSeconds > 0) ? *timeoutSeconds : 5;
        t = std::min<int64_t>(std::max<int64_t>(t, 1), 3600);
        int timeoutMs = (int)(t * 1000);
        runAsync(_nitro_err, dartPort, [printerId, timeoutMs, dartPort]() {
            SocketAddr addr = parseSocketAddr(printerId);
            std::string error;
            nitro_socket_t s = tcpConnect(addr.host, addr.port, timeoutMs, error);
            bool reachable = (s != kInvalidSocket);
            if (reachable) closeSocket(s);
            postBool(dartPort, reachable);
        });
    }

    void setDefaultPrinter(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId;
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    void openSystemPrintQueue(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId;
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    void openPrinterProperties(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId;
        (void)_nitro_err;
        postBool(dartPort, false);
    }

    // ── Raw protocol printing (real TCP socket transport) ────────────────

    void printRaw(const uint8_t* data, size_t data_length, NitroCppBuffer settings,
                  NitroError* _nitro_err, int64_t dartPort) override {
        std::vector<uint8_t> payload(data, data + data_length);
        auto s = decodeSettings(settings);
        int64_t copies = s ? std::max<int64_t>(1, s->copies) : 1;
        runAsync(_nitro_err, dartPort, [payload = std::move(payload), s = std::move(s), copies, dartPort]() {
            postPrintResult(dartPort, rawPrint(payload, s, copies, "printerId required for raw print"));
        });
    }

    void printEscPos(const uint8_t* escPosData, size_t escPosData_length, NitroCppBuffer settings,
                     NitroError* _nitro_err, int64_t dartPort) override {
        std::vector<uint8_t> payload(escPosData, escPosData + escPosData_length);
        auto s = decodeSettings(settings);
        int64_t copies = s ? std::max<int64_t>(1, s->copies) : 1;
        runAsync(_nitro_err, dartPort, [payload = std::move(payload), s = std::move(s), copies, dartPort]() {
            postPrintResult(dartPort, rawPrint(payload, s, copies, "printerId required for ESC/POS print"));
        });
    }

    void printZpl(const std::string& zpl, NitroCppBuffer settings,
                  NitroError* _nitro_err, int64_t dartPort) override {
        std::vector<uint8_t> payload(zpl.begin(), zpl.end()); // UTF-8 bytes
        auto s = decodeSettings(settings);
        // ZPL scripts carry their own quantity commands — always 1 write,
        // mirroring the Kotlin implementation.
        runAsync(_nitro_err, dartPort, [payload = std::move(payload), s = std::move(s), dartPort]() {
            postPrintResult(dartPort, rawPrint(payload, s, 1, "printerId required for ZPL print"));
        });
    }

    void cancelRawPrint(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        bool cancelled = false;
        {
            std::lock_guard<std::mutex> lock(g_rawMutex);
            g_rawCancelled = true;
            if (g_rawSocket != kInvalidSocket) {
                shutdownSocket(g_rawSocket); // aborts a blocked send; the
                g_rawSocket = kInvalidSocket; // owning thread closes the fd
                cancelled = true;
            }
        }
        postBool(dartPort, cancelled);
    }

    // Streams (onPrintJobChanged / onPrinterStatusChanged /
    // onPrinterDiscovered): the emit_* helpers are defined in the generated
    // bridge; this backend never emits, so subscribers simply see no events.
};

} // namespace

// ── Registration ─────────────────────────────────────────────────────────────
// Exactly ONE registration for the shared desktop implementation.
// (windows/src/HybridNitroPrinting.cpp is intentionally empty and is not part
// of any build; linux/ has no local impl source.)

static HybridNitroPrintingImpl g_nitro_printing_impl;

#if defined(_MSC_VER)
// MSVC has no __attribute__((constructor)); use a static-initializer struct.
namespace {
struct NitroPrintingAutoRegister {
    NitroPrintingAutoRegister() { nitro_printing_register_impl(&g_nitro_printing_impl); }
};
static NitroPrintingAutoRegister g_nitro_printing_auto_register;
} // namespace
#else
__attribute__((constructor))
static void nitro_printing_auto_register() {
    nitro_printing_register_impl(&g_nitro_printing_impl);
}
#endif

#endif // defined(_WIN32) || (defined(__linux__) && !defined(__ANDROID__))
