// Windows printing implementation for nitro_printing.
//
// Dialog mode  (showPrintDialog=true):  ShellExecuteEx "print" verb via a temp file.
// Silent mode  (showPrintDialog=false): Windows Print Spooler (WritePrinter) with
//                                       the printer named in settings.printerId.
//
// Printer enumeration uses PRINTER_INFO_4W (level 4 — read-only/name-only;
// level 2 gives address/port but requires higher privilege).
//
// Discovery emits local/network printers via EnumPrintersW — no mDNS on Windows
// without third-party libraries.

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <winspool.h>
#include <wingdi.h>
#include <shellapi.h>
#include <ws2tcpip.h>
#include <string>
#include <vector>
#include <stdexcept>
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include "../../lib/src/generated/cpp/nitro_printing.native.g.h"

#pragma comment(lib, "winspool.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ws2_32.lib")

// ── String helpers ────────────────────────────────────────────────────────────

static std::wstring utf8_to_wstr(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    std::wstring w(n - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
    return w;
}

static std::string wstr_to_utf8(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string s(n - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], n, nullptr, nullptr);
    return s;
}

// ── Printer enumeration helper ────────────────────────────────────────────────

struct PrinterEntry { std::wstring name; std::string address; };

static std::vector<PrinterEntry> enumPrinters() {
    DWORD needed = 0, returned = 0;
    EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr,
                  4, nullptr, 0, &needed, &returned);
    if (needed == 0) return {};
    std::vector<BYTE> buf(needed);
    if (!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr,
                       4, buf.data(), needed, &needed, &returned)) return {};
    std::vector<PrinterEntry> out;
    auto* infos = reinterpret_cast<PRINTER_INFO_4W*>(buf.data());
    for (DWORD i = 0; i < returned; ++i) {
        PrinterEntry e;
        e.name = infos[i].pPrinterName ? infos[i].pPrinterName : L"";
        out.push_back(e);
    }
    return out;
}

static std::wstring defaultPrinterName() {
    DWORD sz = 0;
    GetDefaultPrinterW(nullptr, &sz);
    if (sz == 0) return {};
    std::wstring name(sz, L'\0');
    GetDefaultPrinterW(&name[0], &sz);
    if (!name.empty() && name.back() == L'\0') name.pop_back();
    return name;
}

// ── Shell helper ──────────────────────────────────────────────────────────────

static bool runCmd(const std::string& exe, const std::string& args) {
    SHELLEXECUTEINFOA sei{};
    sei.cbSize    = sizeof(sei);
    sei.fMask     = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    sei.lpVerb    = "open";
    sei.lpFile    = exe.c_str();
    sei.lpParameters = args.c_str();
    sei.nShow     = SW_HIDE;
    if (!ShellExecuteExA(&sei)) return false;
    if (sei.hProcess) { WaitForSingleObject(sei.hProcess, 10'000); CloseHandle(sei.hProcess); }
    return true;
}

// ── Winsock initializer ───────────────────────────────────────────────────────

struct WsaInit {
    WsaInit()  { WSADATA d{}; WSAStartup(MAKEWORD(2,2), &d); }
    ~WsaInit() { WSACleanup(); }
};
static WsaInit _wsaInit;

// Active raw-print socket (for cancelRawPrint)
static std::atomic<SOCKET> g_rawSocket{INVALID_SOCKET};

// Build a PrintResult
static PrintResult okResult(const std::string& jobId = "") {
    static std::string jid; jid = jobId;
    return PrintResult{1, jid.c_str(), "", ""};
}
static PrintResult errResult(const std::string& msg, const std::string& code = "PRINT_ERROR") {
    static std::string m, c; m = msg; c = code;
    return PrintResult{0, "", m.c_str(), c.c_str()};
}

// ── Implementation ────────────────────────────────────────────────────────────

class HybridNitroPrintingImpl final : public HybridNitroPrinting {
public:

    // Synchronous quick-lookup

    bool isPrintingSupported() override { return true; }

    int64_t getPrintersCount() override {
        return static_cast<int64_t>(enumPrinters().size());
    }

    NitroCppBuffer getAllPrinters() override {
        auto list = enumPrinters();
        std::wstring defName = defaultPrinterName();

        // Wire format: [4-byte payload_len LE][4-byte count LE][per-item fields]
        // Per PrinterInfo field order: id, name, address (writeString), isDefault, isAvailable (writeBool).
        auto writeLE32 = [](std::vector<uint8_t>& v, int32_t val) {
            v.push_back(val & 0xFF); v.push_back((val >> 8) & 0xFF);
            v.push_back((val >> 16) & 0xFF); v.push_back((val >> 24) & 0xFF);
        };
        auto writeString = [&](std::vector<uint8_t>& v, const std::string& s) {
            int32_t len = static_cast<int32_t>(s.size());
            writeLE32(v, len);
            v.insert(v.end(), s.begin(), s.end());
        };

        std::vector<uint8_t> payload;
        writeLE32(payload, static_cast<int32_t>(list.size()));

        for (const auto& e : list) {
            std::string name = wstr_to_utf8(e.name);
            bool isDefault = (e.name == defName);
            writeString(payload, name);           // id
            writeString(payload, name);           // name
            writeString(payload, e.address);      // address
            payload.push_back(isDefault ? 1 : 0); // isDefault
            payload.push_back(1);                  // isAvailable
        }

        int32_t payloadLen = static_cast<int32_t>(payload.size());
        uint8_t* buf = static_cast<uint8_t*>(malloc(4 + payloadLen));
        buf[0] = payloadLen & 0xFF; buf[1] = (payloadLen >> 8) & 0xFF;
        buf[2] = (payloadLen >> 16) & 0xFF; buf[3] = (payloadLen >> 24) & 0xFF;
        memcpy(buf + 4, payload.data(), payloadLen);
        return NitroCppBuffer{buf, static_cast<size_t>(4 + payloadLen)};
    }

    PrinterInfo getPrinterAt(int64_t index) override {
        auto list = enumPrinters();
        if (index < 0 || index >= static_cast<int64_t>(list.size()))
            throw std::out_of_range("Printer index out of range");
        auto& e = list[static_cast<size_t>(index)];
        auto name = wstr_to_utf8(e.name);
        bool isDefault = (e.name == defaultPrinterName());
        return PrinterInfo{name.c_str(), name.c_str(), e.address.c_str(), isDefault, true};
    }

    PrinterInfo getDefaultPrinter() override {
        auto wname = defaultPrinterName();
        auto name  = wstr_to_utf8(wname);
        return PrinterInfo{name.c_str(), name.c_str(), "", true, true};
    }

    std::string getPrinterDriverVersion(const std::string& id) override {
        HANDLE hp = nullptr;
        auto wid = utf8_to_wstr(id);
        if (!OpenPrinterW(wid.data(), &hp, nullptr)) return "";
        DWORD needed = 0;
        GetPrinterDriverW(hp, nullptr, 3, nullptr, 0, &needed);
        std::vector<BYTE> buf(needed);
        std::string version;
        if (GetPrinterDriverW(hp, nullptr, 3, buf.data(), needed, &needed)) {
            auto* d = reinterpret_cast<DRIVER_INFO_3W*>(buf.data());
            if (d->pDriverPath) version = wstr_to_utf8(d->pDriverPath);
        }
        ClosePrinter(hp);
        return version;
    }

    PrinterCapabilities getPrinterCapabilities(const std::string& printerId) override {
        PrinterCapabilities caps{};
        // Safe defaults
        caps.supportsColor         = 1;
        caps.supportsDuplex        = 0;
        caps.supportsCopy          = 1;
        caps.maxCopies             = 99;
        caps.maxResolutionDpi      = 600;
        caps.supportsA4            = 1;
        caps.supportsA5            = 1;
        caps.supportsLetter        = 1;
        caps.supportsLegal         = 1;
        caps.supportsDraftQuality  = 1;
        caps.supportsNormalQuality = 1;
        caps.supportsHighQuality   = 1;
        caps.supportsBestQuality   = 1;
        caps.supportsCustomPaper   = 0;
        caps.supportsBorderless    = 0;
        caps.inputTrays            = "";

        if (printerId.empty()) return caps;
        auto wid = utf8_to_wstr(printerId);

        // Need port name for DeviceCapabilities
        HANDLE hp = nullptr;
        if (!OpenPrinterW(wid.data(), &hp, nullptr)) return caps;
        DWORD needed = 0;
        GetPrinterW(hp, 2, nullptr, 0, &needed);
        std::vector<BYTE> buf(needed);
        if (!GetPrinterW(hp, 2, buf.data(), needed, &needed)) { ClosePrinter(hp); return caps; }
        ClosePrinter(hp);
        auto* pi2 = reinterpret_cast<PRINTER_INFO_2W*>(buf.data());
        const wchar_t* port = pi2->pPortName;
        if (!port) return caps;

        // Color
        caps.supportsColor = (DeviceCapabilitiesW(wid.c_str(), port, DC_COLORDEVICE, nullptr, nullptr) == 1) ? 1 : 0;

        // Duplex
        caps.supportsDuplex = (DeviceCapabilitiesW(wid.c_str(), port, DC_DUPLEX, nullptr, nullptr) == 1) ? 1 : 0;

        // Max copies
        long maxCopies = DeviceCapabilitiesW(wid.c_str(), port, DC_COPIES, nullptr, nullptr);
        if (maxCopies > 0) caps.maxCopies = static_cast<int64_t>(maxCopies);

        // Resolution
        long numRes = DeviceCapabilitiesW(wid.c_str(), port, DC_ENUMRESOLUTIONS, nullptr, nullptr);
        if (numRes > 0) {
            std::vector<LONG> resBuf(numRes * 2);
            DeviceCapabilitiesW(wid.c_str(), port, DC_ENUMRESOLUTIONS,
                                reinterpret_cast<LPWSTR>(resBuf.data()), nullptr);
            LONG maxDpi = 0;
            for (long i = 0; i < numRes; ++i) maxDpi = max(maxDpi, max(resBuf[i*2], resBuf[i*2+1]));
            caps.maxResolutionDpi = static_cast<int64_t>(maxDpi);
        }

        // Paper sizes
        long numPapers = DeviceCapabilitiesW(wid.c_str(), port, DC_PAPERS, nullptr, nullptr);
        if (numPapers > 0) {
            std::vector<WORD> papers(numPapers);
            DeviceCapabilitiesW(wid.c_str(), port, DC_PAPERS,
                                reinterpret_cast<LPWSTR>(papers.data()), nullptr);
            // DMPAPER_A4=9, A5=11, LETTER=1, LEGAL=5
            for (long i = 0; i < numPapers; ++i) {
                if (papers[i] == DMPAPER_A4)     caps.supportsA4     = 1;
                if (papers[i] == DMPAPER_A5)     caps.supportsA5     = 1;
                if (papers[i] == DMPAPER_LETTER) caps.supportsLetter = 1;
                if (papers[i] == DMPAPER_LEGAL)  caps.supportsLegal  = 1;
            }
        }

        // Paper bins → inputTrays
        static std::string trays;
        trays.clear();
        long numBins = DeviceCapabilitiesW(wid.c_str(), port, DC_BINNAMES, nullptr, nullptr);
        if (numBins > 0) {
            // Each bin name is 24 wchars
            std::vector<wchar_t> binNames(static_cast<size_t>(numBins) * 24, L'\0');
            DeviceCapabilitiesW(wid.c_str(), port, DC_BINNAMES,
                                reinterpret_cast<LPWSTR>(binNames.data()), nullptr);
            for (long i = 0; i < numBins; ++i) {
                std::wstring binW(binNames.data() + i * 24, 24);
                // Trim null chars
                binW.erase(std::find(binW.begin(), binW.end(), L'\0'), binW.end());
                if (!binW.empty()) {
                    if (!trays.empty()) trays += ",";
                    trays += wstr_to_utf8(binW);
                }
            }
        }
        caps.inputTrays = trays.c_str();
        return caps;
    }

    // ── Print methods ─────────────────────────────────────────────────────────

    PrintResult printText(const std::string& text, const PrintSettings& s) override {
        // Silent direct mode: use GDI TextOut on a printer DC.
        if (!s.showPrintDialog && s.printerId && s.printerId[0] != '\0') {
            return gdiPrintText(text, s);
        }
        // Dialog mode: fall through to shell-print via temp file.
        return printBytes(reinterpret_cast<const uint8_t*>(text.c_str()),
                          text.size(), ".txt", "text/plain", s);
    }

    PrintResult printImage(const uint8_t* data, size_t len, const PrintSettings& s) override {
        const char* ext = ".png";
        if (len >= 2 && data[0] == 0xFF && data[1] == 0xD8) ext = ".jpg";
        return printBytes(data, len, ext, "image/*", s);
    }

    PrintResult printPdf(const uint8_t* data, size_t len, const PrintSettings& s) override {
        return printBytes(data, len, ".pdf", "application/pdf", s);
    }

    PrintResult printDocument(const PrintDocument& doc, const PrintSettings& s) override {
        switch (doc.type) {
            case DOCUMENTTYPE_PLAIN_TEXT:
                return printText(std::string(doc.data, doc.data + doc.dataLength), s);
            case DOCUMENTTYPE_HTML: {
                std::string html(doc.data, doc.data + doc.dataLength);
                std::string plain; bool inTag = false;
                for (char c : html) {
                    if (c == '<') { inTag = true; continue; }
                    if (c == '>') { inTag = false; continue; }
                    if (!inTag) plain += c;
                }
                return printText(plain, s);
            }
            case DOCUMENTTYPE_PDF:   return printPdf(doc.data, doc.dataLength, s);
            case DOCUMENTTYPE_IMAGE: return printImage(doc.data, doc.dataLength, s);
            default: return PrintResult{false, "", "Unknown document type", "UNKNOWN_TYPE"};
        }
    }

    bool printFile(const std::string& filePath, const PrintSettings& s) override {
        HANDLE hFile = CreateFileA(filePath.c_str(), GENERIC_READ, FILE_SHARE_READ,
                                    nullptr, OPEN_EXISTING, 0, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) return false;
        LARGE_INTEGER sz{};
        GetFileSizeEx(hFile, &sz);
        std::vector<uint8_t> data(static_cast<size_t>(sz.QuadPart));
        DWORD read = 0;
        ReadFile(hFile, data.data(), static_cast<DWORD>(data.size()), &read, nullptr);
        CloseHandle(hFile);

        size_t dot = filePath.rfind('.');
        std::string ext = dot != std::string::npos ? filePath.substr(dot) : "";
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

        PrintResult r{false, "", "", ""};
        if      (ext == ".pdf") r = printPdf(data.data(), data.size(), s);
        else if (ext==".jpg"||ext==".jpeg"||ext==".png"||ext==".bmp") r = printImage(data.data(), data.size(), s);
        else    r = printText(std::string(data.begin(), data.end()), s);
        return r.success;
    }

    // ── Export / Virtual print ────────────────────────────────────────────────

    PreviewResult renderPreview(const PrintDocument& doc, const PrintSettings& s) override {
        // For PDF, return the data as-is. Other types returned as raw bytes.
        // Malloc so the pointer outlives this stack frame; Dart owns the view.
        size_t len = doc.dataLength;
        uint8_t* buf = static_cast<uint8_t*>(malloc(len));
        if (buf && len > 0) memcpy(buf, doc.data, len);
        PreviewResult r{};
        r.bytes  = buf;
        r.length = static_cast<int64_t>(len);
        return r;
    }

    int64_t getPageCount(const PrintDocument& doc) override {
        return 1; // No PDF library available on Windows without additional deps
    }

    bool printToFile(const PrintDocument& doc, const std::string& outputPath,
                     const PrintSettings& /*s*/) override {
        // For PDF, write directly. For others, write the raw bytes.
        HANDLE hf = CreateFileA(outputPath.c_str(), GENERIC_WRITE, 0,
                                 nullptr, CREATE_ALWAYS, 0, nullptr);
        if (hf == INVALID_HANDLE_VALUE) return false;
        DWORD written = 0;
        bool ok = WriteFile(hf, doc.data, static_cast<DWORD>(doc.dataLength),
                            &written, nullptr) != 0;
        CloseHandle(hf);
        return ok && written == doc.dataLength;
    }

    // ── Job management ────────────────────────────────────────────────────────

    bool cancelPrintJob(const std::string& jobIdStr) override {
        DWORD jobId = static_cast<DWORD>(std::stoul(jobIdStr));
        auto wname = defaultPrinterName();
        if (wname.empty()) return false;
        HANDLE hp = nullptr;
        if (!OpenPrinterW(wname.data(), &hp, nullptr)) return false;
        bool ok = SetJobW(hp, jobId, 0, nullptr, JOB_CONTROL_DELETE) != 0;
        ClosePrinter(hp);
        return ok;
    }

    bool pausePrintJob(const std::string& jobIdStr) override {
        return setJobControl(jobIdStr, JOB_CONTROL_PAUSE);
    }

    bool resumePrintJob(const std::string& jobIdStr) override {
        return setJobControl(jobIdStr, JOB_CONTROL_RESUME);
    }

    bool clearPrintQueue() override {
        bool any = false;
        for (auto& e : enumPrinters()) {
            HANDLE hp = nullptr;
            if (!OpenPrinterW(e.name.data(), &hp, nullptr)) continue;
            DWORD needed = 0, returned = 0;
            EnumJobsW(hp, 0, 1000, 1, nullptr, 0, &needed, &returned);
            if (needed > 0) {
                std::vector<BYTE> buf(needed);
                if (EnumJobsW(hp, 0, 1000, 1, buf.data(), needed, &needed, &returned)) {
                    auto* jobs = reinterpret_cast<JOB_INFO_1W*>(buf.data());
                    for (DWORD i = 0; i < returned; ++i)
                        SetJobW(hp, jobs[i].JobId, 0, nullptr, JOB_CONTROL_DELETE);
                    any = true;
                }
            }
            ClosePrinter(hp);
        }
        return any;
    }

    int64_t getPrintJobsCount() override {
        DWORD total = 0;
        for (auto& e : enumPrinters()) {
            HANDLE hp = nullptr;
            if (!OpenPrinterW(e.name.data(), &hp, nullptr)) continue;
            DWORD n = 0, r = 0;
            EnumJobsW(hp, 0, 1000, 1, nullptr, 0, &n, &r);
            total += r;
            ClosePrinter(hp);
        }
        return static_cast<int64_t>(total);
    }

    PrintJob getPrintJobAt(int64_t index) override {
        int64_t flatIdx = 0;
        for (auto& e : enumPrinters()) {
            HANDLE hp = nullptr;
            if (!OpenPrinterW(e.name.data(), &hp, nullptr)) continue;
            DWORD needed = 0, returned = 0;
            EnumJobsW(hp, 0, 10000, 2, nullptr, 0, &needed, &returned);
            if (needed > 0) {
                std::vector<BYTE> buf(needed);
                if (EnumJobsW(hp, 0, 10000, 2, buf.data(), needed, &needed, &returned)) {
                    auto* jobs = reinterpret_cast<JOB_INFO_2W*>(buf.data());
                    for (DWORD j = 0; j < returned; ++j, ++flatIdx) {
                        if (flatIdx != index) continue;
                        static std::string jid, pid, title, errMsg;
                        jid   = std::to_string(jobs[j].JobId);
                        pid   = wstr_to_utf8(e.name);
                        title = jobs[j].pDocument ? wstr_to_utf8(jobs[j].pDocument) : "";
                        errMsg= jobs[j].pStatus   ? wstr_to_utf8(jobs[j].pStatus)   : "";
                        bool printing = (jobs[j].Status & JOB_STATUS_PRINTING) != 0;
                        bool paused   = (jobs[j].Status & JOB_STATUS_PAUSED)   != 0;
                        bool error    = (jobs[j].Status & JOB_STATUS_ERROR)     != 0;
                        bool complete = (jobs[j].Status & JOB_STATUS_COMPLETE)  != 0;
                        bool deleted  = (jobs[j].Status & JOB_STATUS_DELETED)   != 0;
                        PrintState state = PRINTSTATE_IDLE;
                        if (printing) state = PRINTSTATE_PRINTING;
                        else if (paused)  state = PRINTSTATE_PAUSED;
                        else if (error)   state = PRINTSTATE_FAILED;
                        else if (complete || deleted) state = PRINTSTATE_COMPLETED;
                        // Timestamps from SYSTEMTIME
                        auto toMs = [](const SYSTEMTIME& st) -> int64_t {
                            FILETIME ft{};
                            SystemTimeToFileTime(&st, &ft);
                            ULARGE_INTEGER ui{};
                            ui.LowPart  = ft.dwLowDateTime;
                            ui.HighPart = ft.dwHighDateTime;
                            // Windows epoch (Jan 1, 1601) to Unix epoch (Jan 1, 1970): 116444736000000000 100ns ticks
                            return static_cast<int64_t>((ui.QuadPart - 116444736000000000ULL) / 10000);
                        };
                        int64_t createdMs   = toMs(jobs[j].Submitted);
                        ClosePrinter(hp);
                        return PrintJob{
                            jid.c_str(), pid.c_str(), title.c_str(),
                            state, 0, createdMs, 0, errMsg.c_str(),
                            static_cast<int64_t>(jobs[j].PagesPrinted)
                        };
                    }
                }
            }
            ClosePrinter(hp);
        }
        throw std::out_of_range("Print job index out of range");
    }

    PrintJob getPrintJobStatus(const std::string& jobIdStr) override {
        DWORD jobId = static_cast<DWORD>(std::stoul(jobIdStr));
        for (auto& e : enumPrinters()) {
            HANDLE hp = nullptr;
            if (!OpenPrinterW(e.name.data(), &hp, nullptr)) continue;
            DWORD needed = 0;
            GetJobW(hp, jobId, 1, nullptr, 0, &needed);
            if (needed > 0) {
                std::vector<BYTE> buf(needed);
                if (GetJobW(hp, jobId, 1, buf.data(), needed, &needed)) {
                    auto* ji = reinterpret_cast<JOB_INFO_1W*>(buf.data());
                    std::string title = ji->pDocument ? wstr_to_utf8(ji->pDocument) : "";
                    std::string pid   = wstr_to_utf8(e.name);
                    bool printing = (ji->Status & JOB_STATUS_PRINTING) != 0;
                    ClosePrinter(hp);
                    return PrintJob{
                        jobIdStr.c_str(), pid.c_str(), title.c_str(),
                        printing ? PRINTSTATE_PRINTING : PRINTSTATE_IDLE,
                        0, 0, 0, "", 0
                    };
                }
            }
            ClosePrinter(hp);
        }
        throw std::runtime_error("Print job not found: " + jobIdStr);
    }

    PrinterStatusDetail getPrinterStatusDetail(const std::string& printerId,
                                               int64_t /*timeoutSeconds*/) override {
        PrinterStatusDetail detail{};
        static std::string pidStr, stateStr, reasonsStr, msgStr, errStr;
        pidStr = printerId;
        stateStr = reasonsStr = msgStr = errStr = "";
        detail.printerId    = pidStr.c_str();
        detail.printerState = stateStr.c_str();
        detail.stateReasons = reasonsStr.c_str();
        detail.statusMessage= msgStr.c_str();
        detail.errorCode    = errStr.c_str();
        detail.inkLevelBlack= -1;
        detail.inkLevelCyan = -1;
        detail.inkLevelMagenta = -1;
        detail.inkLevelYellow  = -1;
        detail.tonerLevel   = -1;
        detail.paperLevel   = -1;

        auto wid = utf8_to_wstr(printerId);
        HANDLE hp = nullptr;
        if (!OpenPrinterW(wid.data(), &hp, nullptr)) {
            errStr = "PRINTER_NOT_FOUND"; detail.errorCode = errStr.c_str(); return detail;
        }
        DWORD needed = 0;
        GetPrinterW(hp, 2, nullptr, 0, &needed);
        std::vector<BYTE> buf(needed);
        if (!GetPrinterW(hp, 2, buf.data(), needed, &needed)) {
            ClosePrinter(hp);
            errStr = "GET_PRINTER_FAILED"; detail.errorCode = errStr.c_str(); return detail;
        }
        ClosePrinter(hp);

        auto* pi2 = reinterpret_cast<PRINTER_INFO_2W*>(buf.data());
        DWORD status = pi2->Status;

        // Online = not offline and not error
        detail.isOnline  = ((status & PRINTER_STATUS_OFFLINE) == 0 &&
                            (status & PRINTER_STATUS_ERROR) == 0) ? 1 : 0;
        detail.isReady   = (status == 0) ? 1 : 0;
        detail.isWarmingUp = (status & PRINTER_STATUS_WARMING_UP) != 0 ? 1 : 0;
        detail.hasPaperJam   = (status & PRINTER_STATUS_PAPER_JAM)  != 0 ? 1 : 0;
        detail.isOutOfPaper  = (status & PRINTER_STATUS_PAPER_OUT)  != 0 ? 1 : 0;
        detail.isOutOfInk    = (status & PRINTER_STATUS_TONER_LOW)  != 0 ? 1 : 0;
        detail.jobsInQueue   = static_cast<int64_t>(pi2->cJobs);

        // State string
        if (status == 0)                              stateStr = "idle";
        else if (status & PRINTER_STATUS_PRINTING)    stateStr = "processing";
        else                                          stateStr = "stopped";
        detail.printerState = stateStr.c_str();

        // Collect reasons as comma-separated names
        struct { DWORD bit; const char* name; } reasons[] = {
            {PRINTER_STATUS_PAPER_JAM,      "media-jam"},
            {PRINTER_STATUS_PAPER_OUT,      "media-empty"},
            {PRINTER_STATUS_MANUAL_FEED,    "media-needed"},
            {PRINTER_STATUS_PAPER_PROBLEM,  "media-low"},
            {PRINTER_STATUS_OFFLINE,        "offline"},
            {PRINTER_STATUS_IO_ACTIVE,      "processing"},
            {PRINTER_STATUS_BUSY,           "busy"},
            {PRINTER_STATUS_OUTPUT_BIN_FULL,"output-area-full"},
            {PRINTER_STATUS_NOT_AVAILABLE,  "not-available"},
            {PRINTER_STATUS_WAITING,        "waiting"},
            {PRINTER_STATUS_PROCESSING,     "processing"},
            {PRINTER_STATUS_INITIALIZING,   "initializing"},
            {PRINTER_STATUS_WARMING_UP,     "warming-up"},
            {PRINTER_STATUS_TONER_LOW,      "toner-low"},
            {PRINTER_STATUS_NO_TONER,       "toner-empty"},
            {PRINTER_STATUS_PAGE_PUNT,      "page-punt"},
            {PRINTER_STATUS_USER_INTERVENTION, "door-open"},
            {PRINTER_STATUS_OUT_OF_MEMORY,  "spool-area-full"},
            {PRINTER_STATUS_DOOR_OPEN,      "door-open"},
            {PRINTER_STATUS_SERVER_UNKNOWN, "unknown"},
            {PRINTER_STATUS_POWER_SAVE,     "power-save"},
        };
        for (auto& r : reasons) {
            if (status & r.bit) {
                if (!reasonsStr.empty()) reasonsStr += ",";
                reasonsStr += r.name;
            }
        }
        detail.stateReasons = reasonsStr.c_str();

        // Status message from PRINTER_INFO_2
        if (pi2->pStatus) msgStr = wstr_to_utf8(pi2->pStatus);
        detail.statusMessage = msgStr.c_str();

        // Capabilities for color / duplex via DeviceCapabilities
        const wchar_t* port = pi2->pPortName;
        if (port) {
            detail.isColorSupported   = (DeviceCapabilitiesW(wid.c_str(), port, DC_COLORDEVICE, nullptr, nullptr) == 1) ? 1 : 0;
            detail.isDuplexSupported  = (DeviceCapabilitiesW(wid.c_str(), port, DC_DUPLEX, nullptr, nullptr) == 1) ? 1 : 0;
        }
        return detail;
    }

    // ── Discovery ─────────────────────────────────────────────────────────────

    bool startPrinterDiscovery() override {
        // Emit all locally-known printers immediately. No mDNS without WinRT.
        for (auto& e : enumPrinters()) {
            auto name = wstr_to_utf8(e.name);
            DiscoveredPrinter dp{
                name.c_str(), name.c_str(), "", 0, "local", "", true
            };
            emit_onPrinterDiscovered(dp);
        }
        return true;
    }

    bool stopPrinterDiscovery() override { return true; }

    // ── Connection / admin ────────────────────────────────────────────────────

    bool testPrinterConnection(const std::string& printerId, int64_t timeoutSeconds) override {
        // Parse host:port from printerId (IP, hostname, or URI).
        std::string host;
        int port = 631;
        parseHostPort(printerId, host, port);
        if (host.empty()) return false;

        SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
        if (s == INVALID_SOCKET) return false;

        DWORD timeoutMs = timeoutSeconds > 0
            ? static_cast<DWORD>(timeoutSeconds) * 1000 : 5000;
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));

        struct addrinfo hints{}, *res = nullptr;
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        std::string portStr = std::to_string(port);
        bool ok = (getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res) == 0);
        if (ok && res) ok = (connect(s, res->ai_addr, static_cast<int>(res->ai_addrlen)) == 0);
        if (res) freeaddrinfo(res);
        closesocket(s);
        return ok;
    }

    bool setDefaultPrinter(const std::string& printerId) override {
        auto wid = utf8_to_wstr(printerId);
        return SetDefaultPrinterW(wid.c_str()) != 0;
    }

    // ── Platform UX ───────────────────────────────────────────────────────────

    bool openSystemPrintQueue(const std::string& printerId) override {
        if (!printerId.empty()) {
            std::string args = std::string("/o /n \"") + printerId + "\"";
            return runCmd("rundll32.exe", "printui.dll,PrintUIEntry " + args);
        }
        return runCmd("control", "printers");
    }

    bool cancelRawPrint() override {
        SOCKET s = g_rawSocket.exchange(INVALID_SOCKET);
        if (s == INVALID_SOCKET) return false;
        shutdown(s, SD_BOTH);
        closesocket(s);
        return true;
    }

    bool openPrinterProperties(const std::string& printerId) override {
        if (printerId.empty()) return false;
        std::string args = std::string("/p /n \"") + printerId + "\"";
        return runCmd("rundll32.exe", "printui.dll,PrintUIEntry " + args);
    }

    // ── Raw / ESC-POS / ZPL ──────────────────────────────────────────────────

    PrintResult printRaw(const uint8_t* data, size_t len, const PrintSettings& s) override {
        return tcpOrSpoolerPrint(data, len, s, 9100);
    }

    PrintResult printEscPos(const uint8_t* data, size_t len, const PrintSettings& s) override {
        return tcpOrSpoolerPrint(data, len, s, 9100);
    }

    PrintResult printZpl(const std::string& zpl, const PrintSettings& s) override {
        return tcpOrSpoolerPrint(
            reinterpret_cast<const uint8_t*>(zpl.c_str()), zpl.size(), s, 9100);
    }

private:

    // ── Core dispatch ─────────────────────────────────────────────────────────

    PrintResult printBytes(const uint8_t* data, size_t len,
                           const char* ext, const char* /*mimeType*/,
                           const PrintSettings& s) {
        std::string tempPath = makeTempFile(data, len, ext);
        if (tempPath.empty())
            return PrintResult{false, "", "Failed to write temp file", "IO_ERROR"};
        PrintResult result;
        if (!s.showPrintDialog && s.printerId && s.printerId[0] != '\0') {
            result = spoolerPrint(data, len, s);
        } else {
            result = shellPrint(tempPath, s);
        }
        DeleteFileA(tempPath.c_str());
        return result;
    }

    // ── Shell print (dialog) ──────────────────────────────────────────────────

    PrintResult shellPrint(const std::string& filePath, const PrintSettings& s) {
        SHELLEXECUTEINFOA sei{};
        sei.cbSize = sizeof(sei);
        sei.fMask  = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        sei.lpVerb = "print";
        sei.lpFile = filePath.c_str();
        sei.nShow  = SW_HIDE;
        std::string printerParam;
        if (s.printerId && s.printerId[0] != '\0') {
            printerParam = std::string("/d:\"") + s.printerId + "\"";
            sei.lpParameters = printerParam.c_str();
        }
        bool ok = ShellExecuteExA(&sei) != 0;
        if (ok && sei.hProcess) {
            WaitForSingleObject(sei.hProcess, 60'000);
            CloseHandle(sei.hProcess);
        }
        return ok
            ? PrintResult{true, "1", "", ""}
            : PrintResult{false, "", "ShellExecute print failed", "SHELL_ERROR"};
    }

    // ── Spooler / silent print ────────────────────────────────────────────────

    PrintResult spoolerPrint(const uint8_t* data, size_t len, const PrintSettings& s) {
        auto wPrinter = utf8_to_wstr(s.printerId ? s.printerId : "");
        if (wPrinter.empty()) {
            wPrinter = defaultPrinterName();
            if (wPrinter.empty())
                return PrintResult{false, "", "No printer available", "NO_PRINTER"};
        }
        HANDLE hp = nullptr;
        if (!OpenPrinterW(wPrinter.data(), &hp, nullptr))
            return PrintResult{false, "", "OpenPrinter failed", "PRINTER_ERROR"};

        std::string jobName = (s.jobName && s.jobName[0] != '\0') ? s.jobName : "Document";
        DOC_INFO_1A docInfo{};
        docInfo.pDocName  = const_cast<LPSTR>(jobName.c_str());
        docInfo.pDatatype = const_cast<LPSTR>("RAW");

        DWORD jobId = StartDocPrinterA(hp, 1, reinterpret_cast<LPBYTE>(&docInfo));
        if (jobId == 0) { ClosePrinter(hp); return PrintResult{false, "", "StartDocPrinter failed", "PRINTER_ERROR"}; }

        int copies = s.copies > 0 ? static_cast<int>(s.copies) : 1;
        bool ok = true;
        if (StartPagePrinter(hp)) {
            DWORD written = 0;
            for (int c = 0; c < copies && ok; ++c) {
                ok = WritePrinter(hp, const_cast<LPVOID>(static_cast<const void*>(data)),
                    static_cast<DWORD>(len), &written) != 0;
            }
            EndPagePrinter(hp);
        } else { ok = false; }

        EndDocPrinter(hp);
        ClosePrinter(hp);
        return ok
            ? PrintResult{true, std::to_string(jobId).c_str(), "", ""}
            : PrintResult{false, "", "WritePrinter failed", "PRINTER_ERROR"};
    }

    // ── TCP raw / ESC-POS / ZPL print ─────────────────────────────────────────

    // Sends raw bytes to the printer. Uses a direct TCP socket when printerId
    // contains ':' or "://" (i.e. looks like a host:port or URI). Otherwise
    // falls back to the Windows spooler RAW datatype.
    PrintResult tcpOrSpoolerPrint(const uint8_t* data, size_t len,
                                   const PrintSettings& s, int defaultPort) {
        std::string pid = s.printerId ? s.printerId : "";
        bool hasHost = (pid.find(':') != std::string::npos ||
                        pid.find("://") != std::string::npos);
        if (hasHost) {
            std::string host;
            int port = defaultPort;
            parseHostPort(pid, host, port);
            if (host.empty())
                return errResult("Cannot parse host from printerId", "BAD_URI");
            int timeoutSec = (s.networkTimeoutSeconds > 0)
                             ? static_cast<int>(s.networkTimeoutSeconds) : 10;

            SOCKET sock = INVALID_SOCKET;
            struct addrinfo hints{}, *res = nullptr;
            hints.ai_family   = AF_INET;
            hints.ai_socktype = SOCK_STREAM;
            std::string portStr = std::to_string(port);
            if (getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res) != 0 || !res)
                return errResult("DNS resolution failed", "DNS_ERROR");

            sock = socket(res->ai_family, SOCK_STREAM, 0);
            DWORD tv = static_cast<DWORD>(timeoutSec) * 1000;
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&tv), sizeof(tv));
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&tv), sizeof(tv));
            int cr = connect(sock, res->ai_addr, static_cast<int>(res->ai_addrlen));
            freeaddrinfo(res);
            if (cr != 0) { closesocket(sock); return errResult("TCP connect failed", "CONNECT_FAILED"); }

            g_rawSocket.store(sock);
            // Chunked send
            const size_t CHUNK = 65536;
            size_t sent = 0; bool ok = true;
            while (sent < len && ok) {
                size_t chunk = std::min(CHUNK, len - sent);
                int n = send(sock, reinterpret_cast<const char*>(data + sent),
                             static_cast<int>(chunk), 0);
                if (n < 0) { ok = false; break; }
                sent += static_cast<size_t>(n);
            }
            g_rawSocket.store(INVALID_SOCKET);
            closesocket(sock);
            return ok ? okResult() : errResult("TCP send failed", "SEND_FAILED");
        }
        // Fall back to spooler
        return spoolerPrint(data, len, s);
    }

    // ── GDI text print (silent, no dialog) ───────────────────────────────────

    PrintResult gdiPrintText(const std::string& text, const PrintSettings& s) {
        auto wPrinter = utf8_to_wstr(s.printerId ? s.printerId : "");
        if (wPrinter.empty()) return errResult("No printer specified", "NO_PRINTER");

        HDC hdc = CreateDCW(L"WINSPOOL", wPrinter.c_str(), nullptr, nullptr);
        if (!hdc) return errResult("CreateDC failed", "PRINTER_ERROR");

        std::string jobName = (s.jobName && s.jobName[0]) ? s.jobName : "Text Document";
        auto wJobName = utf8_to_wstr(jobName);
        DOCINFOW di{}; di.cbSize = sizeof(di); di.lpszDocName = wJobName.c_str();
        if (StartDocW(hdc, &di) <= 0) { DeleteDC(hdc); return errResult("StartDoc failed", "PRINTER_ERROR"); }
        StartPage(hdc);

        // Select a font
        LOGFONTW lf{};
        lf.lfHeight = -MulDiv(10, GetDeviceCaps(hdc, LOGPIXELSY), 72);
        lf.lfCharSet = DEFAULT_CHARSET;
        wcscpy_s(lf.lfFaceName, L"Courier New");
        HFONT hFont = CreateFontIndirectW(&lf);
        HGDIOBJ oldFont = SelectObject(hdc, hFont);

        // Page margins (approx 1 cm)
        int marginX = GetDeviceCaps(hdc, LOGPIXELSX) / 4;
        int marginY = GetDeviceCaps(hdc, LOGPIXELSY) / 4;
        int pageW   = GetDeviceCaps(hdc, HORZRES);
        int pageH   = GetDeviceCaps(hdc, VERTRES);
        TEXTMETRICW tm{}; GetTextMetricsW(hdc, &tm);
        int lineH = tm.tmHeight + tm.tmExternalLeading;
        int x = marginX, y = marginY;

        // Split into lines and print
        size_t pos = 0;
        while (pos <= text.size()) {
            size_t nl = text.find('\n', pos);
            if (nl == std::string::npos) nl = text.size();
            std::string line = text.substr(pos, nl - pos);
            // Remove trailing \r if any
            if (!line.empty() && line.back() == '\r') line.pop_back();
            auto wLine = utf8_to_wstr(line);
            TextOutW(hdc, x, y, wLine.c_str(), static_cast<int>(wLine.size()));
            y += lineH;
            if (y + lineH > pageH - marginY) {
                EndPage(hdc);
                StartPage(hdc);
                y = marginY;
            }
            pos = nl + 1;
        }

        SelectObject(hdc, oldFont);
        DeleteObject(hFont);
        DWORD jobId = static_cast<DWORD>(EndPage(hdc));
        EndDoc(hdc);
        DeleteDC(hdc);
        return jobId > 0
            ? okResult(std::to_string(jobId))
            : errResult("GDI text print failed", "PRINTER_ERROR");
    }

    // ── Job control helper ────────────────────────────────────────────────────

    bool setJobControl(const std::string& jobIdStr, DWORD command) {
        DWORD jobId = static_cast<DWORD>(std::stoul(jobIdStr));
        for (auto& e : enumPrinters()) {
            HANDLE hp = nullptr;
            if (!OpenPrinterW(e.name.data(), &hp, nullptr)) continue;
            bool ok = SetJobW(hp, jobId, 0, nullptr, command) != 0;
            ClosePrinter(hp);
            if (ok) return true;
        }
        return false;
    }

    // ── Temp file helper ──────────────────────────────────────────────────────

    static std::string makeTempFile(const uint8_t* data, size_t len, const char* ext) {
        char tmpDir[MAX_PATH]{}, tmpBase[MAX_PATH]{};
        GetTempPathA(MAX_PATH, tmpDir);
        GetTempFileNameA(tmpDir, "ntp", 0, tmpBase);
        std::string finalPath = std::string(tmpBase) + ext;
        MoveFileExA(tmpBase, finalPath.c_str(), MOVEFILE_REPLACE_EXISTING);
        HANDLE hf = CreateFileA(finalPath.c_str(), GENERIC_WRITE, 0,
                                 nullptr, CREATE_ALWAYS, 0, nullptr);
        if (hf == INVALID_HANDLE_VALUE) return {};
        DWORD written = 0;
        WriteFile(hf, data, static_cast<DWORD>(len), &written, nullptr);
        CloseHandle(hf);
        return written == len ? finalPath : std::string{};
    }

    // ── Host/port parser ──────────────────────────────────────────────────────

    // Host/port parser — handles plain IP, host:port, socket://, ipp:// etc.
    static void parseHostPort(const std::string& uri, std::string& host, int& port) {
        std::string s = uri;
        // Strip scheme
        auto schemeEnd = s.find("://");
        if (schemeEnd != std::string::npos) s = s.substr(schemeEnd + 3);
        // Strip path
        auto pathStart = s.find('/');
        if (pathStart != std::string::npos) s = s.substr(0, pathStart);
        // Split host:port
        auto colon = s.rfind(':');
        if (colon != std::string::npos) {
            host = s.substr(0, colon);
            port = std::stoi(s.substr(colon + 1));
        } else {
            host = s;
        }
    }
};

// ── Auto-registration ─────────────────────────────────────────────────────────

namespace {
    struct _AutoRegister {
        HybridNitroPrintingImpl impl;
        _AutoRegister() { nitro_printing_register_impl(&impl); }
        ~_AutoRegister() { nitro_printing_register_impl(nullptr); }
    };
    static _AutoRegister _instance;
}

#endif // _WIN32
