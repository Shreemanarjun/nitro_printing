// Linux printing implementation for nitro_printing.
//
// All spooled printing goes via CUPS (libcups).
// Raw / ESC-POS / ZPL printing uses a direct POSIX TCP socket to port 9100
// when the printerId contains a host address or a socket:// / ipp:// URI.
//
// Printer discovery emits CUPS destinations (local + network).
// mDNS / Bonjour browsing is delegated to CUPS itself — cupsGetDests() on
// modern CUPS (≥ 2.x) already discovers Bonjour-advertised printers.
//
// Printer status detail uses IPP Get-Printer-Attributes via cupsConnectDest
// / ippNewRequest so we get ink/toner/paper levels and state-reasons.

#include <cups/cups.h>
#include <cups/ipp.h>
#include <cups/ppd.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netdb.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <algorithm>
#include <atomic>
#include <string>
#include <vector>
#include <stdexcept>
#include "../../lib/src/generated/cpp/nitro_printing.native.g.h"

// ── Internal helpers ──────────────────────────────────────────────────────────

// Write bytes to a secure temp file; returns path or "" on failure.
static std::string writeTempFile(const uint8_t* data, size_t len, const char* suffix) {
    const char* tmpdir = getenv("TMPDIR");
    if (!tmpdir) tmpdir = "/tmp";
    std::string tmpl = std::string(tmpdir) + "/ntp_XXXXXX";
    // mkstemp requires a mutable buffer
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    int fd = mkstemp(buf.data());
    if (fd < 0) return {};
    // Write data
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, data + written, len - written);
        if (n < 0) { close(fd); unlink(buf.data()); return {}; }
        written += static_cast<size_t>(n);
    }
    close(fd);
    // Rename to add the suffix (so CUPS can infer the MIME type)
    std::string finalPath = std::string(buf.data()) + suffix;
    if (rename(buf.data(), finalPath.c_str()) != 0) {
        // If rename fails (cross-device), fall back to the original name
        finalPath = std::string(buf.data());
    }
    return finalPath;
}

// Parse host + port from a printerId string.
// Handles: "192.168.1.5", "hostname", "socket://host:9100",
//          "ipp://host:631/ipp/print", "host:9100".
static void parseHostPort(const std::string& uri, std::string& host, int& port) {
    std::string s = uri;
    // Strip scheme
    auto schemeEnd = s.find("://");
    if (schemeEnd != std::string::npos) s = s.substr(schemeEnd + 3);
    // Strip path
    auto pathStart = s.find('/');
    if (pathStart != std::string::npos) s = s.substr(0, pathStart);
    // Strip query
    auto qstart = s.find('?');
    if (qstart != std::string::npos) s = s.substr(0, qstart);
    // Split host:port
    auto colon = s.rfind(':');
    if (colon != std::string::npos) {
        host = s.substr(0, colon);
        try { port = std::stoi(s.substr(colon + 1)); } catch (...) {}
    } else {
        host = s;
    }
}

// TCP connect with timeout (seconds). Returns connected socket fd or -1.
static int tcpConnect(const std::string& host, int port, int timeoutSec) {
    struct addrinfo hints{}, *res = nullptr;
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    std::string portStr = std::to_string(port);
    if (getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res) != 0 || !res)
        return -1;

    int fd = socket(res->ai_family, SOCK_STREAM, 0);
    if (fd < 0) { freeaddrinfo(res); return -1; }

    // Set non-blocking for connect-with-timeout
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int cr = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);

    if (cr == 0) {
        // Connected immediately
        fcntl(fd, F_SETFL, flags); // restore blocking
        return fd;
    }
    if (errno != EINPROGRESS) { close(fd); return -1; }

    // Wait for writable (connected)
    fd_set wfds; FD_ZERO(&wfds); FD_SET(fd, &wfds);
    struct timeval tv{ timeoutSec, 0 };
    int sel = select(fd + 1, nullptr, &wfds, nullptr, &tv);
    if (sel <= 0) { close(fd); return -1; }

    int err = 0; socklen_t errLen = sizeof(err);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen);
    if (err != 0) { close(fd); return -1; }

    fcntl(fd, F_SETFL, flags); // restore blocking
    return fd;
}

// Send all bytes on an already-connected socket. Returns true on success.
static bool tcpSendAll(int fd, const uint8_t* data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, data + sent, len - sent, MSG_NOSIGNAL);
        if (n < 0) return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

// Build a PrintResult with success + job id string.
static PrintResult okResult(const std::string& jobId = "") {
    static std::string jid; jid = jobId;
    return PrintResult{1, jid.c_str(), "", ""};
}
static PrintResult errResult(const std::string& msg, const std::string& code = "PRINT_ERROR") {
    static std::string m, c; m = msg; c = code;
    return PrintResult{0, "", m.c_str(), c.c_str()};
}

// CUPS option builder from PrintSettings
static void addCupsOptions(const PrintSettings& s, int& numOpts, cups_option_t*& opts) {
    if (s.copies > 1)
        numOpts = cupsAddOption("copies", std::to_string(s.copies).c_str(), numOpts, &opts);
    if (s.duplex)
        numOpts = cupsAddOption("sides", "two-sided-long-edge", numOpts, &opts);
    if (!s.color)
        numOpts = cupsAddOption("ColorModel", "Gray", numOpts, &opts);
    if (s.collate)
        numOpts = cupsAddOption("Collate", "True", numOpts, &opts);
    if (s.quality == PRINTQUALITY_DRAFT)
        numOpts = cupsAddOption("print-quality", "3", numOpts, &opts);
    else if (s.quality == PRINTQUALITY_HIGH || s.quality == PRINTQUALITY_BEST)
        numOpts = cupsAddOption("print-quality", "5", numOpts, &opts);
    if (s.inputTray && s.inputTray[0])
        numOpts = cupsAddOption("InputSlot", s.inputTray, numOpts, &opts);
    // Page range
    if (s.pageRangeFrom > 0 && s.pageRangeTo >= s.pageRangeFrom) {
        std::string range = std::to_string(s.pageRangeFrom) + "-" + std::to_string(s.pageRangeTo);
        numOpts = cupsAddOption("page-ranges", range.c_str(), numOpts, &opts);
    }
}

// ── Active raw-print cancellation flag ───────────────────────────────────────
static std::atomic<int> g_rawFd{-1};

// ── Implementation ────────────────────────────────────────────────────────────

class HybridNitroPrintingImpl final : public HybridNitroPrinting {
public:

    // ── Synchronous quick-lookup ──────────────────────────────────────────────

    bool isPrintingSupported() override { return true; }

    int64_t getPrintersCount() override {
        cups_dest_t* dests = nullptr;
        int n = cupsGetDests(&dests);
        cupsFreeDests(n, dests);
        return static_cast<int64_t>(n);
    }

    NitroCppBuffer getAllPrinters() override {
        cups_dest_t* dests = nullptr;
        int n = cupsGetDests(&dests);

        // Wire format: [4-byte payload_len LE][4-byte count LE][per-item fields]
        // Per PrinterInfo field order: id, name, address (writeString), isDefault, isAvailable (writeBool).
        auto writeLE32 = [](std::vector<uint8_t>& v, int32_t val) {
            v.push_back(val & 0xFF); v.push_back((val >> 8) & 0xFF);
            v.push_back((val >> 16) & 0xFF); v.push_back((val >> 24) & 0xFF);
        };
        auto writeString = [&](std::vector<uint8_t>& v, const char* s) {
            const char* str = s ? s : "";
            int32_t len = static_cast<int32_t>(strlen(str));
            writeLE32(v, len);
            v.insert(v.end(), str, str + len);
        };

        std::vector<uint8_t> payload;
        writeLE32(payload, static_cast<int32_t>(n)); // item count

        for (int i = 0; i < n; ++i) {
            cups_dest_t& d = dests[i];
            const char* name = d.name ? d.name : "";
            const char* uriOpt = cupsGetOption("device-uri", d.num_options, d.options);
            const char* uri = uriOpt ? uriOpt : "";
            const char* stateStr = cupsGetOption("printer-state", d.num_options, d.options);
            bool avail = stateStr ? (atoi(stateStr) != 5) : true;
            writeString(payload, name);        // id
            writeString(payload, name);        // name
            writeString(payload, uri);         // address
            payload.push_back(d.is_default ? 1 : 0); // isDefault
            payload.push_back(avail ? 1 : 0);         // isAvailable
        }
        cupsFreeDests(n, dests);

        int32_t payloadLen = static_cast<int32_t>(payload.size());
        uint8_t* buf = static_cast<uint8_t*>(malloc(4 + payloadLen));
        // Prepend 4-byte payload length
        buf[0] = payloadLen & 0xFF; buf[1] = (payloadLen >> 8) & 0xFF;
        buf[2] = (payloadLen >> 16) & 0xFF; buf[3] = (payloadLen >> 24) & 0xFF;
        memcpy(buf + 4, payload.data(), payloadLen);
        return NitroCppBuffer{buf, static_cast<size_t>(4 + payloadLen)};
    }

    PrinterInfo getPrinterAt(int64_t index) override {
        cups_dest_t* dests = nullptr;
        int n = cupsGetDests(&dests);
        if (index < 0 || index >= n) {
            cupsFreeDests(n, dests);
            throw std::out_of_range("Printer index out of range");
        }
        cups_dest_t& d = dests[index];
        static std::string name, uri;
        name = d.name ? d.name : "";
        const char* uriOpt = cupsGetOption("device-uri", d.num_options, d.options);
        uri = uriOpt ? uriOpt : "";
        bool isDefault = d.is_default != 0;
        const char* stateStr = cupsGetOption("printer-state", d.num_options, d.options);
        bool isAvail = stateStr ? (atoi(stateStr) != 5) : true;
        cupsFreeDests(n, dests);
        return PrinterInfo{name.c_str(), name.c_str(), uri.c_str(),
                           static_cast<int8_t>(isDefault), static_cast<int8_t>(isAvail)};
    }

    PrinterInfo getDefaultPrinter() override {
        const char* defName = cupsGetDefault();
        static std::string name, uri;
        name = defName ? defName : "";
        uri  = "";
        if (!name.empty()) {
            cups_dest_t* dests = nullptr;
            int n = cupsGetDests(&dests);
            cups_dest_t* d = cupsGetDest(name.c_str(), nullptr, n, dests);
            if (d) {
                const char* u = cupsGetOption("device-uri", d->num_options, d->options);
                if (u) uri = u;
            }
            cupsFreeDests(n, dests);
        }
        return PrinterInfo{name.c_str(), name.c_str(), uri.c_str(), 1, 1};
    }

    std::string getPrinterDriverVersion(const std::string& printerId) override {
        // Read PPD NickName as driver version
        const char* ppdFile = cupsGetPPD(printerId.c_str());
        if (!ppdFile) return "";
        ppd_file_t* ppd = ppdOpenFile(ppdFile);
        unlink(ppdFile);
        if (!ppd) return "";
        std::string version = ppd->nickname ? ppd->nickname : "";
        ppdClose(ppd);
        return version;
    }

    PrinterCapabilities getPrinterCapabilities(const std::string& printerId) override {
        PrinterCapabilities caps{};
        // Defaults
        caps.supportsColor      = 1;
        caps.supportsDuplex     = 0;
        caps.supportsCopy       = 1;
        caps.maxCopies          = 99;
        caps.maxResolutionDpi   = 600;
        caps.supportsA4         = 1;
        caps.supportsA5         = 1;
        caps.supportsLetter     = 1;
        caps.supportsLegal      = 1;
        caps.supportsDraftQuality  = 1;
        caps.supportsNormalQuality = 1;
        caps.supportsHighQuality   = 1;
        caps.supportsBestQuality   = 1;
        caps.supportsCustomPaper   = 0;
        caps.supportsBorderless    = 0;
        caps.inputTrays            = "";

        const char* ppdFile = cupsGetPPD(printerId.c_str());
        if (!ppdFile) return caps;
        ppd_file_t* ppd = ppdOpenFile(ppdFile);
        unlink(ppdFile);
        if (!ppd) return caps;

        // Color
        ppd_option_t* colorOpt = ppdFindOption(ppd, "ColorModel");
        caps.supportsColor = (colorOpt && colorOpt->num_choices > 1) ? 1 : 0;

        // Duplex
        ppd_option_t* duplexOpt = ppdFindOption(ppd, "Duplex");
        caps.supportsDuplex = (duplexOpt && duplexOpt->num_choices > 1) ? 1 : 0;

        // Paper sizes — scan ppd->sizes
        static std::string trays;
        trays.clear();
        for (int i = 0; i < ppd->num_sizes; ++i) {
            const char* pname = ppd->sizes[i].name;
            if (!pname) continue;
            std::string pn = pname;
            std::transform(pn.begin(), pn.end(), pn.begin(), ::tolower);
            if (pn.find("a4")     != std::string::npos) caps.supportsA4     = 1;
            if (pn.find("a5")     != std::string::npos) caps.supportsA5     = 1;
            if (pn.find("letter") != std::string::npos) caps.supportsLetter = 1;
            if (pn.find("legal")  != std::string::npos) caps.supportsLegal  = 1;
        }

        // Input trays from InputSlot option
        ppd_option_t* trayOpt = ppdFindOption(ppd, "InputSlot");
        if (trayOpt) {
            for (int i = 0; i < trayOpt->num_choices; ++i) {
                if (!trays.empty()) trays += ",";
                trays += trayOpt->choices[i].text;
            }
        }
        caps.inputTrays = trays.c_str();

        ppdClose(ppd);
        return caps;
    }

    // ── Print operations ──────────────────────────────────────────────────────

    PrintResult printText(const std::string& text, const PrintSettings& s) override {
        const uint8_t* data = reinterpret_cast<const uint8_t*>(text.c_str());
        return printBytesViaCups(data, text.size(), ".txt", s);
    }

    PrintResult printImage(const uint8_t* data, size_t len, const PrintSettings& s) override {
        const char* ext = ".png";
        if (len >= 2 && data[0] == 0xFF && data[1] == 0xD8) ext = ".jpg";
        else if (len >= 4 && data[0] == 0x47 && data[1] == 0x49) ext = ".gif";
        return printBytesViaCups(data, len, ext, s);
    }

    PrintResult printPdf(const uint8_t* data, size_t len, const PrintSettings& s) override {
        return printBytesViaCups(data, len, ".pdf", s);
    }

    PrintResult printDocument(const PrintDocument& doc, const PrintSettings& s) override {
        switch (doc.type) {
            case DOCUMENTTYPE_PLAIN_TEXT:
                return printText(std::string(doc.data, doc.data + doc.dataLength), s);
            case DOCUMENTTYPE_HTML: {
                // Strip HTML tags to plain text
                std::string plain;
                bool inTag = false;
                for (int64_t i = 0; i < doc.dataLength; ++i) {
                    char c = static_cast<char>(doc.data[i]);
                    if (c == '<') { inTag = true; continue; }
                    if (c == '>') { inTag = false; continue; }
                    if (!inTag) plain += c;
                }
                return printText(plain, s);
            }
            case DOCUMENTTYPE_PDF:
                return printPdf(doc.data, static_cast<size_t>(doc.dataLength), s);
            case DOCUMENTTYPE_IMAGE:
                return printImage(doc.data, static_cast<size_t>(doc.dataLength), s);
            default:
                return errResult("Unknown document type", "UNKNOWN_TYPE");
        }
    }

    bool printFile(const std::string& filePath, const PrintSettings& s) override {
        std::string pid = printerIdOrDefault(s.printerId);
        if (pid.empty()) return false;
        int numOpts = 0; cups_option_t* opts = nullptr;
        addCupsOptions(s, numOpts, opts);
        std::string jobName = (s.jobName && s.jobName[0]) ? s.jobName : "Document";
        int jobId = cupsPrintFile(pid.c_str(), filePath.c_str(), jobName.c_str(), numOpts, opts);
        cupsFreeOptions(numOpts, opts);
        return jobId > 0;
    }

    PreviewResult renderPreview(const PrintDocument& doc, const PrintSettings& /*s*/) override {
        size_t len = static_cast<size_t>(doc.dataLength);
        uint8_t* buf = static_cast<uint8_t*>(malloc(len));
        if (buf && len > 0) memcpy(buf, doc.data, len);
        PreviewResult r{};
        r.bytes  = buf;
        r.length = static_cast<int64_t>(len);
        return r;
    }

    int64_t getPageCount(const PrintDocument& /*doc*/) override {
        // Page counting without a PDF library — return 1 as default.
        return 1;
    }

    bool printToFile(const PrintDocument& doc, const std::string& outputPath,
                     const PrintSettings& /*s*/) override {
        FILE* f = fopen(outputPath.c_str(), "wb");
        if (!f) return false;
        size_t written = fwrite(doc.data, 1, static_cast<size_t>(doc.dataLength), f);
        fclose(f);
        return written == static_cast<size_t>(doc.dataLength);
    }

    // ── Raw protocol printing ─────────────────────────────────────────────────

    PrintResult printRaw(const uint8_t* data, size_t len, const PrintSettings& s) override {
        return tcpRawPrint(data, len, s, 9100);
    }

    PrintResult printEscPos(const uint8_t* data, size_t len, const PrintSettings& s) override {
        return tcpRawPrint(data, len, s, 9100);
    }

    PrintResult printZpl(const std::string& zpl, const PrintSettings& s) override {
        return tcpRawPrint(
            reinterpret_cast<const uint8_t*>(zpl.c_str()), zpl.size(), s, 9100);
    }

    bool cancelRawPrint() override {
        int fd = g_rawFd.exchange(-1);
        if (fd < 0) return false;
        shutdown(fd, SHUT_RDWR);
        close(fd);
        return true;
    }

    // ── Job management ────────────────────────────────────────────────────────

    bool cancelPrintJob(const std::string& jobIdStr) override {
        int jobId = std::stoi(jobIdStr);
        std::string pid = printerIdOrDefault("");
        return cupsCancelJob(pid.c_str(), jobId) == 1;
    }

    bool pausePrintJob(const std::string& jobIdStr) override {
        int jobId = std::stoi(jobIdStr);
        // CUPS: hold the job
        std::string pid = printerIdOrDefault("");
        return cupsCancelJob2(CUPS_HTTP_DEFAULT, pid.c_str(), jobId, 1) == 1;
    }

    bool resumePrintJob(const std::string& jobIdStr) override {
        int jobId = std::stoi(jobIdStr);
        // CUPS: release the job
        std::string pid = printerIdOrDefault("");
        return cupsCancelJob2(CUPS_HTTP_DEFAULT, pid.c_str(), jobId, 0) == 1;
    }

    bool clearPrintQueue() override {
        // Cancel all active jobs for every printer
        cups_dest_t* dests = nullptr;
        int n = cupsGetDests(&dests);
        bool any = false;
        for (int i = 0; i < n; ++i) {
            const char* pname = dests[i].name;
            if (!pname) continue;
            cups_job_t* jobs = nullptr;
            int nj = cupsGetJobs(&jobs, pname, 0, CUPS_WHICHJOBS_ACTIVE);
            for (int j = 0; j < nj; ++j) {
                cupsCancelJob(pname, jobs[j].id);
                any = true;
            }
            cupsFreeJobs(nj, jobs);
        }
        cupsFreeDests(n, dests);
        return any;
    }

    int64_t getPrintJobsCount() override {
        cups_job_t* jobs = nullptr;
        int n = cupsGetJobs(&jobs, nullptr, 0, CUPS_WHICHJOBS_ACTIVE);
        cupsFreeJobs(n, jobs);
        return static_cast<int64_t>(n);
    }

    PrintJob getPrintJobAt(int64_t index) override {
        cups_job_t* jobs = nullptr;
        int n = cupsGetJobs(&jobs, nullptr, 0, CUPS_WHICHJOBS_ACTIVE);
        if (index < 0 || index >= n) {
            cupsFreeJobs(n, jobs);
            throw std::out_of_range("Job index out of range");
        }
        cups_job_t& j = jobs[index];
        static std::string jid, pid, title;
        jid   = std::to_string(j.id);
        pid   = j.dest ? j.dest : "";
        title = j.title ? j.title : "";
        PrintState state = cupsJobStateToEnum(j.state);
        int64_t createdMs = static_cast<int64_t>(j.creation_time) * 1000;
        int64_t completedMs = static_cast<int64_t>(j.completed_time) * 1000;
        PrintJob pj{};
        pj.id               = jid.c_str();
        pj.printerId        = pid.c_str();
        pj.documentTitle    = title.c_str();
        pj.state            = state;
        pj.progress         = 0;
        pj.createdAtMillis  = createdMs;
        pj.completedAtMillis= completedMs;
        pj.errorMessage     = "";
        pj.pagesPrinted     = 0;
        cupsFreeJobs(n, jobs);
        return pj;
    }

    PrintJob getPrintJobStatus(const std::string& jobIdStr) override {
        int jobId = std::stoi(jobIdStr);
        cups_job_t* jobs = nullptr;
        int n = cupsGetJobs(&jobs, nullptr, 0, CUPS_WHICHJOBS_ALL);
        for (int i = 0; i < n; ++i) {
            if (jobs[i].id != jobId) continue;
            cups_job_t& j = jobs[i];
            static std::string jid, pid, title;
            jid   = std::to_string(j.id);
            pid   = j.dest ? j.dest : "";
            title = j.title ? j.title : "";
            PrintState state = cupsJobStateToEnum(j.state);
            int64_t createdMs   = static_cast<int64_t>(j.creation_time) * 1000;
            int64_t completedMs = static_cast<int64_t>(j.completed_time) * 1000;
            PrintJob pj{};
            pj.id               = jid.c_str();
            pj.printerId        = pid.c_str();
            pj.documentTitle    = title.c_str();
            pj.state            = state;
            pj.progress         = 0;
            pj.createdAtMillis  = createdMs;
            pj.completedAtMillis= completedMs;
            pj.errorMessage     = "";
            pj.pagesPrinted     = 0;
            cupsFreeJobs(n, jobs);
            return pj;
        }
        cupsFreeJobs(n, jobs);
        throw std::runtime_error("Print job not found: " + jobIdStr);
    }

    // ── Discovery ─────────────────────────────────────────────────────────────

    bool startPrinterDiscovery() override {
        // cupsGetDests on modern CUPS already discovers Bonjour printers.
        cups_dest_t* dests = nullptr;
        int n = cupsGetDests(&dests);
        for (int i = 0; i < n; ++i) {
            cups_dest_t& d = dests[i];
            if (!d.name) continue;
            const char* uriOpt  = cupsGetOption("device-uri", d.num_options, d.options);
            const char* stateStr= cupsGetOption("printer-state", d.num_options, d.options);
            bool avail = stateStr ? (atoi(stateStr) != 5) : true;

            static std::string id, name, host, uri, svc;
            id   = d.name;
            name = d.name;
            uri  = uriOpt ? uriOpt : "";
            svc  = "_ipp._tcp";
            host = "";
            int port = 631;
            if (!uri.empty()) parseHostPort(uri, host, port);

            DiscoveredPrinter dp{};
            dp.id          = id.c_str();
            dp.name        = name.c_str();
            dp.host        = host.c_str();
            dp.port        = static_cast<int64_t>(port);
            dp.serviceType = svc.c_str();
            dp.uri         = uri.c_str();
            dp.isAvailable = static_cast<int8_t>(avail);
            emit_onPrinterDiscovered(dp);
        }
        cupsFreeDests(n, dests);
        return true;
    }

    bool stopPrinterDiscovery() override { return true; }

    // ── Connection / admin ────────────────────────────────────────────────────

    bool testPrinterConnection(const std::string& printerId, int64_t timeoutSeconds) override {
        std::string host;
        int port = 9100;
        parseHostPort(printerId, host, port);
        if (host.empty()) return false;
        int sec = timeoutSeconds > 0 ? static_cast<int>(timeoutSeconds) : 5;
        int fd = tcpConnect(host, port, sec);
        if (fd < 0) return false;
        close(fd);
        return true;
    }

    bool setDefaultPrinter(const std::string& printerId) override {
        // cupsSetDefault is not available in all public CUPS headers.
        // We write to ~/.cups/lpoptions by calling lpoptions.
        std::string cmd = "lpoptions -d \"" + printerId + "\"";
        return system(cmd.c_str()) == 0;
    }

    bool openSystemPrintQueue(const std::string& printerId) override {
        std::string url = "http://localhost:631/printers/";
        if (!printerId.empty()) url += printerId;
        std::string cmd = "xdg-open \"" + url + "\" &";
        return system(cmd.c_str()) == 0;
    }

    bool openPrinterProperties(const std::string& printerId) override {
        if (printerId.empty()) return false;
        std::string url = "http://localhost:631/printers/" + printerId;
        std::string cmd = "xdg-open \"" + url + "\" &";
        return system(cmd.c_str()) == 0;
    }

    // ── Detailed printer status via IPP ───────────────────────────────────────

    PrinterStatusDetail getPrinterStatusDetail(const std::string& printerId,
                                               int64_t timeoutSeconds) override {
        PrinterStatusDetail detail{};
        static std::string pidStr, stateStr, reasonsStr, msgStr, errStr;
        pidStr = printerId;
        stateStr = reasonsStr = msgStr = errStr = "";
        detail.printerId         = pidStr.c_str();
        detail.isOnline          = 0;
        detail.isReady           = 0;
        detail.inkLevelBlack     = -1;
        detail.inkLevelCyan      = -1;
        detail.inkLevelMagenta   = -1;
        detail.inkLevelYellow    = -1;
        detail.tonerLevel        = -1;
        detail.paperLevel        = -1;
        detail.printerState      = stateStr.c_str();
        detail.stateReasons      = reasonsStr.c_str();
        detail.statusMessage     = msgStr.c_str();
        detail.errorCode         = errStr.c_str();

        // Find the destination
        cups_dest_t* dests = nullptr;
        int nDests = cupsGetDests(&dests);
        cups_dest_t* dst = cupsGetDest(printerId.c_str(), nullptr, nDests, dests);
        if (!dst) {
            cupsFreeDests(nDests, dests);
            detail.errorCode = "PRINTER_NOT_FOUND";
            return detail;
        }

        int timeoutMs = timeoutSeconds > 0 ? static_cast<int>(timeoutSeconds * 1000) : 10000;
        http_t* http = cupsConnectDest(dst, CUPS_DEST_FLAGS_NONE,
                                        timeoutMs, nullptr, nullptr, 0, nullptr, nullptr);
        cupsFreeDests(nDests, dests);
        if (!http) {
            detail.errorCode = "CONNECTION_FAILED";
            return detail;
        }

        // Build Get-Printer-Attributes request
        ipp_t* req = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
        // Printer URI
        char uri[1024];
        httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri),
                         "ipp", nullptr, "localhost", 0,
                         "/printers/%s", printerId.c_str());
        ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nullptr, uri);

        // Requested attributes
        static const char* attrs[] = {
            "printer-state",
            "printer-state-reasons",
            "printer-state-message",
            "marker-levels",
            "marker-names",
            "marker-types",
            "printer-is-accepting-jobs",
            "queued-job-count",
            "color-supported",
            "sides-supported",
        };
        ippAddStrings(req, IPP_TAG_OPERATION, IPP_TAG_KEYWORD,
                      "requested-attributes",
                      static_cast<int>(sizeof(attrs)/sizeof(attrs[0])),
                      nullptr, attrs);

        ipp_t* resp = cupsDoRequest(http, req, "/");
        httpClose(http);

        if (!resp) return detail;

        // Parse printer-state
        ipp_attribute_t* attr = ippFindAttribute(resp, "printer-state", IPP_TAG_ENUM);
        if (attr) {
            int state = ippGetInteger(attr, 0);
            // IPP: 3=idle, 4=processing, 5=stopped
            if (state == 3) { stateStr = "idle";        detail.isOnline = 1; detail.isReady = 1; }
            else if (state == 4) { stateStr = "processing"; detail.isOnline = 1; }
            else if (state == 5) { stateStr = "stopped";    detail.isOnline = 0; }
        }

        // printer-state-reasons
        attr = ippFindAttribute(resp, "printer-state-reasons", IPP_TAG_KEYWORD);
        if (attr) {
            for (int i = 0; i < ippGetCount(attr); ++i) {
                if (!reasonsStr.empty()) reasonsStr += ",";
                const char* r = ippGetString(attr, i, nullptr);
                reasonsStr += r ? r : "";
                // Parse specific reasons
                if (r) {
                    if (strstr(r, "media-jam"))        detail.hasPaperJam   = 1;
                    if (strstr(r, "media-empty"))      detail.isOutOfPaper  = 1;
                    if (strstr(r, "media-needed"))     detail.isOutOfPaper  = 1;
                    if (strstr(r, "toner-empty"))      detail.isOutOfInk    = 1;
                    if (strstr(r, "ink-empty"))        detail.isOutOfInk    = 1;
                    if (strstr(r, "warming-up"))       detail.isWarmingUp   = 1;
                }
            }
        }

        // printer-state-message
        attr = ippFindAttribute(resp, "printer-state-message", IPP_TAG_TEXT);
        if (attr) { const char* m = ippGetString(attr, 0, nullptr); if (m) msgStr = m; }

        // marker-levels (ink/toner, 0-100, -1=unknown)
        ipp_attribute_t* levelsAttr = ippFindAttribute(resp, "marker-levels", IPP_TAG_INTEGER);
        ipp_attribute_t* namesAttr  = ippFindAttribute(resp, "marker-names",  IPP_TAG_NAME);
        ipp_attribute_t* typesAttr  = ippFindAttribute(resp, "marker-types",  IPP_TAG_KEYWORD);
        if (levelsAttr && namesAttr) {
            int cnt = ippGetCount(levelsAttr);
            for (int i = 0; i < cnt; ++i) {
                int level = ippGetInteger(levelsAttr, i);
                const char* mname = (namesAttr && i < ippGetCount(namesAttr))
                                    ? ippGetString(namesAttr, i, nullptr) : nullptr;
                const char* mtype = (typesAttr && i < ippGetCount(typesAttr))
                                    ? ippGetString(typesAttr, i, nullptr) : nullptr;
                if (!mname) mname = "";
                if (!mtype) mtype = "";
                std::string lname = mname;
                std::transform(lname.begin(), lname.end(), lname.begin(), ::tolower);
                if (strstr(mtype, "toner") || strstr(lname.c_str(), "toner")) {
                    if (strstr(lname.c_str(), "cyan"))    detail.inkLevelCyan    = level;
                    else if (strstr(lname.c_str(), "magenta")) detail.inkLevelMagenta = level;
                    else if (strstr(lname.c_str(), "yellow"))  detail.inkLevelYellow  = level;
                    else { detail.inkLevelBlack = level; detail.tonerLevel = level; }
                } else if (strstr(mtype, "ink") || strstr(lname.c_str(), "ink")) {
                    if (strstr(lname.c_str(), "cyan"))    detail.inkLevelCyan    = level;
                    else if (strstr(lname.c_str(), "magenta")) detail.inkLevelMagenta = level;
                    else if (strstr(lname.c_str(), "yellow"))  detail.inkLevelYellow  = level;
                    else                                       detail.inkLevelBlack   = level;
                } else if (strstr(mtype, "media") || strstr(lname.c_str(), "paper")) {
                    detail.paperLevel = level;
                }
            }
        }

        // queued-job-count
        attr = ippFindAttribute(resp, "queued-job-count", IPP_TAG_INTEGER);
        if (attr) detail.jobsInQueue = ippGetInteger(attr, 0);

        // color-supported
        attr = ippFindAttribute(resp, "color-supported", IPP_TAG_BOOLEAN);
        if (attr) detail.isColorSupported = ippGetBoolean(attr, 0) ? 1 : 0;

        // sides-supported → duplex
        attr = ippFindAttribute(resp, "sides-supported", IPP_TAG_KEYWORD);
        if (attr) {
            for (int i = 0; i < ippGetCount(attr); ++i) {
                const char* sv = ippGetString(attr, i, nullptr);
                if (sv && strstr(sv, "two-sided")) { detail.isDuplexSupported = 1; break; }
            }
        }

        ippDelete(resp);

        // Commit static strings
        detail.printerState  = stateStr.c_str();
        detail.stateReasons  = reasonsStr.c_str();
        detail.statusMessage = msgStr.c_str();
        detail.errorCode     = errStr.c_str();
        return detail;
    }

private:

    // ── CUPS print from bytes ─────────────────────────────────────────────────

    PrintResult printBytesViaCups(const uint8_t* data, size_t len,
                                   const char* suffix, const PrintSettings& s) {
        std::string pid = printerIdOrDefault(s.printerId);
        if (pid.empty()) return errResult("No printer available", "NO_PRINTER");

        std::string tmp = writeTempFile(data, len, suffix);
        if (tmp.empty()) return errResult("Failed to write temp file", "IO_ERROR");

        int numOpts = 0; cups_option_t* opts = nullptr;
        addCupsOptions(s, numOpts, opts);
        std::string jobName = (s.jobName && s.jobName[0]) ? s.jobName : "Document";
        int jobId = cupsPrintFile(pid.c_str(), tmp.c_str(), jobName.c_str(), numOpts, opts);
        cupsFreeOptions(numOpts, opts);
        unlink(tmp.c_str());

        if (jobId <= 0) return errResult(cupsLastErrorString(), "CUPS_ERROR");
        return okResult(std::to_string(jobId));
    }

    // ── TCP raw print ─────────────────────────────────────────────────────────

    PrintResult tcpRawPrint(const uint8_t* data, size_t len,
                             const PrintSettings& s, int defaultPort) {
        std::string host;
        int port = defaultPort;
        std::string pid = s.printerId ? s.printerId : "";

        // If printerId looks like a plain name (no ':' or '//'), fall back to CUPS spooler RAW.
        if (pid.find(':') == std::string::npos && pid.find("://") == std::string::npos) {
            return printBytesViaCups(data, len, ".raw", s);
        }

        parseHostPort(pid, host, port);
        if (host.empty()) return errResult("Cannot parse host from printerId", "BAD_URI");

        int sec = (s.networkTimeoutSeconds > 0)
                  ? static_cast<int>(s.networkTimeoutSeconds) : 10;
        int fd = tcpConnect(host, port, sec);
        if (fd < 0) return errResult("TCP connect failed to " + host + ":" + std::to_string(port),
                                      "CONNECT_FAILED");
        g_rawFd.store(fd);
        bool ok = tcpSendAll(fd, data, len);
        g_rawFd.store(-1);
        close(fd);
        return ok ? okResult() : errResult("TCP send failed", "SEND_FAILED");
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    std::string printerIdOrDefault(const char* pid) {
        if (pid && pid[0]) return pid;
        const char* def = cupsGetDefault();
        return def ? def : "";
    }
    std::string printerIdOrDefault(const std::string& pid) {
        return printerIdOrDefault(pid.empty() ? nullptr : pid.c_str());
    }

    static PrintState cupsJobStateToEnum(ipp_jstate_t state) {
        switch (state) {
            case IPP_JSTATE_PENDING:   return PRINTSTATE_IDLE;
            case IPP_JSTATE_HELD:      return PRINTSTATE_PAUSED;
            case IPP_JSTATE_PROCESSING:return PRINTSTATE_PRINTING;
            case IPP_JSTATE_STOPPED:   return PRINTSTATE_PAUSED;
            case IPP_JSTATE_CANCELED:  return PRINTSTATE_CANCELLED;
            case IPP_JSTATE_ABORTED:   return PRINTSTATE_FAILED;
            case IPP_JSTATE_COMPLETED: return PRINTSTATE_COMPLETED;
            default:                   return PRINTSTATE_IDLE;
        }
    }
};

// ── Auto-registration ─────────────────────────────────────────────────────────

namespace {
    struct _AutoRegister {
        HybridNitroPrintingImpl impl;
        _AutoRegister()  { nitro_printing_register_impl(&impl); }
        ~_AutoRegister() { nitro_printing_register_impl(nullptr); }
    };
    static _AutoRegister _instance;
}
