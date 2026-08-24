//HybridNitroPrinting — web (WASM/Emscripten) implementation, built by
//web/build_web.sh into assets/web/nitro_printing.{js,wasm}.
//Single-threaded: async work completes through the exported
//nitro_printing_web_* callbacks.
#ifdef __EMSCRIPTEN__

#include "nitro_printing.native.g.h"
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

PrintResult failedResult(const std::string& msg, const char* code) {
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

std::string ptLength(double v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%gpt", v);
    return buf;
}

bool isLandscape(const PrintSettings& s) {
    int deg = ((int)s.orientationDegrees % 360 + 360) % 360;
    return deg == 90 || deg == 270;
}

/// PrintSettings → dialog-flow options row (parsed by W.parseOpts):
/// sizeCss, marginCss, gray, copies, fit, header, footer, rangeFrom, rangeTo.
std::string buildDialogOpts(const std::optional<PrintSettings>& sOpt) {
    if (!sOpt) return "";
    const PrintSettings& s = *sOpt;
    std::string size;
    switch (s.paperSize) {
        case PAPERSIZE_A4: size = "A4"; break;
        case PAPERSIZE_A5: size = "A5"; break;
        case PAPERSIZE_LETTER: size = "letter"; break;
        case PAPERSIZE_LEGAL: size = "legal"; break;
        case PAPERSIZE_CUSTOM:
            if (s.customPaperWidth > 0 && s.customPaperHeight > 0) {
                double w = s.customPaperWidth, h = s.customPaperHeight;
                if (isLandscape(s) && h > w) std::swap(w, h);
                size = ptLength(w) + " " + ptLength(h);
            }
            break;
        default: break;
    }
    if (!size.empty() && s.paperSize != PAPERSIZE_CUSTOM && isLandscape(s)) {
        size += " landscape";
    }
    std::string margin;
    if (s.marginTop > 0 || s.marginRight > 0 || s.marginBottom > 0 || s.marginLeft > 0) {
        margin = ptLength(s.marginTop) + " " + ptLength(s.marginRight) + " " +
                 ptLength(s.marginBottom) + " " + ptLength(s.marginLeft);
    }
    int64_t copies = s.copies > 1 ? s.copies : 1;
    std::string out;
    out += size; out += '\x1F';
    out += margin; out += '\x1F';
    out += s.color ? "0" : "1"; out += '\x1F';
    out += std::to_string(copies); out += '\x1F';
    out += s.fitToPage ? "1" : "0"; out += '\x1F';
    out += s.headerText; out += '\x1F';
    out += s.footerText; out += '\x1F';
    out += std::to_string(s.pageRangeFrom); out += '\x1F';
    out += std::to_string(s.pageRangeTo); out += '\x1F';
    out += s.jobName; out += '\x1F';
    out += std::to_string(s.pagesPerSheet > 1 ? s.pagesPerSheet : 1); out += '\x1F';
    out += s.collate ? "1" : "0";
    return out;
}

/// PrintSettings → Web Printing IPP template-attributes row (W.wpAttrs):
/// copies, sides, colorMode, quality, orientation, mediaSizeName, from, to.
std::string buildWpAttrs(const std::optional<PrintSettings>& sOpt) {
    PrintSettings s = sOpt ? *sOpt : defaultSettings();
    const char* media = "";
    switch (s.paperSize) {
        case PAPERSIZE_A4: media = "iso_a4_210x297mm"; break;
        case PAPERSIZE_A5: media = "iso_a5_148x210mm"; break;
        case PAPERSIZE_LETTER: media = "na_letter_8.5x11in"; break;
        case PAPERSIZE_LEGAL: media = "na_legal_8.5x14in"; break;
        default: break; // custom — omit, printer default wins
    }
    const char* quality =
        s.quality == PRINTQUALITY_DRAFT ? "draft" :
        (s.quality == PRINTQUALITY_HIGH || s.quality == PRINTQUALITY_BEST) ? "high" : "normal";
    const char* mediaType = "";
    switch (s.mediaType) {
        case MEDIATYPE_GLOSSY: mediaType = "photographic-glossy"; break;
        case MEDIATYPE_MATTE: mediaType = "photographic-matte"; break;
        case MEDIATYPE_PHOTO: mediaType = "photographic"; break;
        case MEDIATYPE_LABEL: mediaType = "labels"; break;
        case MEDIATYPE_ENVELOPE: mediaType = "envelope"; break;
        default: break; // plain — omit, printer default wins
    }
    std::string out;
    out += std::to_string(s.copies > 1 ? s.copies : 1); out += '\x1F';
    out += s.duplex ? "two-sided-long-edge" : "one-sided"; out += '\x1F';
    out += s.color ? "color" : "monochrome"; out += '\x1F';
    out += quality; out += '\x1F';
    out += isLandscape(s) ? "landscape" : "portrait"; out += '\x1F';
    out += media; out += '\x1F';
    out += std::to_string(s.pageRangeFrom); out += '\x1F';
    out += std::to_string(s.pageRangeTo); out += '\x1F';
    out += s.collate ? "separate-documents-collated-copies"
                     : "separate-documents-uncollated-copies"; out += '\x1F';
    out += mediaType; out += '\x1F';
    out += std::to_string(s.pagesPerSheet > 1 ? s.pagesPerSheet : 1); out += '\x1F';
    out += s.fitToPage ? "1" : "0";
    return out;
}

const char* sniffImageMime(const uint8_t* d, size_t n) {
    if (n >= 4 && d[0] == 0x89 && d[1] == 'P' && d[2] == 'N' && d[3] == 'G') return "image/png";
    if (n >= 2 && d[0] == 0xFF && d[1] == 0xD8) return "image/jpeg";
    if (n >= 4 && d[0] == 'G' && d[1] == 'I' && d[2] == 'F' && d[3] == '8') return "image/gif";
    if (n >= 12 && d[0] == 'R' && d[1] == 'I' && d[2] == 'F' && d[3] == 'F' &&
        d[8] == 'W' && d[9] == 'E' && d[10] == 'B' && d[11] == 'P') return "image/webp";
    return "image/png";
}

/// Splits a \x1F-separated field row.
std::vector<std::string> splitFields(const std::string& row) {
    std::vector<std::string> out;
    size_t start = 0;
    while (true) {
        size_t sep = row.find('\x1F', start);
        if (sep == std::string::npos) {
            out.push_back(row.substr(start));
            break;
        }
        out.push_back(row.substr(start, sep - start));
        start = sep + 1;
    }
    return out;
}

/// Splits a \x1E-separated table into rows (empty table → no rows).
std::vector<std::vector<std::string>> splitTable(const char* table) {
    std::vector<std::vector<std::string>> rows;
    if (table == nullptr || *table == '\0') return rows;
    std::string s(table);
    size_t start = 0;
    while (start <= s.size()) {
        size_t sep = s.find('\x1E', start);
        std::string row = (sep == std::string::npos) ? s.substr(start) : s.substr(start, sep - start);
        if (!row.empty()) rows.push_back(splitFields(row));
        if (sep == std::string::npos) break;
        start = sep + 1;
    }
    return rows;
}

int64_t toInt(const std::string& s) { return s.empty() ? 0 : (int64_t)strtoll(s.c_str(), nullptr, 10); }
bool toBool(const std::string& s) { return s == "1"; }

// printers row: id, name, address, isDefault, isAvailable
PrinterInfo printerFromRow(const std::vector<std::string>& f) {
    PrinterInfo p{};
    if (f.size() >= 5) {
        p.id = f[0]; p.name = f[1]; p.address = f[2];
        p.isDefault = toBool(f[3]); p.isAvailable = toBool(f[4]);
    }
    return p;
}

// job row: id, printerId, title, state, progress, createdMs, completedMs, error, pages
PrintJob jobFromRow(const std::vector<std::string>& f) {
    PrintJob j{};
    if (f.size() >= 9) {
        j.id = f[0]; j.printerId = f[1]; j.documentTitle = f[2];
        j.state = (PrintState)toInt(f[3]);
        j.progress = toInt(f[4]);
        j.createdAtMillis = toInt(f[5]);
        j.completedAtMillis = toInt(f[6]);
        j.errorMessage = f[7];
        j.pagesPrinted = toInt(f[8]);
    }
    return j;
}

// Completion kinds routed through nitro_printing_web_done().
enum WebDoneKind { kDonePrint = 0, kDoneDialog = 1, kDoneBatchItem = 2, kDoneBool = 3 };

// showPrintDialog settings held until the JS flow calls back, keyed by the
// (unique per call) Dart port.
std::map<int64_t, PrintSettings> g_pendingDialogs;

//Preview bytes stay native-owned (Dart frees only the PreviewResult shell);
//released when the next preview renders.
std::vector<uint8_t>* g_lastPreview = nullptr;

// ── Minimal PDF utilities (pure wasm, no browser API) ────────────────────────

///Page count by scanning "/Type /Page" (not "/Pages"); object streams undercount.
int64_t countPdfPages(const uint8_t* d, size_t n) {
    int64_t count = 0;
    for (size_t i = 0; i + 5 < n; i++) {
        if (d[i] != '/' || d[i + 1] != 'T' || memcmp(d + i, "/Type", 5) != 0) continue;
        size_t j = i + 5;
        while (j < n && (d[j] == ' ' || d[j] == '\r' || d[j] == '\n' || d[j] == '\t')) j++;
        if (j + 5 <= n && memcmp(d + j, "/Page", 5) == 0) {
            if (j + 5 == n || (d[j + 5] != 's')) count++;
        }
    }
    return count;
}

std::string pdfEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        if (c == '(' || c == ')' || c == '\\') out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

///Page geometry from PrintSettings (paper size, orientation, margins). A4
///portrait with default margins = 60 lines/page (getPageCount contract).
struct PageGeom {
    double w = 595, h = 842;       // pt
    double marginL = 40;
    double firstBaseline = 42;     // distance from the top edge
    double marginB = 20;
    int linesPerPage() const {
        int n = (int)((h - firstBaseline - marginB) / 13.0);
        return n > 0 ? n : 1;
    }
};

PageGeom pageGeomFrom(const std::optional<PrintSettings>& sOpt) {
    PageGeom g;
    if (!sOpt) return g;
    const PrintSettings& s = *sOpt;
    switch (s.paperSize) {
        case PAPERSIZE_A4: g.w = 595; g.h = 842; break;
        case PAPERSIZE_A5: g.w = 420; g.h = 595; break;
        case PAPERSIZE_LETTER: g.w = 612; g.h = 792; break;
        case PAPERSIZE_LEGAL: g.w = 612; g.h = 1008; break;
        case PAPERSIZE_CUSTOM:
            if (s.customPaperWidth > 0 && s.customPaperHeight > 0) {
                g.w = s.customPaperWidth;
                g.h = s.customPaperHeight;
            }
            break;
        default: break;
    }
    if (isLandscape(s) && g.h > g.w) std::swap(g.w, g.h);
    if (s.marginLeft > 0) g.marginL = s.marginLeft;
    if (s.marginTop > 0) g.firstBaseline = s.marginTop + 11; // baseline under the margin
    if (s.marginBottom > 0) g.marginB = s.marginBottom;
    return g;
}

/// Serializes numbered objects (objects[i] = body of object i+1) into a PDF.
std::vector<uint8_t> finishPdf(const std::vector<std::string>& objects) {
    std::string pdf = "%PDF-1.4\n";
    std::vector<size_t> offsets;
    for (size_t i = 0; i < objects.size(); i++) {
        offsets.push_back(pdf.size());
        pdf += std::to_string(i + 1) + " 0 obj" + objects[i] + "endobj\n";
    }
    size_t xref = pdf.size();
    char buf[32];
    pdf += "xref\n0 " + std::to_string(objects.size() + 1) + "\n0000000000 65535 f \n";
    for (size_t off : offsets) {
        snprintf(buf, sizeof(buf), "%010zu 00000 n \n", off);
        pdf += buf;
    }
    pdf += "trailer<</Size " + std::to_string(objects.size() + 1) +
           "/Root 1 0 R>>\nstartxref\n" + std::to_string(xref) + "\n%%EOF";
    return std::vector<uint8_t>(pdf.begin(), pdf.end());
}

std::string mediaBox(const PageGeom& g) {
    char buf[64];
    snprintf(buf, sizeof(buf), "[0 0 %g %g]", g.w, g.h);
    return buf;
}

///Plain text → minimal multi-page PDF (Helvetica 11pt) sized by [g], with
///optional per-page header/footer and a 1-based page range.
std::vector<uint8_t> textToPdf(const std::string& text, const PageGeom& g,
                               const std::string& header = "",
                               const std::string& footer = "",
                               int64_t rangeFrom = 0, int64_t rangeTo = 0) {
    int kLinesPerPage = g.linesPerPage();
    if (!header.empty()) kLinesPerPage -= 2;
    if (!footer.empty()) kLinesPerPage -= 2;
    if (kLinesPerPage < 1) kLinesPerPage = 1;
    std::vector<std::string> lines;
    std::string cur;
    for (char c : text) {
        if (c == '\n') { lines.push_back(cur); cur.clear(); }
        else if (c != '\r') cur.push_back(c);
    }
    lines.push_back(cur);

    size_t pageCount = (lines.size() + kLinesPerPage - 1) / kLinesPerPage;
    if (pageCount == 0) pageCount = 1;
    size_t pageFirst = 0, pageLast = pageCount; // [first, last)
    if (rangeFrom > 0 || rangeTo > 0) {
        int64_t f = rangeFrom > 0 ? rangeFrom : 1;
        int64_t t = (rangeTo > 0 && (size_t)rangeTo <= pageCount) ? rangeTo : (int64_t)pageCount;
        if (f <= t && (size_t)f <= pageCount) {
            pageFirst = (size_t)(f - 1);
            pageLast = (size_t)t;
        }
    }

    std::vector<std::string> objects;
    std::string kids;
    // Object layout: 1=Catalog, 2=Pages, 3=Font, then per page: content, page.
    objects.push_back("<</Type/Catalog/Pages 2 0 R>>");
    objects.push_back(""); // Pages — filled after kids are known
    objects.push_back("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>");
    char head[96];
    snprintf(head, sizeof(head), "BT /F1 11 Tf %g %g Td 13 TL\n",
             g.marginL, g.h - g.firstBaseline);
    for (size_t p = pageFirst; p < pageLast; p++) {
        std::string stream = head;
        if (!header.empty()) {
            stream += "(" + pdfEscape(header) + ") Tj T*\n() Tj T*\n";
        }
        size_t first = p * (size_t)kLinesPerPage;
        size_t last = std::min(lines.size(), first + (size_t)kLinesPerPage);
        for (size_t i = first; i < last; i++) {
            stream += "(" + pdfEscape(lines[i]) + ") Tj T*\n";
        }
        if (!footer.empty()) {
            char foot[64];
            snprintf(foot, sizeof(foot), "ET BT /F1 9 Tf %g %g Td ",
                     g.marginL, g.marginB + 4);
            stream += foot;
            stream += "(" + pdfEscape(footer) + ") Tj\n";
        }
        stream += "ET";
        int contentNum = (int)objects.size() + 1;
        objects.push_back("<</Length " + std::to_string(stream.size()) + ">>\nstream\n" + stream + "\nendstream");
        int pageNum = (int)objects.size() + 1;
        objects.push_back("<</Type/Page/MediaBox" + mediaBox(g) + "/Parent 2 0 R"
                          "/Resources<</Font<</F1 3 0 R>>>>/Contents " +
                          std::to_string(contentNum) + " 0 R>>");
        kids += std::to_string(pageNum) + " 0 R ";
    }
    objects[1] = "<</Type/Pages/Kids[" + kids + "]/Count " +
                 std::to_string(pageLast - pageFirst) + ">>";
    return finishPdf(objects);
}

/// Embeds a JPEG (from the browser's canvas re-encode) as a one-page PDF via
/// DCTDecode, scaled to fit inside [g] with 40pt padding, top-left anchored.
std::vector<uint8_t> jpegToPdf(const uint8_t* jpeg, size_t len, int wPx, int hPx,
                               const PageGeom& g) {
    double boxW = g.w - 80, boxH = g.h - 80;
    if (boxW < 1) boxW = g.w;
    if (boxH < 1) boxH = g.h;
    double scale = std::min(boxW / (wPx > 0 ? wPx : 1), boxH / (hPx > 0 ? hPx : 1));
    if (scale > 1) scale = 1;
    double drawW = wPx * scale, drawH = hPx * scale;
    char cm[128];
    snprintf(cm, sizeof(cm), "q %g 0 0 %g %g %g cm /Im1 Do Q",
             drawW, drawH, (g.w - drawW) / 2, g.h - 40 - drawH);
    std::string content = cm;

    std::vector<std::string> objects;
    objects.push_back("<</Type/Catalog/Pages 2 0 R>>");
    objects.push_back("<</Type/Pages/Kids[5 0 R]/Count 1>>");
    std::string img = "<</Type/XObject/Subtype/Image/Width " + std::to_string(wPx) +
                      "/Height " + std::to_string(hPx) +
                      "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode/Length " +
                      std::to_string(len) + ">>\nstream\n";
    img.append((const char*)jpeg, len);
    img += "\nendstream";
    objects.push_back(std::move(img));
    objects.push_back("<</Length " + std::to_string(content.size()) + ">>\nstream\n" + content + "\nendstream");
    objects.push_back("<</Type/Page/MediaBox" + mediaBox(g) + "/Parent 2 0 R"
                      "/Resources<</XObject<</Im1 3 0 R>>>>/Contents 4 0 R>>");
    return finishPdf(objects);
}

/// Unicode codepoint → CP437 byte (thermal printers' default codepage).
/// Covers ASCII plus the common Latin/symbol range; unmappable → '?'.
uint8_t cp437FromCodepoint(uint32_t cp) {
    if (cp < 0x80) return (uint8_t)cp;
    switch (cp) {
        case 0x00FC: return 0x81; case 0x00E9: return 0x82; case 0x00E2: return 0x83;
        case 0x00E4: return 0x84; case 0x00E0: return 0x85; case 0x00E5: return 0x86;
        case 0x00E7: return 0x87; case 0x00EA: return 0x88; case 0x00EB: return 0x89;
        case 0x00E8: return 0x8A; case 0x00EF: return 0x8B; case 0x00EE: return 0x8C;
        case 0x00EC: return 0x8D; case 0x00C4: return 0x8E; case 0x00C5: return 0x8F;
        case 0x00C9: return 0x90; case 0x00E6: return 0x91; case 0x00C6: return 0x92;
        case 0x00F4: return 0x93; case 0x00F6: return 0x94; case 0x00F2: return 0x95;
        case 0x00FB: return 0x96; case 0x00F9: return 0x97; case 0x00FF: return 0x98;
        case 0x00D6: return 0x99; case 0x00DC: return 0x9A; case 0x00A2: return 0x9B;
        case 0x00A3: return 0x9C; case 0x00A5: return 0x9D; case 0x0192: return 0x9F;
        case 0x00E1: return 0xA0; case 0x00ED: return 0xA1; case 0x00F3: return 0xA2;
        case 0x00FA: return 0xA3; case 0x00F1: return 0xA4; case 0x00D1: return 0xA5;
        case 0x00AA: return 0xA6; case 0x00BA: return 0xA7; case 0x00BF: return 0xA8;
        case 0x00BD: return 0xAB; case 0x00BC: return 0xAC; case 0x00A1: return 0xAD;
        case 0x00AB: return 0xAE; case 0x00BB: return 0xAF; case 0x00DF: return 0xE1;
        case 0x00B5: return 0xE6; case 0x00B1: return 0xF1; case 0x00F7: return 0xF6;
        case 0x00B0: return 0xF8; case 0x00B7: return 0xFA; case 0x00B2: return 0xFD;
        default: return '?';
    }
}

/// Wraps plain text in a minimal ESC/POS job: initialize, CP437-translated
/// text, feed, cut.
std::vector<uint8_t> textToEscPos(const std::string& text) {
    std::vector<uint8_t> out = {0x1B, '@'}; // ESC @ — initialize
    // Inline UTF-8 decode → CP437. Malformed sequences fall through bytewise.
    for (size_t i = 0; i < text.size();) {
        uint8_t b = (uint8_t)text[i];
        uint32_t cp = b;
        size_t adv = 1;
        if ((b & 0xE0) == 0xC0 && i + 1 < text.size()) {
            cp = ((b & 0x1F) << 6) | ((uint8_t)text[i + 1] & 0x3F);
            adv = 2;
        } else if ((b & 0xF0) == 0xE0 && i + 2 < text.size()) {
            cp = ((b & 0x0F) << 12) | (((uint8_t)text[i + 1] & 0x3F) << 6) |
                 ((uint8_t)text[i + 2] & 0x3F);
            adv = 3;
        } else if ((b & 0xF8) == 0xF0 && i + 3 < text.size()) {
            cp = 0xFFFD; // beyond the BMP — no CP437 mapping
            adv = 4;
        }
        i += adv;
        if (cp == '\r') continue;
        out.push_back(cp437FromCodepoint(cp));
    }
    if (out.empty() || out.back() != '\n') out.push_back('\n');
    out.insert(out.end(), {0x1B, 'd', 4});        // ESC d 4 — feed 4 lines
    out.insert(out.end(), {0x1D, 'V', 0x42, 0});  // GS V B 0 — feed and cut
    return out;
}

//── Classic-PDF object model (page counting + page-range extraction) ─────────
//Plain "N G obj … endobj" objects and a classic page tree only; object
//streams and encrypted files yield no objects (callers use the whole document).

struct PdfObj {
    int num = 0;
    int gen = 0;
    std::string body;
};

bool pdfIsWs(uint8_t c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == 0;
}

std::vector<PdfObj> scanPdfObjects(const uint8_t* d, size_t n) {
    std::vector<PdfObj> out;
    size_t i = 0;
    while (i + 3 < n) {
        // Match "obj" as a token.
        if (!(d[i] == 'o' && d[i + 1] == 'b' && d[i + 2] == 'j')) { i++; continue; }
        // Walk back across "N G " to validate + capture the numbers.
        size_t j = i;
        while (j > 0 && pdfIsWs(d[j - 1])) j--;
        size_t genEnd = j;
        while (j > 0 && d[j - 1] >= '0' && d[j - 1] <= '9') j--;
        size_t genStart = j;
        if (genStart == genEnd) { i++; continue; }
        while (j > 0 && pdfIsWs(d[j - 1])) j--;
        size_t numEnd = j;
        while (j > 0 && d[j - 1] >= '0' && d[j - 1] <= '9') j--;
        size_t numStart = j;
        if (numStart == numEnd) { i++; continue; }
        // Find the body end: "endobj", skipping stream payloads.
        size_t p = i + 3;
        size_t bodyStart = p;
        size_t bodyEnd = 0;
        while (p + 6 <= n) {
            if (d[p] == 's' && memcmp(d + p, "stream", 6) == 0 &&
                (p + 6 >= n || d[p + 6] == '\r' || d[p + 6] == '\n')) {
                p += 6;
                while (p + 9 <= n && memcmp(d + p, "endstream", 9) != 0) p++;
                p += 9;
                continue;
            }
            if (d[p] == 'e' && p + 6 <= n && memcmp(d + p, "endobj", 6) == 0) {
                bodyEnd = p;
                break;
            }
            p++;
        }
        if (bodyEnd == 0) break;
        PdfObj obj;
        obj.num = atoi(std::string((const char*)d + numStart, numEnd - numStart).c_str());
        obj.gen = atoi(std::string((const char*)d + genStart, genEnd - genStart).c_str());
        obj.body.assign((const char*)d + bodyStart, bodyEnd - bodyStart);
        out.push_back(std::move(obj));
        i = bodyEnd + 6;
    }
    return out;
}

/// Reads the object number of "/Key N G R" in [body]; -1 when absent.
int pdfRefAfterKey(const std::string& body, const std::string& key) {
    size_t k = body.find(key);
    if (k == std::string::npos) return -1;
    size_t p = k + key.size();
    while (p < body.size() && pdfIsWs((uint8_t)body[p])) p++;
    int num = 0;
    bool any = false;
    while (p < body.size() && body[p] >= '0' && body[p] <= '9') {
        num = num * 10 + (body[p] - '0');
        p++;
        any = true;
    }
    return any ? num : -1;
}

void pdfCollectLeafPages(int num, const std::map<int, const PdfObj*>& byNum,
                         std::vector<int>& leaves, int depth) {
    if (depth > 32) return; // cycle guard
    auto it = byNum.find(num);
    if (it == byNum.end()) return;
    const std::string& body = it->second->body;
    bool isPages = body.find("/Kids") != std::string::npos;
    if (!isPages) {
        if (body.find("/Page") != std::string::npos) leaves.push_back(num);
        return;
    }
    size_t k = body.find("/Kids");
    size_t open = body.find('[', k);
    size_t close = body.find(']', open);
    if (open == std::string::npos || close == std::string::npos) return;
    size_t p = open + 1;
    while (p < close) {
        while (p < close && !(body[p] >= '0' && body[p] <= '9')) p++;
        int kid = 0;
        bool any = false;
        while (p < close && body[p] >= '0' && body[p] <= '9') {
            kid = kid * 10 + (body[p] - '0');
            p++;
            any = true;
        }
        // skip generation + R
        while (p < close && body[p] != 'R') p++;
        p++;
        if (any) pdfCollectLeafPages(kid, byNum, leaves, depth + 1);
    }
}

struct PdfDoc {
    std::vector<PdfObj> objects;
    int catalogNum = -1;
    int pagesRootNum = -1;
    std::vector<int> leaves; // page object numbers in document order
};

/// Parses the classic object model; leaves empty on anything exotic.
PdfDoc parsePdf(const uint8_t* d, size_t n) {
    PdfDoc doc;
    std::string tail((const char*)d + (n > 2048 ? n - 2048 : 0), std::min(n, (size_t)2048));
    if (tail.find("/Encrypt") != std::string::npos) return doc;
    doc.objects = scanPdfObjects(d, n);
    if (doc.objects.empty()) return doc;
    std::map<int, const PdfObj*> byNum;
    for (const auto& o : doc.objects) byNum[o.num] = &o;
    // Catalog: prefer the trailer's /Root; fall back to any /Type/Catalog obj.
    std::string whole((const char*)d, n);
    size_t rootKey = whole.rfind("/Root");
    if (rootKey != std::string::npos) {
        doc.catalogNum = pdfRefAfterKey(whole.substr(rootKey, 64), "/Root");
    }
    if (doc.catalogNum < 0 || byNum.find(doc.catalogNum) == byNum.end()) {
        for (const auto& o : doc.objects) {
            if (o.body.find("/Catalog") != std::string::npos) { doc.catalogNum = o.num; break; }
        }
    }
    if (doc.catalogNum < 0) return doc;
    auto cat = byNum.find(doc.catalogNum);
    if (cat == byNum.end()) return doc;
    doc.pagesRootNum = pdfRefAfterKey(cat->second->body, "/Pages");
    if (doc.pagesRootNum < 0) return doc;
    pdfCollectLeafPages(doc.pagesRootNum, byNum, doc.leaves, 0);
    return doc;
}

std::vector<uint8_t> serializePdf(const PdfDoc& doc) {
    int maxNum = 0;
    for (const auto& o : doc.objects) maxNum = std::max(maxNum, o.num);
    std::map<int, size_t> offsets;
    std::string pdf = "%PDF-1.7\n";
    for (const auto& o : doc.objects) {
        offsets[o.num] = pdf.size();
        pdf += std::to_string(o.num) + " " + std::to_string(o.gen) + " obj" + o.body + "endobj\n";
    }
    size_t xref = pdf.size();
    pdf += "xref\n0 " + std::to_string(maxNum + 1) + "\n0000000000 65535 f \n";
    char buf[32];
    for (int i = 1; i <= maxNum; i++) {
        auto it = offsets.find(i);
        if (it == offsets.end()) {
            pdf += "0000000000 65535 f \n";
        } else {
            snprintf(buf, sizeof(buf), "%010zu 00000 n \n", it->second);
            pdf += buf;
        }
    }
    pdf += "trailer<</Size " + std::to_string(maxNum + 1) + "/Root " +
           std::to_string(doc.catalogNum) + " 0 R>>\nstartxref\n" +
           std::to_string(xref) + "\n%%EOF";
    return std::vector<uint8_t>(pdf.begin(), pdf.end());
}

/// Splices [replacement] over the "/Key …" value span in [body].
void pdfReplaceKidsAndCount(std::string& body, const std::string& kids, size_t count) {
    size_t k = body.find("/Kids");
    if (k != std::string::npos) {
        size_t open = body.find('[', k);
        size_t close = body.find(']', open);
        if (open != std::string::npos && close != std::string::npos) {
            body.replace(open, close - open + 1, "[" + kids + "]");
        }
    }
    size_t c = body.find("/Count");
    if (c != std::string::npos) {
        size_t p = c + 6;
        while (p < body.size() && pdfIsWs((uint8_t)body[p])) p++;
        size_t start = p;
        while (p < body.size() && body[p] >= '0' && body[p] <= '9') p++;
        body.replace(start, p - start, std::to_string(count));
    }
}

///Extracts pages [from..to] (1-based, 0 = unbounded) by rewriting the page
///tree; unused objects stay so every reference remains valid. Empty result →
///whole document.
std::vector<uint8_t> extractPdfPages(const uint8_t* d, size_t n, int64_t from, int64_t to) {
    PdfDoc doc = parsePdf(d, n);
    if (doc.leaves.empty()) return {};
    int64_t count = (int64_t)doc.leaves.size();
    int64_t f = from > 0 ? from : 1;
    int64_t t = (to > 0 && to <= count) ? to : count;
    if (f > count || f > t) return {};
    if (f == 1 && t == count) return {}; // full range — nothing to do
    std::string kids;
    for (int64_t i = f - 1; i < t; i++) {
        kids += std::to_string(doc.leaves[(size_t)i]) + " 0 R ";
    }
    for (auto& o : doc.objects) {
        if (o.num == doc.pagesRootNum) {
            pdfReplaceKidsAndCount(o.body, kids, (size_t)(t - f + 1));
        }
    }
    // Re-parent the selected pages onto the root (nested trees).
    for (int64_t i = f - 1; i < t; i++) {
        for (auto& o : doc.objects) {
            if (o.num != doc.leaves[(size_t)i]) continue;
            size_t p = o.body.find("/Parent");
            if (p == std::string::npos) break;
            size_t s = p + 7;
            while (s < o.body.size() && pdfIsWs((uint8_t)o.body[s])) s++;
            size_t e = s;
            while (e < o.body.size() && o.body[e] != 'R') e++;
            if (e < o.body.size()) {
                o.body.replace(s, e - s + 1, std::to_string(doc.pagesRootNum) + " 0 R");
            }
            break;
        }
    }
    return serializePdf(doc);
}

/// One JPEG slice of a rasterized page.
struct JpegSlice {
    const uint8_t* data;
    size_t len;
    int w, h;
};

/// Builds a PDF with one page per JPEG slice, each scaled into [g] with
/// [pad]pt padding (0 = full-bleed page-sized slices).
std::vector<uint8_t> jpegsToPdf(const std::vector<JpegSlice>& slices, const PageGeom& g,
                                double pad = 40) {
    std::vector<std::string> objects;
    objects.push_back("<</Type/Catalog/Pages 2 0 R>>");
    objects.push_back(""); // Pages — filled once kids are known
    std::string kids;
    for (const auto& s : slices) {
        double boxW = g.w - 2 * pad, boxH = g.h - 2 * pad;
        if (boxW < 1) boxW = g.w;
        if (boxH < 1) boxH = g.h;
        double scale = std::min(boxW / (s.w > 0 ? s.w : 1), boxH / (s.h > 0 ? s.h : 1));
        double drawW = s.w * scale, drawH = s.h * scale;
        char cm[128];
        snprintf(cm, sizeof(cm), "q %g 0 0 %g %g %g cm /Im1 Do Q",
                 drawW, drawH, (g.w - drawW) / 2, g.h - pad - drawH);
        std::string content = cm;
        int imgNum = (int)objects.size() + 1;
        std::string img = "<</Type/XObject/Subtype/Image/Width " + std::to_string(s.w) +
                          "/Height " + std::to_string(s.h) +
                          "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode/Length " +
                          std::to_string(s.len) + ">>\nstream\n";
        img.append((const char*)s.data, s.len);
        img += "\nendstream";
        objects.push_back(std::move(img));
        int contentNum = (int)objects.size() + 1;
        objects.push_back("<</Length " + std::to_string(content.size()) + ">>\nstream\n" + content + "\nendstream");
        int pageNum = (int)objects.size() + 1;
        objects.push_back("<</Type/Page/MediaBox" + mediaBox(g) + "/Parent 2 0 R"
                          "/Resources<</XObject<</Im1 " + std::to_string(imgNum) +
                          " 0 R>>>>/Contents " + std::to_string(contentNum) + " 0 R>>");
        kids += std::to_string(pageNum) + " 0 R ";
    }
    objects[1] = "<</Type/Pages/Kids[" + kids + "]/Count " + std::to_string(slices.size()) + ">>";
    return finishPdf(objects);
}

/// True when [id] names a raw transport this backend can drive directly.
bool isRawPrinterId(const std::string& id) {
    return id.rfind("usb:", 0) == 0 || id.rfind("ws://", 0) == 0 ||
           id.rfind("wss://", 0) == 0 || id.rfind("socket://", 0) == 0 ||
           id.rfind("serial:", 0) == 0 || id.rfind("ble:", 0) == 0 ||
           id.rfind("qz:", 0) == 0 || id.rfind("agent:", 0) == 0;
}

// renderPreview/printToFile image jobs awaiting the browser's JPEG re-encode.
struct PendingImagePdf {
    int intent;          // 0 = preview, 1 = download
    PageGeom geom;
    std::string name;    // download filename (intent 1)
};
std::map<int64_t, PendingImagePdf> g_pendingImagePdf;

// renderPreview/printToFile/getPageCount HTML jobs awaiting rasterization.
struct PendingHtmlPdf {
    int intent;          // 0 = preview, 1 = download, 2 = page count
    PageGeom geom;
    std::string name;    // download filename (intent 1)
    double pad = 40;     // 0 = full-bleed (page-accurate preview raster)
};
std::map<int64_t, PendingHtmlPdf> g_pendingHtmlPdf;

} // namespace

//── JS flows ─────────────────────────────────────────────────────────────────
//Helpers live on globalThis; async flows finish by calling the exported
//nitro_printing_web_* functions. JS→C++ strings are malloc'd UTF-8 freed by
//C++; tables use \x1F fields / \x1E rows.

EM_JS(void, js_ensure_helpers, (), {
  if (globalThis.__nitroWeb) return;
  var W = globalThis.__nitroWeb = {
    cache: { printers: [], caps: {}, status: {}, jobs: [] },
    rawAbort: null,
    batch: [],
    batchDone: null,
  };

  //UTF-8 encode into a malloc'd NUL-terminated buffer the C++ side frees
  //(EM_JS bodies get no emscripten runtime helpers).
  W.cstr = function(s) {
    var bytes = new TextEncoder().encode(String(s == null ? "" : s));
    var p = wasmExports.malloc(bytes.length + 1);
    HEAPU8.set(bytes, p);
    HEAPU8[p + bytes.length] = 0;
    return p;
  };
  //── Job tracker ────────────────────────────────────────────────────────
  //Every print path records a job and emits onPrintJobChanged per transition.
  //States mirror PrintState: 1=printing, 2=completed, 3=cancelled, 4=failed.
  W.jobSeq = 0;
  W.jobsByPort = new Map();
  W.emitJob = function(rec) {
    try { wasmExports.nitro_printing_web_job_changed(W.cstr(W.wpJobRow(rec))); } catch (e) {}
  };
  W.newJob = function(port, printerId, title) {
    var rec = { id: 'web-print-' + (++W.jobSeq), printerId: printerId || "",
                title: title || "", state: 1, progress: 0,
                createdMs: Date.now(), completedMs: 0, error: "", pages: 0 };
    W.cache.jobs.push(rec);
    W.jobsByPort.set(port, rec);
    W.emitJob(rec);
    return rec;
  };
  W.finishJob = function(port, ok, error) {
    var rec = W.jobsByPort.get(port);
    if (!rec) return null;
    W.jobsByPort.delete(port);
    rec.state = ok ? 2 : ((error || "").indexOf('CANCELLED') === 0 ? 3 : 4);
    rec.progress = ok ? 100 : rec.progress;
    rec.completedMs = Date.now();
    rec.error = error || "";
    W.emitJob(rec);
    return rec;
  };

  // Failure messages carry a machine code as "CODE|human message" — the C++
  // side splits them into PrintResult.errorCode / errorMessage.
  W.rawDone = function(port, ok, msg) {
    var rec = W.finishJob(port, ok, ok ? "" : msg);
    if (port < 0n) {
      // -1..-999999: batch-item sentinels; below that: resume re-dispatches
      // (tracked purely through job events).
      if (port > -1000000n && W.batchDone) W.batchDone(ok ? 1 : 0);
      return;
    }
    if (ok && rec && !msg) msg = rec.id;
    wasmExports.nitro_printing_web_raw_done(port, ok ? 1 : 0, W.cstr(msg || ""));
  };
  // Resume = re-dispatch a finished raw job's kept payload. True when the
  // retry started; completion arrives via onPrintJobChanged.
  W.resumeJob = function(port, jobId) {
    for (var rec of W.cache.jobs) {
      if (rec.id !== jobId) continue;
      if (rec.state < 2 || !rec.retry) break; // still running or nothing kept
      rec.state = 1;
      rec.error = "";
      rec.completedMs = 0;
      W.emitJob(rec);
      var synth = -1000000n - BigInt(++W.jobSeq);
      W.jobsByPort.set(synth, rec);
      W.dispatchRaw(synth, rec.retry.bytes, rec.retry.printerId,
                    rec.retry.copies, rec.retry.timeoutMs);
      W.boolDone(port, 1);
      return;
    }
    W.boolDone(port, 0);
  };
  W.boolDone = function(port, v) {
    wasmExports.nitro_printing_web_bool_done(port, v ? 1 : 0);
  };

  //── Hidden-iframe dialog printing ──────────────────────────────────────
  //dialogMs = how long the dialog stayed open (heuristic Print-vs-Cancel
  //signal; the platform reveals nothing definitive).
  //restoreAfterDialog returns focus to the page and re-kicks Flutter's
  //renderer after the dialog closes.
  W.restoreAfterDialog = function(frame) {
    var kick = function() {
      try { if (frame) frame.blur(); } catch (e) {}
      try { window.focus(); } catch (e) {}
      try { window.dispatchEvent(new Event('resize')); } catch (e) {}
      var glass = document.querySelector('flt-glass-pane') || document.querySelector('flutter-view');
      try { if (glass && glass.focus) glass.focus(); } catch (e) {}
    };
    kick();
    setTimeout(kick, 250);
  };
  W.printFrame = function(port, kind, timeoutMs, setup) {
    var fired = false;
    var frame = null;
    var dialogMs = 0;
    var rec = W.newJob(port, "", kind === 1 ? 'print dialog' : "");
    var done = function(ok) {
      if (fired) return;
      fired = true;
      //Completion runs in a fresh task, never inside the afterprint/print() stack.
      setTimeout(function() {
        W.restoreAfterDialog(frame);
        setTimeout(function() { try { if (frame) frame.remove(); } catch (e) {} }, 400);
        //Print-vs-Cancel is unknowable; mark the job outcome unknown.
        W.finishJob(port, ok,
            ok ? '[DIALOG_OUTCOME_UNKNOWN] dialogMs=' + Math.round(dialogMs)
               : 'DIALOG_FAILED|Browser print failed or timed out');
        wasmExports.nitro_printing_web_done(port, kind, ok ? 1 : 0, W.cstr(rec.id),
                                            Math.round(dialogMs));
      }, 0);
    };
    try {
      frame = document.createElement('iframe');
      frame.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden;';
      document.body.appendChild(frame);
      var loadTimer = setTimeout(function() { done(0); }, timeoutMs);
      setup(frame, function() {
        try {
          //Stop the load timeout once print() is reached; the dialog may stay open
          //indefinitely.
          clearTimeout(loadTimer);
          frame.contentWindow.focus();
          var t0 = performance.now();
          var sawAfterprint = false;
          //afterprint fires when the dialog closes (Print or Cancel). Chromium 127+
          //can return from print() before the dialog closes (crbug 357784797), so
          //return timing alone is unreliable.
          try {
            frame.contentWindow.addEventListener('afterprint', function() {
              sawAfterprint = true;
              dialogMs = performance.now() - t0;
              if (!fired) {
                done(1);
              } else if (rec) {
                //Already reported via the grace fallback; correct the job's dialog time.
                rec.error = '[DIALOG_OUTCOME_UNKNOWN] dialogMs=' + Math.round(dialogMs);
                W.emitJob(rec);
              }
            });
          } catch (e2) {}
          frame.contentWindow.print();
          dialogMs = performance.now() - t0;
          //No afterprint within the grace period (headless no-op print): complete
          //with the return-timing measurement.
          setTimeout(function() { if (!sawAfterprint) done(1); }, 250);
        } catch (e) { done(0); }
      });
    } catch (e) { done(0); }
  };
  //Definitive outcome from the app (user confirmation / out-of-band signal).
  W.markJobOutcome = function(jobId, printed) {
    for (var rec of W.cache.jobs) {
      if (rec.id !== jobId) continue;
      if (rec.state < 2) return false; // still running
      rec.state = printed ? 2 : 3;
      rec.progress = printed ? 100 : rec.progress;
      rec.error = printed ? '[USER_CONFIRMED] printed'
                          : '[JOB_CANCELLED] user confirmed cancelled';
      W.emitJob(rec);
      return true;
    }
    return false;
  };
  W.printHtml = function(port, kind, html) {
    W.printFrame(port, kind, 5000, function(frame, ready) {
      frame.onload = ready;
      frame.srcdoc = html;
    });
  };
  W.printBlobUrl = function(port, kind, url, asImage) {
    W.printFrame(port, kind, 8000, function(frame, ready) {
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
  // ── PrintSettings → rendered page options ──────────────────────────────
  // opts row: sizeCss, marginCss, gray, copies, fit, header, footer, from,
  //           to, jobName, pagesPerSheet, collate
  W.parseOpts = function(optsStr) {
    var a = (optsStr || "").split('\x1F');
    return { size: a[0] || "", margin: a[1] || "", gray: a[2] === '1',
             copies: Math.max(1, +a[3] || 1), fit: a[4] === '1',
             header: a[5] || "", footer: a[6] || "",
             from: +a[7] || 0, to: +a[8] || 0,
             title: a[9] || "", nup: Math.max(1, +a[10] || 1),
             collate: a[11] !== '0' };
  };
  // Expands logical pages by copies: collated repeats the document
  // (1,2,1,2); uncollated repeats each page in place (1,1,2,2).
  W.applyCopies = function(pages, o) {
    if (o.copies <= 1) return pages;
    var out = [];
    if (o.collate) {
      for (var c = 0; c < o.copies; c++) out = out.concat(pages);
    } else {
      for (var p of pages) {
        for (var c2 = 0; c2 < o.copies; c2++) out.push(p);
      }
    }
    return out;
  };
  W.pageCss = function(o) {
    var css = "";
    if (o.size || o.margin) {
      css += '@page{' + (o.size ? 'size:' + o.size + ';' : "") +
          (o.margin ? 'margin:' + o.margin + ';' : "") + '}';
    }
    css += '.pg{break-after:page;}';
    css += 'body{margin:' + (o.margin ? '0' : '24px') + ';font:14px/1.4 monospace;}';
    if (o.gray) css += 'html{filter:grayscale(1);}';
    css += '.hdr,.ftr{font:11px sans-serif;color:#444;}';
    css += '.nup{display:grid;gap:8pt;align-content:start;}';
    css += '.cell{overflow:hidden;border:0.5pt solid #bbb;padding:4pt;}';
    return '<style>' + css + '</style>';
  };
  W.escHtml = function(s) {
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  };
  // Page decoration (set from Dart via WebPrintDecor → globalThis):
  // { background, header, footer } as raw HTML. headerText/footerText that
  // start with '<' are also treated as HTML rather than escaped.
  W.decor = function() { return globalThis.__nitroWebDecor || {}; };
  W.decorPart = function(cls, htmlOverride, text) {
    var content = htmlOverride ? htmlOverride
        : text ? (text.charAt(0) === '<' ? text : W.escHtml(text)) : "";
    return content ? '<div class="' + cls + '">' + content + '</div>' : "";
  };
  // Wraps a logical-page's inner markup with the optional header/footer.
  W.decoratePage = function(inner, o) {
    var d = W.decor();
    return W.decorPart('hdr', d.header, o.header) + inner +
        W.decorPart('ftr', d.footer, o.footer);
  };
  //position:fixed repeats on every printed page.
  W.backgroundDiv = function() {
    var d = W.decor();
    if (!d.background) return "";
    return '<div style="position:fixed;inset:0;z-index:-1;pointer-events:none">' +
        d.background + '</div>';
  };
  //N-up: groups logical pages into physical sheets (grid, font scaled by row
  //count) — one HTML string per physical page. Shared by the dialog document
  //and the preview raster.
  W.physicalPages = function(pages, o) {
    if (o.nup <= 1) return pages;
    var cols = o.nup === 2 ? 2 : Math.ceil(Math.sqrt(o.nup));
    var rows = Math.ceil(o.nup / cols);
    var out = [];
    for (var i = 0; i < pages.length; i += o.nup) {
      var body = '<div class="nup" style="display:grid;gap:8pt;align-content:start;' +
          'grid-template-columns:repeat(' + cols + ',1fr)">';
      for (var j = i; j < Math.min(i + o.nup, pages.length); j++) {
        body += '<div class="cell" style="font-size:' + Math.round(100 / rows) +
            '%;overflow:hidden;border:0.5pt solid #bbb;padding:4pt">' + pages[j] + '</div>';
      }
      out.push(body + '</div>');
    }
    return out;
  };
  W.assemblePages = function(pages, o) {
    var phys = W.physicalPages(pages, o);
    return '<html><head>' +
        (o.title ? '<title>' + W.escHtml(o.title) + '</title>' : "") +
        W.pageCss(o) + '</head><body>' + W.backgroundDiv() +
        phys.map(function(p) { return '<div class="pg">' + p + '</div>'; }).join("") +
        '</body></html>';
  };
  // Plain text: hard-paginated at 60 lines/page (matches the wasm PDF
  // renderer), honoring pageRange, header/footer, copies, and N-up.
  W.textLogicalPages = function(text, o) {
    var lines = text.split('\n');
    var pages = [];
    for (var i = 0; i < lines.length || pages.length === 0; i += 60) {
      pages.push(lines.slice(i, i + 60));
    }
    var from = o.from > 0 ? o.from : 1;
    var to = o.to > 0 ? Math.min(o.to, pages.length) : pages.length;
    var chosen = from <= to ? pages.slice(from - 1, to) : [];
    if (!chosen.length) chosen = [[]];
    return chosen.map(function(p) {
      return W.decoratePage(
          '<pre style="white-space:pre-wrap;margin:0;font:inherit">' +
          W.escHtml(p.join('\n')) + '</pre>', o);
    });
  };
  W.textPagesHtml = function(text, o) {
    return W.assemblePages(W.applyCopies(W.textLogicalPages(text, o), o), o);
  };

  // ── Page-accurate preview raster ───────────────────────────────────────
  // Renders ONE physical page (fixed page-sized box, margins as padding,
  // grayscale filter, background decor) to a JPEG through SVG foreignObject.
  W.renderPageJpeg = async function(pageInner, o, pageWpt, pageHpt) {
    var PXPT = 2; // 2 px per pt for sharpness
    var wpx = Math.round(pageWpt * PXPT), hpx = Math.round(pageHpt * PXPT);
    var pad = o.margin || '30pt 30pt 30pt 30pt';
    var d = W.decor();
    var bg = d.background
        ? '<div style="position:absolute;inset:0;z-index:0;pointer-events:none">' + d.background + '</div>'
        : "";
    var page = '<div style="width:' + pageWpt + 'pt;height:' + pageHpt + 'pt;' +
        'background:#fff;position:relative;box-sizing:border-box;padding:' + pad +
        ';font:14px/1.4 monospace;overflow:hidden' +
        (o.gray ? ';filter:grayscale(1)' : "") + '">' + bg +
        '<div style="position:relative;height:100%">' + pageInner + '</div></div>';
    // foreignObject needs well-formed XML — round-trip through the DOM.
    // (No regex literals in EM_JS: macro stringification mangles them.)
    var parsed = new DOMParser().parseFromString(page, 'text/html');
    var xhtml = new XMLSerializer().serializeToString(parsed.body);
    xhtml = '<div' + xhtml.slice(5, xhtml.lastIndexOf('</body>')) + '</div>';
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="' + wpx + '" height="' + hpx +
        '"><foreignObject width="100%" height="100%">' +
        '<div xmlns="http://www.w3.org/1999/xhtml" style="transform:scale(' + PXPT +
        ');transform-origin:0 0">' +
        '<style>.hdr,.ftr{font:11px sans-serif;color:#444}</style>' +
        xhtml + '</div></foreignObject></svg>';
    var img = new Image();
    var loaded = new Promise(function(res, rej) { img.onload = res; img.onerror = rej; });
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
    await loaded;
    var canvas = new OffscreenCanvas(wpx, hpx);
    var ctx = canvas.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, wpx, hpx);
    ctx.drawImage(img, 0, 0);
    var blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.92 });
    return { w: wpx, h: hpx, bytes: new Uint8Array(await blob.arrayBuffer()) };
  };
  //Text preview: same logical→copies→N-up pipeline as the dialog, one JPEG
  //per physical sheet.
  W.textPreviewJpegs = async function(port, text, optsStr, pageWpt, pageHpt) {
    var fired = false;
    var fail = function() {
      if (fired) return;
      fired = true;
      wasmExports.nitro_printing_web_html_jpegs(port, 0, 0);
    };
    setTimeout(fail, 10000);
    try {
      var o = W.parseOpts(optsStr);
      var phys = W.physicalPages(W.applyCopies(W.textLogicalPages(text, o), o), o);
      //Preview caps at 40 sheets.
      if (phys.length > 40) phys = phys.slice(0, 40);
      var slices = [];
      var total = 0;
      for (var pg of phys) {
        var s = await W.renderPageJpeg(pg, o, pageWpt, pageHpt);
        slices.push(s);
        total += s.bytes.length;
      }
      if (fired) return;
      fired = true;
      var headLen = 4 + slices.length * 12;
      var pack = new Uint8Array(headLen + total);
      var dv = new DataView(pack.buffer);
      dv.setUint32(0, slices.length, true);
      var off = headLen;
      for (var k = 0; k < slices.length; k++) {
        dv.setUint32(4 + k * 12, slices[k].w, true);
        dv.setUint32(8 + k * 12, slices[k].h, true);
        dv.setUint32(12 + k * 12, slices[k].bytes.length, true);
        pack.set(slices[k].bytes, off);
        off += slices[k].bytes.length;
      }
      var p = wasmExports.malloc(pack.length);
      HEAPU8.set(pack, p);
      wasmExports.nitro_printing_web_html_jpegs(port, p, pack.length);
    } catch (e) { fail(); }
  };
  //User HTML passes through untouched unless settings or decor need the
  //page wrapper.
  W.htmlDocHtml = function(html, o) {
    var d = W.decor();
    if (!o.size && !o.margin && !o.gray && !o.title && !o.header && !o.footer &&
        o.copies === 1 && o.nup === 1 &&
        !d.background && !d.header && !d.footer) {
      return html;
    }
    var doc = W.assemblePages(W.applyCopies([W.decoratePage(html, o)], o), o);
    //position:fixed .hdr/.ftr repeat at the top/bottom of every printed page;
    //body padding keeps content clear of them.
    var hasH = !!(d.header || o.header), hasF = !!(d.footer || o.footer);
    if (hasH || hasF) {
      doc = doc.replace('</head>', '<style>' +
          (hasH ? '.hdr{position:fixed;top:0;left:0;right:0;}body{padding-top:28pt;}' : "") +
          (hasF ? '.ftr{position:fixed;bottom:0;left:0;right:0;}body{padding-bottom:28pt;}' : "") +
          '</style></head>');
    }
    return doc;
  };
  W.imgHtml = function(url, o) {
    var style = o.fit ? 'width:100%;height:auto' : 'max-width:100%';
    var page = W.decoratePage('<img src="' + url + '" style="' + style + '">', o);
    return W.assemblePages(W.applyCopies([page], o), o);
  };

  // ── WebUSB raw transport ───────────────────────────────────────────────
  W.usbId = function(d) {
    var hex = function(v) { return v.toString(16).padStart(4, '0'); };
    return 'usb:' + hex(d.vendorId) + ':' + hex(d.productId) +
        (d.serialNumber ? ':' + d.serialNumber : "");
  };
  W.usbFind = async function(printerId) {
    if (!navigator.usb) return null;
    var devices = await navigator.usb.getDevices();
    if (!devices.length) return null;
    if (!printerId || printerId.indexOf('usb:') !== 0) return devices[0];
    for (var d of devices) {
      if (W.usbId(d).indexOf(printerId) === 0 || printerId.indexOf(W.usbId(d)) === 0) return d;
    }
    return null;
  };
  // Locates a claimable bulk-OUT endpoint (printer class 7 preferred).
  W.usbEndpoint = function(device) {
    var fallback = null;
    for (var config of device.configurations) {
      for (var iface of config.interfaces) {
        for (var alt of iface.alternates) {
          for (var ep of alt.endpoints) {
            if (ep.direction === 'out' && ep.type === 'bulk') {
              var m = { conf: config.configurationValue, iface: iface.interfaceNumber,
                        alt: alt.alternateSetting, ep: ep.endpointNumber };
              if (alt.interfaceClass === 7) return m;
              if (!fallback) fallback = m;
            }
          }
        }
      }
    }
    return fallback;
  };
  W.usbPrint = async function(port, bytes, copies, printerId) {
    var device = null;
    try {
      device = await W.usbFind(printerId);
      if (!device) {
        W.rawDone(port, 0, 'NO_USB_DEVICE|No granted USB printer' +
            (printerId ? ' matching "' + printerId + '"' : "") +
            ' — call startPrinterDiscovery() from a user gesture to grant one');
        return;
      }
      var target = W.usbEndpoint(device);
      if (!target) { W.rawDone(port, 0, 'USB_NO_ENDPOINT|USB device has no bulk-OUT endpoint'); return; }
      await device.open();
      if (device.configuration == null ||
          device.configuration.configurationValue !== target.conf) {
        await device.selectConfiguration(target.conf);
      }
      await device.claimInterface(target.iface);
      if (target.alt) await device.selectAlternateInterface(target.iface, target.alt);
      var cancelled = false;
      W.rawAbort = function() { cancelled = true; };
      var CHUNK = 16384;
      for (var c = 0; c < copies && !cancelled; c++) {
        for (var off = 0; off < bytes.length && !cancelled; off += CHUNK) {
          var r = await device.transferOut(target.ep, bytes.subarray(off, off + CHUNK));
          if (r.status !== 'ok') { W.rawDone(port, 0, 'USB_TRANSFER_FAILED|USB transfer ' + r.status); return; }
        }
      }
      W.rawAbort = null;
      try { await device.releaseInterface(target.iface); await device.close(); } catch (e) {}
      if (cancelled) W.rawDone(port, 0, 'CANCELLED|Cancelled');
      else W.rawDone(port, 1, "");
    } catch (e) {
      W.rawAbort = null;
      try { if (device) await device.close(); } catch (e2) {}
      W.rawDone(port, 0, 'USB_FAILED|WebUSB: ' + (e && e.message ? e.message : e));
    }
  };

  // ── WebSocket relay transport (websockify → printer TCP port) ──────────
  W.wsPrint = function(port, bytes, copies, url, timeoutMs) {
    var ws = null;
    var fired = false;
    var done = function(ok, msg) {
      if (fired) return;
      fired = true;
      W.rawAbort = null;
      try { if (ws) ws.close(); } catch (e) {}
      W.rawDone(port, ok, msg);
    };
    setTimeout(function() { done(0, 'RELAY_TIMEOUT|WebSocket relay timeout'); }, timeoutMs);
    try {
      ws = new WebSocket(url);
      ws.binaryType = 'arraybuffer';
      W.rawAbort = function() { done(0, 'CANCELLED|Cancelled'); };
      ws.onerror = function() { done(0, 'RELAY_FAILED|WebSocket relay connection failed'); };
      ws.onopen = function() {
        try {
          for (var c = 0; c < copies; c++) ws.send(bytes);
          var waitDrain = function() {
            if (fired) return;
            if (ws.bufferedAmount === 0) done(1, "");
            else setTimeout(waitDrain, 50);
          };
          waitDrain();
        } catch (e) { done(0, 'RELAY_FAILED|WebSocket send failed: ' + e.message); }
      };
    } catch (e) { done(0, 'RELAY_FAILED|WebSocket: ' + e.message); }
  };

  // ── Direct Sockets TCP transport (Isolated Web Apps, Chrome 147+) ──────
  W.tcpPrint = async function(port, bytes, copies, host, tcpPort, timeoutMs) {
    if (typeof TCPSocket === 'undefined') {
      W.rawDone(port, 0, 'TCP_UNAVAILABLE|Raw TCP needs an Isolated Web App (Direct Sockets) — ' +
          'or use a ws://host:port relay printerId');
      return;
    }
    var socket = null;
    var timer = setTimeout(function() {
      try { if (socket) socket.close(); } catch (e) {}
    }, timeoutMs);
    try {
      socket = new TCPSocket(host, tcpPort);
      var info = await socket.opened;
      var writer = info.writable.getWriter();
      var cancelled = false;
      W.rawAbort = function() { cancelled = true; try { socket.close(); } catch (e) {} };
      for (var c = 0; c < copies && !cancelled; c++) await writer.write(bytes);
      await writer.close();
      clearTimeout(timer);
      W.rawAbort = null;
      W.rawDone(port, cancelled ? 0 : 1, cancelled ? 'CANCELLED|Cancelled' : "");
    } catch (e) {
      clearTimeout(timer);
      W.rawAbort = null;
      W.rawDone(port, 0, 'TCP_FAILED|TCP: ' + (e && e.message ? e.message : e));
    }
  };

  // ── Web Serial transport (serial-attached receipt printers) ────────────
  // printerId "serial:" uses the first granted port; "serial:<baud>" sets the
  // baud rate (default 9600).
  W.serialPrint = async function(port, bytes, copies, printerId) {
    if (!navigator.serial) {
      W.rawDone(port, 0, 'WEB_SERIAL_UNAVAILABLE|Web Serial is not available in this browser');
      return;
    }
    var sp = null;
    try {
      var ports = await navigator.serial.getPorts();
      if (!ports.length) {
        W.rawDone(port, 0, 'NO_SERIAL_DEVICE|No granted serial printer — call startPrinterDiscovery() from a user gesture to grant one');
        return;
      }
      sp = ports[0];
      var baud = parseInt(printerId.slice(7), 10) || 9600;
      await sp.open({ baudRate: baud });
      var writer = sp.writable.getWriter();
      var cancelled = false;
      W.rawAbort = function() { cancelled = true; };
      for (var c = 0; c < copies && !cancelled; c++) await writer.write(bytes);
      writer.releaseLock();
      await sp.close();
      W.rawAbort = null;
      W.rawDone(port, cancelled ? 0 : 1, cancelled ? 'CANCELLED|Cancelled' : "");
    } catch (e) {
      W.rawAbort = null;
      try { if (sp) await sp.close(); } catch (e2) {}
      W.rawDone(port, 0, 'SERIAL_FAILED|Web Serial: ' + (e && e.message ? e.message : e));
    }
  };

  // ── Web Bluetooth transport (BLE thermal printers) ─────────────────────
  // Known transparent-UART service UUIDs used by common thermal printers.
  W.bleServices = [
    0x18f0,
    '49535343-fe7d-4ae5-8fa9-9fafd205e455',
    'e7810a71-73ae-499d-8c15-faa9aef0c3f2',
    '0000ff00-0000-1000-8000-00805f9b34fb',
  ];
  W.blePrint = async function(port, bytes, copies, printerId) {
    if (!navigator.bluetooth || !navigator.bluetooth.getDevices) {
      W.rawDone(port, 0, 'WEB_BLUETOOTH_UNAVAILABLE|Web Bluetooth is not available in this browser');
      return;
    }
    var server = null;
    try {
      var devices = await navigator.bluetooth.getDevices();
      var name = printerId.slice(4);
      var device = devices.find(function(d) { return !name || (d.name || "").indexOf(name) >= 0; });
      if (!device) {
        W.rawDone(port, 0, 'NO_BLE_DEVICE|No granted Bluetooth printer — call startPrinterDiscovery() from a user gesture to grant one');
        return;
      }
      server = await device.gatt.connect();
      var ch = null;
      var services = await server.getPrimaryServices();
      for (var svc of services) {
        var chars = await svc.getCharacteristics();
        for (var c2 of chars) {
          if (c2.properties.writeWithoutResponse || c2.properties.write) { ch = c2; break; }
        }
        if (ch) break;
      }
      if (!ch) { server.disconnect(); W.rawDone(port, 0, 'BLE_NO_CHARACTERISTIC|BLE printer exposes no writable characteristic'); return; }
      var cancelled = false;
      W.rawAbort = function() { cancelled = true; };
      var CHUNK = 180; // conservative BLE ATT payload
      for (var c3 = 0; c3 < copies && !cancelled; c3++) {
        for (var off = 0; off < bytes.length && !cancelled; off += CHUNK) {
          var part = bytes.subarray(off, off + CHUNK);
          if (ch.properties.writeWithoutResponse) await ch.writeValueWithoutResponse(part);
          else await ch.writeValueWithResponse(part);
        }
      }
      server.disconnect();
      W.rawAbort = null;
      W.rawDone(port, cancelled ? 0 : 1, cancelled ? 'CANCELLED|Cancelled' : "");
    } catch (e) {
      W.rawAbort = null;
      try { if (server) server.disconnect(); } catch (e2) {}
      W.rawDone(port, 0, 'BLE_FAILED|Web Bluetooth: ' + (e && e.message ? e.message : e));
    }
  };

  // ── Raw transport router (shared by direct calls, images, and batches) ─
  W.routeRaw = function(port, bytes, printerId, copies, timeoutMs) {
    var rec = W.newJob(port, printerId, "");
    //Keep the payload (most recent only) so a failed job can be resumed.
    rec.retry = { bytes: bytes, printerId: printerId, copies: copies, timeoutMs: timeoutMs };
    var kept = 0;
    for (var i = W.cache.jobs.length - 1; i >= 0; i--) {
      if (W.cache.jobs[i].retry && ++kept > 20) delete W.cache.jobs[i].retry;
    }
    W.dispatchRaw(port, bytes, printerId, copies, timeoutMs);
  };
  W.dispatchRaw = function(port, bytes, printerId, copies, timeoutMs) {
    if (printerId.indexOf('ws://') === 0 || printerId.indexOf('wss://') === 0) {
      W.wsPrint(port, bytes, copies, printerId, timeoutMs);
    } else if (printerId.indexOf('serial:') === 0) {
      W.serialPrint(port, bytes, copies, printerId);
    } else if (printerId.indexOf('ble:') === 0) {
      W.blePrint(port, bytes, copies, printerId);
    } else if (printerId.indexOf('qz:') === 0) {
      W.qzPrint(port, bytes, printerId, copies, false);
    } else if (printerId.indexOf('agent:') === 0) {
      W.agentPrint(port, 'raw', bytes, printerId, copies);
    } else if (printerId === "" || printerId.indexOf('usb:') === 0) {
      W.usbPrint(port, bytes, copies, printerId);
    } else {
      var hp = W.parseHostPort(printerId);
      W.tcpPrint(port, bytes, copies, hp.host, hp.port, timeoutMs);
    }
  };

  // ── ESC/POS raster image (GS v 0) ──────────────────────────────────────
  // Decodes the image, scales to the printer's dot width, Bayer-dithers to
  // 1-bit, and wraps in init + raster + feed/cut.
  W.imageEscPos = async function(port, bytes, printerId, copies, timeoutMs, widthDots) {
    try {
      var bitmap = await createImageBitmap(new Blob([bytes]));
      var w = Math.min(bitmap.width, widthDots || 384);
      var h = Math.max(1, Math.round(bitmap.height * (w / bitmap.width)));
      var canvas = new OffscreenCanvas(w, h);
      var ctx = canvas.getContext('2d');
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, w, h);
      ctx.drawImage(bitmap, 0, 0, w, h);
      var px = ctx.getImageData(0, 0, w, h).data;
      var bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];
      var rowBytes = Math.ceil(w / 8);
      var raster = new Uint8Array(rowBytes * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          var i = (y * w + x) * 4;
          var lum = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
          var threshold = (bayer[y & 3][x & 3] + 0.5) * 16;
          if (lum < threshold) { // dark → print dot
            raster[y * rowBytes + (x >> 3)] |= 0x80 >> (x & 7);
          }
        }
      }
      var head = [0x1B, 0x40, 0x1D, 0x76, 0x30, 0x00,
                  rowBytes & 0xff, (rowBytes >> 8) & 0xff, h & 0xff, (h >> 8) & 0xff];
      var tail = [0x1B, 0x64, 4, 0x1D, 0x56, 0x42, 0];
      var job = new Uint8Array(head.length + raster.length + tail.length);
      job.set(head, 0);
      job.set(raster, head.length);
      job.set(tail, head.length + raster.length);
      W.routeRaw(port, job, printerId, copies, timeoutMs);
    } catch (e) {
      W.rawDone(port, 0, 'IMAGE_DECODE_FAILED|Image raster failed: ' + (e && e.message ? e.message : e));
    }
  };

  //── HTML rasterization (SVG foreignObject → canvas → JPEG page slices) ─
  //Slices pack as [u32 count][u32 w,h,len]×count + JPEG payloads →
  //nitro_printing_web_html_jpegs (ptr 0 on failure). External images/fonts
  //do not load inside the SVG sandbox.
  //fragToImage renders an HTML fragment to an Image at a fixed width
  //(height measured off-screen unless given).
  W.fragToImage = async function(fragHtml, wpx, hpx) {
    var parsed = new DOMParser().parseFromString(fragHtml, 'text/html');
    var xhtml = new XMLSerializer().serializeToString(parsed.body);
    var h = hpx;
    if (!h) {
      var holder = document.createElement('div');
      holder.style.cssText = 'position:fixed;left:-99999px;top:0;width:' + wpx + 'px;';
      holder.innerHTML = parsed.body.innerHTML;
      document.body.appendChild(holder);
      h = Math.max(holder.scrollHeight, 1);
      holder.remove();
    }
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="' + wpx +
        '" height="' + h + '"><foreignObject width="100%" height="100%">' +
        xhtml.replace('<body', '<body style="margin:0;width:' + wpx + 'px"') +
        '</foreignObject></svg>';
    var img = new Image();
    var loaded = new Promise(function(res, rej) { img.onload = res; img.onerror = rej; });
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
    await loaded;
    return { img: img, h: h };
  };
  W.htmlToJpegs = async function(port, html, pageWpt, pageHpt, optsStr) {
    var o = W.parseOpts(optsStr || "");
    var d = W.decor();
    var fired = false;
    var fail = function() {
      if (fired) return;
      fired = true;
      wasmExports.nitro_printing_web_html_jpegs(port, 0, 0);
    };
    // Watchdog: an SVG image that never loads must still complete the future.
    setTimeout(fail, 10000);
    try {
      var PXPT = 2; // render at 2 px per pt for sharpness
      var contentWpx = Math.max(64, Math.round((pageWpt - 80) * PXPT));
      var sliceHpx = Math.max(64, Math.round((pageHpt - 80) * PXPT));
      var gray = function(s) {
        return o.gray && s ? '<div style="filter:grayscale(1)">' + s + '</div>' : s;
      };
      var style = '<style>.hdr,.ftr{font:11px sans-serif;color:#444}</style>';
      //Header, footer, and background composite onto every page (top / bottom /
      //behind), matching the dialog output.
      var hdrHtml = W.decorPart('hdr', d.header, o.header);
      var ftrHtml = W.decorPart('ftr', d.footer, o.footer);
      var hdr = hdrHtml ? await W.fragToImage(style + gray(hdrHtml), contentWpx) : null;
      var ftr = ftrHtml ? await W.fragToImage(style + gray(ftrHtml), contentWpx) : null;
      var bg = d.background
          ? await W.fragToImage(gray('<div style="width:' + contentWpx + 'px;height:' +
              sliceHpx + 'px;overflow:hidden">' + d.background + '</div>'), contentWpx, sliceHpx)
          : null;
      var body = await W.fragToImage(gray(html), contentWpx);
      var hdrH = hdr ? hdr.h : 0;
      var ftrH = ftr ? ftr.h : 0;
      var contentHpx = Math.max(64, sliceHpx - hdrH - ftrH);
      var sliceCount = Math.max(1, Math.ceil(body.h / contentHpx));
      var slices = [];
      var total = 0;
      for (var s = 0; s < sliceCount; s++) {
        var y = s * contentHpx;
        var hpx = Math.min(contentHpx, body.h - y);
        if (hpx <= 0 && s > 0) break;
        var canvas = new OffscreenCanvas(contentWpx, sliceHpx);
        var ctx = canvas.getContext('2d');
        ctx.fillStyle = '#fff';
        ctx.fillRect(0, 0, contentWpx, sliceHpx);
        if (bg) ctx.drawImage(bg.img, 0, 0);
        if (hdr) ctx.drawImage(hdr.img, 0, 0);
        if (hpx > 0) ctx.drawImage(body.img, 0, y, contentWpx, hpx, 0, hdrH, contentWpx, hpx);
        if (ftr) ctx.drawImage(ftr.img, 0, sliceHpx - ftrH);
        var blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.92 });
        var jb = new Uint8Array(await blob.arrayBuffer());
        slices.push({ w: contentWpx, h: sliceHpx, bytes: jb });
        total += jb.length;
      }
      var headLen = 4 + slices.length * 12;
      var pack = new Uint8Array(headLen + total);
      var dv = new DataView(pack.buffer);
      dv.setUint32(0, slices.length, true);
      var off = headLen;
      for (var k = 0; k < slices.length; k++) {
        dv.setUint32(4 + k * 12, slices[k].w, true);
        dv.setUint32(8 + k * 12, slices[k].h, true);
        dv.setUint32(12 + k * 12, slices[k].bytes.length, true);
        pack.set(slices[k].bytes, off);
        off += slices[k].bytes.length;
      }
      if (fired) return; // watchdog already reported
      fired = true;
      var p = wasmExports.malloc(pack.length);
      HEAPU8.set(pack, p);
      wasmExports.nitro_printing_web_html_jpegs(port, p, pack.length);
    } catch (e) { fail(); }
  };

  //── mDNS discovery over Direct Sockets UDP (Isolated Web Apps) ─────────
  //One-shot QU query for IPP/raw services; parses PTR/SRV/A. Skipped without
  //bound-mode UDPSocket.
  W.mdnsDiscover = async function() {
    if (typeof UDPSocket === 'undefined') return false;
    try {
      var names = ['_ipp._tcp.local', '_pdl-datastream._tcp.local', '_printer._tcp.local'];
      // Header: id=0, flags=0, qdcount=names.length, an/ns/ar=0.
      var bytes = [0, 0, 0, 0, 0, names.length, 0, 0, 0, 0, 0, 0];
      for (var nm of names) {
        for (var label of nm.split('.')) {
          bytes.push(label.length);
          for (var ci = 0; ci < label.length; ci++) bytes.push(label.charCodeAt(ci));
        }
        bytes.push(0);
        bytes.push(0, 12);       // QTYPE PTR
        bytes.push(0x80, 0x01);  // QU bit + class IN
      }
      var socket = new UDPSocket({ localAddress: '0.0.0.0' });
      var info = await socket.opened;
      var writer = info.writable.getWriter();
      await writer.write({ data: new Uint8Array(bytes), remoteAddress: '224.0.0.251', remotePort: 5353 });
      var reader = info.readable.getReader();
      var deadline = Date.now() + 3000;
      var found = false;
      while (Date.now() < deadline) {
        var race = await Promise.race([
          reader.read(),
          new Promise(function(res) { setTimeout(function() { res({ timeout: true }); }, deadline - Date.now()); }),
        ]);
        if (race.timeout || race.done) break;
        var rows = W.parseMdns(new Uint8Array(race.value.data), race.value.remoteAddress);
        for (var row of rows) {
          found = true;
          wasmExports.nitro_printing_web_discovered(W.cstr(row));
        }
      }
      try { reader.releaseLock(); socket.close(); } catch (e) {}
      return found;
    } catch (e) { return false; }
  };
  // Minimal DNS answer parser: name (with compression), SRV port, A address.
  W.parseMdns = function(d, fromAddr) {
    try {
      var readName = function(pos) {
        var parts = [];
        var jumps = 0;
        while (pos < d.length && jumps < 8) {
          var len = d[pos];
          if (len === 0) { pos++; break; }
          if ((len & 0xc0) === 0xc0) { pos = ((len & 0x3f) << 8) | d[pos + 1]; jumps++; continue; }
          parts.push(String.fromCharCode.apply(null, d.subarray(pos + 1, pos + 1 + len)));
          pos += len + 1;
        }
        return parts.join('.');
      };
      var skipName = function(pos) {
        while (pos < d.length) {
          var len = d[pos];
          if (len === 0) return pos + 1;
          if ((len & 0xc0) === 0xc0) return pos + 2;
          pos += len + 1;
        }
        return pos;
      };
      var qd = (d[4] << 8) | d[5];
      var counts = ((d[6] << 8) | d[7]) + ((d[8] << 8) | d[9]) + ((d[10] << 8) | d[11]);
      var pos = 12;
      for (var i = 0; i < qd; i++) pos = skipName(pos) + 4;
      var instance = "", host = fromAddr, svcPort = 631, svc = 'ipp';
      for (var a = 0; a < counts && pos + 10 < d.length; a++) {
        var namePos = pos;
        pos = skipName(pos);
        var type = (d[pos] << 8) | d[pos + 1];
        var rdlen = (d[pos + 8] << 8) | d[pos + 9];
        var rd = pos + 10;
        if (type === 12) {        // PTR → instance name
          instance = readName(rd).split('._')[0];
        } else if (type === 33) { // SRV → port + target
          svcPort = (d[rd + 4] << 8) | d[rd + 5];
          var svcName = readName(namePos);
          if (svcName.indexOf('_pdl-datastream') >= 0) svc = 'socket';
          else if (svcName.indexOf('_printer') >= 0) svc = 'lpd';
        } else if (type === 1 && rdlen === 4) { // A → IPv4
          host = d[rd] + '.' + d[rd + 1] + '.' + d[rd + 2] + '.' + d[rd + 3];
        }
        pos = rd + rdlen;
      }
      if (!instance && !host) return [];
      var id = (svc === 'socket' ? 'socket://' : 'ipp://') + host + ':' + svcPort;
      return [[id, instance || host, host, String(svcPort), '_' + svc + '._tcp', id, '1'].join('\x1F')];
    } catch (e) { return []; }
  };

  // ── Web Printing status poller (emits onPrinterStatusChanged) ──────────
  W.startStatusPoll = function() {
    if (W.statusPoll || !W.wp()) return;
    W.statusPoll = setInterval(async function() {
      for (var id of W.cache.printers) {
        var p = W.cache['wpPrinter:' + id];
        if (!p) continue;
        try {
          var attrs = await p.fetchAttributes();
          var state = String(attrs['printer-state'] || 'idle');
          var reasons = (attrs['printer-state-reasons'] || []).join(',');
          var prev = W.cache.status[id] || {};
          if (prev.state !== state || prev.reasons !== reasons) {
            W.cache.status[id] = {
              online: state !== 'stopped', ready: state === 'idle',
              state: state, reasons: reasons,
              msg: attrs['printer-state-message'] || "",
            };
            var row = [id, state !== 'stopped' ? '1' : '0', state === 'processing' ? '1' : '0',
                       state, reasons].join('\x1F');
            wasmExports.nitro_printing_web_status_changed(W.cstr(row));
          }
        } catch (e) {}
      }
    }, 10000);
  };

  //── Nitro Print Agent (agent/ in this repo) ───────────────────────────
  //Localhost WebSocket over the plugin's native backends: {id, call, ...}
  //JSON frames, {event, data} pushes. printerId "agent:" / "agent:<printer id>".
  W.agent = { socket: null, ready: null, pending: new Map(), uidSeq: 0, printers: [] };
  W.agentEndpoints = function() {
    var o = globalThis.__nitroAgentEndpoint;
    return o ? [o] : ['ws://127.0.0.1:9629', 'ws://localhost:9629'];
  };
  W.agentReset = function() {
    try { if (W.agent.socket) W.agent.socket.close(); } catch (e) {}
    W.agent.socket = null;
    W.agent.ready = null;
    W.agent.pending.clear();
  };
  W.agentCall = function(msg, timeoutMs) {
    return new Promise(function(resolve, reject) {
      var id = 'a' + (++W.agent.uidSeq);
      msg.id = id;
      var timer = setTimeout(function() {
        W.agent.pending.delete(id);
        reject(new Error('agent call timed out: ' + msg.call));
      }, timeoutMs || 8000);
      W.agent.pending.set(id, function(reply) {
        clearTimeout(timer);
        W.agent.pending.delete(id);
        if (reply.error) reject(new Error(String(reply.error)));
        else resolve(reply.result);
      });
      W.agent.socket.send(JSON.stringify(msg));
    });
  };
  W.agentStateInt = function(name) {
    var map = { idle: 0, printing: 1, completed: 2, cancelled: 3, failed: 4, paused: 5 };
    return map[name] != null ? map[name] : 0;
  };
  W.agentEvent = function(m) {
    if (!m || !m.event) return;
    var d = m.data || {};
    if (m.event === 'printerStatus') {
      var id = 'agent:' + (d.printerId || "");
      W.cache.status[id] = { online: d.isOnline !== false, ready: d.isOnline !== false && !d.isPrinting,
                             state: d.isPrinting ? 'printing' : 'idle', reasons: "",
                             msg: d.statusMessage || "" };
      wasmExports.nitro_printing_web_status_changed(
          W.cstr([id, d.isOnline !== false ? '1' : '0', d.isPrinting ? '1' : '0',
                  d.statusMessage || "", d.errorCode || ""].join('')));
    } else if (m.event === 'job') {
      // Native job lifecycle from the agent, re-emitted on onPrintJobChanged.
      wasmExports.nitro_printing_web_job_changed(
          W.cstr([d.jobId || "", "", "", String(W.agentStateInt(d.state)),
                  String(d.progress || 0), '0', '0', d.message || "", '0'].join('')));
    }
  };
  W.agentConnect = function(timeoutMs) {
    if (W.agent.ready) return W.agent.ready;
    W.agent.ready = new Promise(function(resolve, reject) {
      var endpoints = W.agentEndpoints();
      var attempt = function(i) {
        if (i >= endpoints.length) {
          W.agent.ready = null;
          reject(new Error('agent not reachable'));
          return;
        }
        var ws;
        try { ws = new WebSocket(endpoints[i]); } catch (e) { attempt(i + 1); return; }
        var settled = false;
        var timer = setTimeout(function() {
          if (settled) return;
          settled = true;
          try { ws.close(); } catch (e) {}
          attempt(i + 1);
        }, timeoutMs || 1200);
        ws.onerror = function() {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          attempt(i + 1);
        };
        ws.onopen = async function() {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          W.agent.socket = ws;
          ws.onmessage = function(ev) {
            var m;
            try { m = JSON.parse(ev.data); } catch (e) { return; }
            if (m && m.id && W.agent.pending.has(m.id)) W.agent.pending.get(m.id)(m);
            else W.agentEvent(m);
          };
          ws.onclose = function() { W.agentReset(); };
          try {
            await W.agentCall({ call: 'version' }, 3000);
            resolve(ws);
          } catch (e) {
            W.agentReset();
            reject(e);
          }
        };
      };
      attempt(0);
    });
    return W.agent.ready;
  };
  W.agentErr = function(e) {
    var m = e && e.message ? e.message : String(e);
    if (m.indexOf('not reachable') >= 0) {
      return 'AGENT_UNAVAILABLE|Nitro Print Agent not reachable — start the agent app, or set WebPrintAgent.configure(agentEndpoint:)';
    }
    return 'AGENT_PRINT_FAILED|Print agent: ' + m;
  };
  // kind: raw|escpos|zpl|text|image|pdf. Success carries the NATIVE job id.
  W.agentPrint = async function(port, kind, bytes, printerId, copies) {
    try {
      await W.agentConnect(1500);
      var data = (kind === 'text' || kind === 'zpl')
          ? new TextDecoder().decode(bytes)
          : W.qzB64(bytes);
      var r = await W.agentCall({
        call: 'print', printer: printerId.slice(6), kind: kind,
        data: data, copies: copies > 1 ? copies : 1,
      }, 60000);
      if (r && r.success) {
        W.rawDone(port, 1, r.jobId || "");
      } else {
        var code = (r && r.errorCode) ? r.errorCode : 'AGENT_PRINT_FAILED';
        W.rawDone(port, 0, code + '|' + ((r && r.errorMessage) || 'print failed'));
      }
    } catch (e) {
      W.rawDone(port, 0, W.agentErr(e));
    }
  };
  W.agentDiscover = async function() {
    try {
      await W.agentConnect(1200);
      var printers = await W.agentCall({ call: 'printers' }, 8000);
      if (!Array.isArray(printers)) printers = [];
      W.agent.printers = printers;
      for (var p of printers) {
        var id = 'agent:' + p.id;
        if (W.cache.printers.indexOf(id) < 0) W.cache.printers.push(id);
        W.cache.caps[id] = { color: true, duplex: true, maxCopies: 999, dpi: 600,
                             a4: true, a5: true, letter: true, legal: true,
                             draft: true, normal: true, high: true, trays: "" };
        if (!W.cache.status[id]) {
          W.cache.status[id] = { online: p.isAvailable !== false, ready: true,
                                 state: 'idle', reasons: "", msg: 'agent printer' };
        }
        wasmExports.nitro_printing_web_discovered(
            W.cstr([id, p.name || p.id, 'localhost', '0', 'nitro-agent', id,
                    p.isAvailable !== false ? '1' : '0'].join('')));
      }
      return printers.length > 0;
    } catch (e) { return false; }
  };
  // Live status through the agent's native getPrinterStatusDetail.
  W.agentStatus = async function(printerId) {
    await W.agentConnect(1500);
    var d = await W.agentCall({ call: 'status', printer: printerId.slice(6) }, 8000);
    var reasons = d.hasPaperJam ? 'media-jam'
        : d.isOutOfPaper ? 'media-empty'
        : d.isOutOfInk ? 'toner-empty' : (d.stateReasons || "");
    W.cache.status['agent:' + (d.printerId || printerId.slice(6))] = {
      online: d.isOnline !== false, ready: d.isReady !== false,
      state: d.printerState || 'idle', reasons: reasons, msg: d.statusMessage || "",
    };
    return d;
  };

  //── QZ Tray local agent (https://github.com/qzind/tray) ────────────────
  //JSON calls {call, params, uid, timestamp} over WebSocket (wss:8181 /
  //ws:8182 + fallbacks), responses correlated by uid; certificate:null =
  //untrusted mode (QZ shows its Allow prompt). printerId "qz:" / "qz:Printer Name".
  W.qz = { socket: null, ready: null, pending: new Map(), uidSeq: 0, names: [] };
  W.qzEndpoints = function() {
    var o = globalThis.__nitroQzEndpoint;
    if (o) return [o];
    return ['wss://localhost:8181', 'ws://localhost:8182',
            'wss://localhost:8282', 'ws://localhost:8283'];
  };
  W.qzSend = function(msg, timeoutMs, tolerateTimeout) {
    return new Promise(function(resolve, reject) {
      var uid = 'nitro-' + (++W.qz.uidSeq);
      msg.uid = uid;
      msg.timestamp = Date.now();
      var timer = setTimeout(function() {
        W.qz.pending.delete(uid);
        if (tolerateTimeout) resolve(null);
        else reject(new Error('QZ call timed out: ' + (msg.call || 'handshake')));
      }, timeoutMs || 5000);
      W.qz.pending.set(uid, function(reply) {
        clearTimeout(timer);
        W.qz.pending.delete(uid);
        if (reply && reply.error) reject(new Error(String(reply.error)));
        else resolve(reply ? reply.result : null);
      });
      W.qz.socket.send(JSON.stringify(msg));
    });
  };
  W.qzReset = function() {
    try { if (W.qz.socket) W.qz.socket.close(); } catch (e) {}
    W.qz.socket = null;
    W.qz.ready = null;
    W.qz.pending.clear();
  };
  W.qzConnect = function(timeoutMs) {
    if (W.qz.ready) return W.qz.ready;
    W.qz.ready = new Promise(function(resolve, reject) {
      var endpoints = W.qzEndpoints();
      var attempt = function(i) {
        if (i >= endpoints.length) {
          W.qz.ready = null;
          reject(new Error('QZ Tray agent not reachable'));
          return;
        }
        var ws;
        try { ws = new WebSocket(endpoints[i]); } catch (e) { attempt(i + 1); return; }
        var settled = false;
        var connTimer = setTimeout(function() {
          if (settled) return;
          settled = true;
          try { ws.close(); } catch (e) {}
          attempt(i + 1);
        }, timeoutMs || 1500);
        ws.onerror = function() {
          if (settled) return;
          settled = true;
          clearTimeout(connTimer);
          attempt(i + 1);
        };
        ws.onopen = async function() {
          if (settled) return;
          settled = true;
          clearTimeout(connTimer);
          W.qz.socket = ws;
          ws.onmessage = function(ev) {
            var m;
            try { m = JSON.parse(ev.data); } catch (e) { return; }
            if (m && m.uid && W.qz.pending.has(m.uid)) W.qz.pending.get(m.uid)(m);
            else W.qzStream(m);
          };
          ws.onclose = function() { W.qzReset(); };
          try {
            await W.qzSend({ call: 'getVersion', params: {} }, 3000);
            // Untrusted mode: QZ gates calls behind its own Allow prompt.
            await W.qzSend({ certificate: null }, 1500, /*tolerateTimeout=*/true);
            resolve(ws);
          } catch (e) {
            W.qzReset();
            reject(e);
          }
        };
      };
      attempt(0);
    });
    return W.qz.ready;
  };
  // QZ status strings → our status cache + onPrinterStatusChanged.
  W.qzStream = function(m) {
    if (!m || m.type !== 'PRINTER') return;
    var ev = m.event;
    if (typeof ev === 'string') { try { ev = JSON.parse(ev); } catch (e) { ev = {}; } }
    ev = ev || {};
    var name = ev.printerName || m.key;
    if (!name) return;
    var status = String(ev.statusText || ev.status || "").toUpperCase();
    var id = 'qz:' + name;
    var online = status.indexOf('OFFLINE') < 0 && status.indexOf('ERROR') < 0 &&
                 status.indexOf('NOT_AVAILABLE') < 0;
    var reasons = "";
    if (status.indexOf('PAPER_JAM') >= 0 || status.indexOf('JAM') >= 0) reasons = 'media-jam';
    else if (status.indexOf('PAPER_OUT') >= 0 || status.indexOf('OUT_OF_PAPER') >= 0) reasons = 'media-empty';
    else if (status.indexOf('TONER_LOW') >= 0) reasons = 'toner-low';
    else if (status.indexOf('NO_TONER') >= 0 || status.indexOf('TONER_EMPTY') >= 0) reasons = 'toner-empty';
    else if (status.indexOf('DOOR_OPEN') >= 0 || status.indexOf('COVER') >= 0) reasons = 'cover-open';
    W.cache.status[id] = { online: online, ready: online && status.indexOf('PRINTING') < 0,
                           state: status.toLowerCase() || 'idle', reasons: reasons,
                           msg: 'QZ Tray: ' + (status || 'ONLINE') };
    wasmExports.nitro_printing_web_status_changed(
        W.cstr([id, online ? '1' : '0',
                status.indexOf('PRINTING') >= 0 ? '1' : '0',
                status.toLowerCase() || 'idle', reasons].join('\x1F')));
  };
  W.qzB64 = function(bytes) {
    var s = "";
    for (var i = 0; i < bytes.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(s);
  };
  W.qzErrCode = function(e) {
    var m = (e && e.message ? e.message : String(e));
    if (m.indexOf('not reachable') >= 0) {
      return 'QZ_UNAVAILABLE|QZ Tray agent not reachable — install and start QZ Tray (https://qz.io), or point WebPrintAgent.endpoint at your agent';
    }
    if (m.toLowerCase().indexOf('block') >= 0 || m.toLowerCase().indexOf('denied') >= 0) {
      return 'QZ_BLOCKED|QZ Tray blocked the request — allow this site in the QZ Tray prompt';
    }
    return 'QZ_PRINT_FAILED|QZ Tray: ' + m;
  };
  //QZ resolves print once the OS spooler accepted the job → PrintOutcome.printed.
  W.qzPrint = async function(port, bytes, printerId, copies, asPdf) {
    try {
      await W.qzConnect(1800);
      var name = printerId.slice(3);
      if (!name) name = await W.qzSend({ call: 'printers.getDefault', params: {} }, 5000);
      if (!name) { W.rawDone(port, 0, 'QZ_PRINT_FAILED|QZ Tray reports no default printer'); return; }
      var entry = asPdf
          ? { type: 'pixel', format: 'pdf', flavor: 'base64', data: W.qzB64(bytes) }
          : { type: 'raw', format: 'command', flavor: 'base64', data: W.qzB64(bytes) };
      await W.qzSend({
        call: 'print',
        params: { printer: { name: name }, options: { copies: copies > 1 ? copies : 1 }, data: [entry] },
      }, 30000);
      W.rawDone(port, 1, '');
    } catch (e) {
      W.rawDone(port, 0, W.qzErrCode(e));
    }
  };
  // Agent discovery: enumerate + start the OS status stream.
  W.qzDiscover = async function() {
    try {
      await W.qzConnect(1500);
      var names = await W.qzSend({ call: 'printers.find', params: {} }, 5000);
      if (!Array.isArray(names)) names = names ? [names] : [];
      W.qz.names = names;
      for (var n of names) {
        var id = 'qz:' + n;
        if (W.cache.printers.indexOf(id) < 0) W.cache.printers.push(id);
        W.cache.caps[id] = { color: true, duplex: false, maxCopies: 999, dpi: 300,
                             a4: true, a5: false, letter: true, legal: false,
                             draft: true, normal: true, high: true, trays: "" };
        if (!W.cache.status[id]) {
          W.cache.status[id] = { online: true, ready: true, state: 'idle', reasons: "",
                                 msg: 'QZ Tray agent printer' };
        }
        wasmExports.nitro_printing_web_discovered(
            W.cstr([id, n, 'localhost', '0', 'qz-tray', id, '1'].join('\x1F')));
      }
      try {
        await W.qzSend({ call: 'printers.startListening',
                         params: { printerNames: names, jobData: false } }, 5000, true);
      } catch (e2) {}
      return names.length > 0;
    } catch (e) { return false; }
  };

  // ── Web Printing API (Isolated Web Apps) ───────────────────────────────
  W.wp = function() { return self.printing || navigator.printing || null; };
  W.wpJobRow = function(rec) {
    return [rec.id, rec.printerId, rec.title, rec.state, rec.progress,
            rec.createdMs, rec.completedMs, rec.error, rec.pages].join('\x1F');
  };
  W.jobsTable = function() {
    return W.cache.jobs.map(W.wpJobRow).join('\x1E');
  };
  // Job failure → "[REASON_CODE] human text" (parsed by the Dart catalog).
  W.jobFailure = function(state, reasons) {
    var code = state === 3 ? 'JOB_CANCELLED' : 'JOB_ABORTED';
    if (reasons.indexOf('media-jam') >= 0) code = 'MEDIA_JAM';
    else if (reasons.indexOf('media-empty') >= 0 || reasons.indexOf('media-needed') >= 0) code = 'MEDIA_EMPTY';
    else if (reasons.indexOf('toner-empty') >= 0 || reasons.indexOf('marker-supply-empty') >= 0) code = 'TONER_EMPTY';
    else if (reasons.indexOf('toner-low') >= 0 || reasons.indexOf('marker-supply-low') >= 0) code = 'TONER_LOW';
    else if (reasons.indexOf('cover-open') >= 0 || reasons.indexOf('door-open') >= 0) code = 'COVER_OPEN';
    else if (reasons.indexOf('offline') >= 0 || reasons.indexOf('shutdown') >= 0 ||
             reasons.indexOf('stopped') >= 0) code = 'PRINTER_OFFLINE';
    return '[' + code + '] ' + (reasons || (state === 3 ? 'cancelled' : 'aborted'));
  };
  // IPP job state → PrintState enum (idle/printing/completed/cancelled/failed).
  W.wpMapState = function(s) {
    if (s === 'processing') return 1;
    if (s === 'completed') return 2;
    if (s === 'canceled') return 3;
    if (s === 'aborted') return 4;
    return 0; // preliminary / pending
  };

  // Refreshes the printers + capabilities + status caches (WebUSB granted
  // devices merged with Web Printing system printers), then reports the
  // printers table.
  W.refreshPrinters = async function(port) {
    var rows = [];
    var cache = W.cache;
    cache.printers = [];
    try {
      var thermalCaps = { color: false, duplex: false, maxCopies: 999, dpi: 203,
                          a4: false, a5: false, letter: false, legal: false,
                          draft: false, normal: true, high: false, trays: "" };
      var addLocal = function(id, name, kind) {
        rows.push([id, name, kind, '0', '1'].join('\x1F'));
        cache.printers.push(id);
        cache.caps[id] = thermalCaps;
        cache.status[id] = { online: true, ready: true, state: 'idle', reasons: "",
                             msg: kind + ' device granted' };
      };
      if (navigator.usb) {
        var devices = await navigator.usb.getDevices();
        for (var d of devices) addLocal(W.usbId(d), d.productName || W.usbId(d), 'usb');
      }
      if (navigator.serial) {
        var ports = await navigator.serial.getPorts();
        if (ports.length) addLocal('serial:', 'Serial printer', 'serial');
      }
      if (navigator.bluetooth && navigator.bluetooth.getDevices) {
        try {
          var bles = await navigator.bluetooth.getDevices();
          for (var b of bles) addLocal('ble:' + (b.name || b.id), b.name || 'BLE printer', 'ble');
        } catch (e) {}
      }
      //QZ printers: only auto-probed when an endpoint is configured or the agent
      //is already connected (no unsolicited localhost / LNA prompts).
      if (!W.qz.socket && globalThis.__nitroQzEndpoint) await W.qzDiscover();
      if (!W.agent.socket && globalThis.__nitroAgentEndpoint) await W.agentDiscover();
      if (W.agent.socket) {
        for (var ap of W.agent.printers) {
          var aid = 'agent:' + ap.id;
          rows.push([aid, ap.name || ap.id, 'nitro-agent', ap.isDefault ? '1' : '0',
                     ap.isAvailable !== false ? '1' : '0'].join(''));
          if (cache.printers.indexOf(aid) < 0) cache.printers.push(aid);
        }
      }
      if (W.qz.socket) {
        for (var qn of W.qz.names) {
          var qid = 'qz:' + qn;
          rows.push([qid, qn, 'qz-tray', '0',
                     (W.cache.status[qid] && W.cache.status[qid].online === false) ? '0' : '1'].join(''));
          if (cache.printers.indexOf(qid) < 0) cache.printers.push(qid);
        }
      }
      var wp = W.wp();
      if (wp) {
        var printers = await wp.getPrinters();
        for (var p of printers) {
          var attrs = null;
          try { attrs = await p.fetchAttributes(); }
          catch (e) { try { attrs = await p.cachedAttributes(); } catch (e2) { attrs = {}; } }
          var name = (attrs && attrs['printer-name']) || p.name || 'printer';
          var id = String(name);
          var state = (attrs && attrs['printer-state']) || 'idle';
          var available = state !== 'stopped';
          rows.push([id, name, 'system', '0', available ? '1' : '0'].join('\x1F'));
          cache.printers.push(id);
          var colorModes = (attrs && attrs['print-color-mode-supported']) || [];
          var sides = (attrs && attrs['sides-supported']) || [];
          var quality = (attrs && attrs['print-quality-supported']) || [];
          var media = ((attrs && attrs['media-supported']) || []).join(',');
          var copiesMax = (attrs && attrs['copies-supported'] && attrs['copies-supported'].to) || 1;
          var res = (attrs && attrs['printer-resolution-supported']) || [];
          var maxDpi = 0;
          for (var r of res) { maxDpi = Math.max(maxDpi, r.crossFeedDirectionResolution || 0); }
          cache.caps[id] = {
            color: colorModes.indexOf('color') >= 0,
            duplex: sides.some(function(s) { return s.indexOf('two-sided') === 0; }),
            maxCopies: copiesMax,
            dpi: maxDpi || 300,
            a4: media.indexOf('iso_a4') >= 0, a5: media.indexOf('iso_a5') >= 0,
            letter: media.indexOf('na_letter') >= 0, legal: media.indexOf('na_legal') >= 0,
            draft: quality.indexOf('draft') >= 0, normal: quality.indexOf('normal') >= 0 || quality.length === 0,
            high: quality.indexOf('high') >= 0,
            trays: ((attrs && attrs['media-source-supported']) || []).join(','),
          };
          cache.status[id] = {
            online: available, ready: state === 'idle',
            state: String(state),
            reasons: ((attrs && attrs['printer-state-reasons']) || []).join(','),
            msg: (attrs && attrs['printer-state-message']) || "",
          };
          cache['wpPrinter:' + id] = p;
        }
        W.startStatusPoll(); // live onPrinterStatusChanged while WP exists
      }
      wasmExports.nitro_printing_web_printers_done(port, W.cstr(rows.join('\x1E')));
    } catch (e) {
      wasmExports.nitro_printing_web_printers_done(port, W.cstr(rows.join('\x1E')));
    }
  };

  // attrs row: copies, sides, colorMode, quality, orientation, mediaSizeName,
  // rangeFrom, rangeTo, collate, mediaType — IPP template attributes for
  // submitPrintJob. Members a printer doesn't support are ignored.
  W.wpAttrs = function(attrsStr) {
    var a = (attrsStr || "").split('\x1F');
    var t = { copies: Math.max(1, +a[0] || 1) };
    if (a[1]) t.sides = a[1];
    if (a[2]) t.printColorMode = a[2];
    if (a[3]) t.printQuality = a[3];
    if (a[4]) t.orientationRequested = a[4];
    if (a[5] || a[9]) {
      t.mediaCol = {};
      if (a[5]) t.mediaCol.mediaSizeName = a[5];
      if (a[9]) t.mediaCol.mediaType = a[9];
    }
    if (+a[6] > 0) t.pageRanges = [{ from: +a[6], to: +a[7] > 0 ? +a[7] : 65535 }];
    if (a[8]) t.multipleDocumentHandling = a[8];
    if (+a[10] > 1) t.numberUp = +a[10];
    if (a[11] === '1') t.printScaling = 'fit';
    return t;
  };
  // Submits a real Web Printing PDF job; fallback is handled C++-side.
  W.wpSubmit = async function(port, printerId, title, bytes, attrsStr) {
    try {
      var p = W.cache['wpPrinter:' + printerId];
      if (!p) { W.rawDone(port, 0, 'WP_UNKNOWN_PRINTER|Unknown system printer "' + printerId + '" — call getAllPrinters() first'); return; }
      var attrs = W.wpAttrs(attrsStr);
      var caps = W.cache.caps[printerId];
      if (attrs.printQuality === 'high' && caps && caps.dpi > 0) {
        attrs.printerResolution = { crossFeedDirectionResolution: caps.dpi,
                                    feedDirectionResolution: caps.dpi,
                                    units: 'dots-per-inch' };
      }
      var job = await p.submitPrintJob(title || 'nitro_printing job',
                                       new Blob([bytes], { type: 'application/pdf' }), attrs);
      var rec = { id: makeId(), printerId: printerId, title: title || "", state: 0,
                  progress: 0, createdMs: Date.now(), completedMs: 0, error: "", pages: 0 };
      function makeId() { return 'wp-job-' + Date.now() + '-' + Math.floor(Math.random() * 1e6); }
      rec.id = makeId();
      rec.cancel = function() { try { job.cancel(); return true; } catch (e) { return false; } };
      job.onjobstatechange = function() {
        try {
          var a = job.attributes();
          rec.state = W.wpMapState(a['job-state']);
          rec.pages = a['job-pages-completed'] || 0;
          var total = a['job-pages'] || 0;
          rec.progress = total > 0 ? Math.round(rec.pages * 100 / total) : (rec.state === 2 ? 100 : 0);
          if (rec.state >= 2) rec.completedMs = Date.now();
          if (rec.state >= 3) { // cancelled / failed — attach the printer's reason
            var st = W.cache.status[printerId] || {};
            rec.error = W.jobFailure(rec.state, st.reasons || "");
          }
          wasmExports.nitro_printing_web_job_changed(W.cstr(W.wpJobRow(rec)));
        } catch (e) {}
      };
      W.cache.jobs.push(rec);
      W.rawDone(port, 1, rec.id); // msg carries the job id on success
    } catch (e) {
      W.rawDone(port, 0, 'WP_SUBMIT_FAILED|Web Printing: ' + (e && e.message ? e.message : e));
    }
  };

  //── Discovery ──────────────────────────────────────────────────────────
  //Needs a user gesture. WebUSB picker → Web Serial picker fallback; mDNS
  //runs alongside in IWAs. Finds emit onPrinterDiscovered.
  W.discover = async function(port) {
    var mdns = W.mdnsDiscover(); // gesture-free; resolves with "found any"
    var qzFound = W.qzDiscover(); // localhost agent probes (gesture-free)
    var agentFound = W.agentDiscover();
    var granted = false;
    if (navigator.usb) {
      try {
        var device = await navigator.usb.requestDevice({ filters: [
          { classCode: 7 },
          { vendorId: 0x04b8 }, // Epson
          { vendorId: 0x0519 }, // Star
          { vendorId: 0x0a5f }, // Zebra
          { vendorId: 0x1504 }, // Bixolon
          { vendorId: 0x1d90 }, // Citizen
        ] });
        if (device) {
          var id = W.usbId(device);
          wasmExports.nitro_printing_web_discovered(
              W.cstr([id, device.productName || id, "", '0', 'usb', id, '1'].join('\x1F')));
          granted = true;
        }
      } catch (e) {} // no gesture / picker dismissed — try the next picker
    }
    if (!granted && navigator.serial) {
      try {
        var sp = await navigator.serial.requestPort();
        if (sp) {
          wasmExports.nitro_printing_web_discovered(
              W.cstr(['serial:', 'Serial printer', "", '0', 'serial', 'serial:', '1'].join('\x1F')));
          granted = true;
        }
      } catch (e) {}
    }
    if (!granted && navigator.bluetooth && navigator.bluetooth.requestDevice) {
      try {
        var bd = await navigator.bluetooth.requestDevice({
          filters: W.bleServices.map(function(s) { return { services: [s] }; }),
          optionalServices: W.bleServices,
        });
        if (bd) {
          var bid = 'ble:' + (bd.name || bd.id);
          wasmExports.nitro_printing_web_discovered(
              W.cstr([bid, bd.name || 'BLE printer', "", '0', 'ble', bid, '1'].join('\x1F')));
          granted = true;
        }
      } catch (e) {}
    }
    W.boolDone(port,
        granted || (await mdns) || (await qzFound) || (await agentFound) ? 1 : 0);
  };

  // ── Connection probe ───────────────────────────────────────────────────
  W.testConnection = async function(port, printerId, timeoutMs) {
    try {
      if (printerId.indexOf('usb:') === 0 || printerId === "") {
        var d = await W.usbFind(printerId);
        if (!d) { W.boolDone(port, 0); return; }
        await d.open(); await d.close();
        W.boolDone(port, 1);
        return;
      }
      if (printerId.indexOf('serial:') === 0) {
        var ports2 = navigator.serial ? await navigator.serial.getPorts() : [];
        W.boolDone(port, ports2.length ? 1 : 0);
        return;
      }
      if (printerId.indexOf('agent:') === 0) {
        try {
          await W.agentStatus(printerId);
          W.boolDone(port, 1);
        } catch (e4) { W.boolDone(port, 0); }
        return;
      }
      if (printerId.indexOf('qz:') === 0) {
        try {
          await W.qzConnect(1800);
          var qname = printerId.slice(3);
          if (!qname) { W.boolDone(port, 1); return; }
          var found = await W.qzSend({ call: 'printers.find', params: {} }, 5000);
          W.boolDone(port, Array.isArray(found) && found.indexOf(qname) >= 0 ? 1 : 0);
        } catch (e3) { W.boolDone(port, 0); }
        return;
      }
      if (printerId.indexOf('ble:') === 0) {
        var bles = (navigator.bluetooth && navigator.bluetooth.getDevices)
            ? await navigator.bluetooth.getDevices() : [];
        W.boolDone(port, bles.length ? 1 : 0);
        return;
      }
      if (printerId.indexOf('ws://') === 0 || printerId.indexOf('wss://') === 0) {
        var ws = new WebSocket(printerId);
        var fired = false;
        var finish = function(ok) {
          if (fired) return; fired = true;
          try { ws.close(); } catch (e) {}
          W.boolDone(port, ok);
        };
        setTimeout(function() { finish(0); }, timeoutMs);
        ws.onopen = function() { finish(1); };
        ws.onerror = function() { finish(0); };
        return;
      }
      if (W.cache['wpPrinter:' + printerId]) { W.boolDone(port, 1); return; }
      if (typeof TCPSocket !== 'undefined') {
        var hp = W.parseHostPort(printerId);
        var s = new TCPSocket(hp.host, hp.port);
        setTimeout(function() { try { s.close(); } catch (e) {} }, timeoutMs);
        await s.opened;
        try { s.close(); } catch (e) {}
        W.boolDone(port, 1);
        return;
      }
      W.boolDone(port, 0);
    } catch (e) { W.boolDone(port, 0); }
  };
  W.parseHostPort = function(id) {
    var s = id;
    if (s.indexOf('socket://') === 0) s = s.slice(9);
    if (s.indexOf('ipp://') === 0) s = s.slice(6);
    var colon = s.lastIndexOf(':');
    if (colon > 0 && s.indexOf(']') < colon) {
      return { host: s.slice(0, colon), port: parseInt(s.slice(colon + 1), 10) || 9100 };
    }
    return { host: s, port: 9100 };
  };

  // ── Image → JPEG re-encode (canvas) for PDF embedding ──────────────────
  // Reports back through nitro_printing_web_image_jpeg(port, ptr, len, w, h);
  // ptr 0 signals a decode failure.
  W.imageToJpeg = async function(port, bytes) {
    var fired = false;
    var fail = function() {
      if (fired) return;
      fired = true;
      wasmExports.nitro_printing_web_image_jpeg(port, 0, 0, 0, 0);
    };
    // Watchdog: a stalled decode/encode must still complete the Dart future.
    setTimeout(fail, 10000);
    try {
      var bitmap = await createImageBitmap(new Blob([bytes]));
      var canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
      var ctx = canvas.getContext('2d');
      ctx.fillStyle = '#fff'; // JPEG has no alpha — composite on white
      ctx.fillRect(0, 0, bitmap.width, bitmap.height);
      ctx.drawImage(bitmap, 0, 0);
      var blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.92 });
      var jpeg = new Uint8Array(await blob.arrayBuffer());
      if (fired) return; // watchdog already reported
      fired = true;
      var p = wasmExports.malloc(jpeg.length);
      HEAPU8.set(jpeg, p);
      wasmExports.nitro_printing_web_image_jpeg(port, p, jpeg.length, bitmap.width, bitmap.height);
    } catch (e) { fail(); }
  };

  // ── printFile: fetch an http(s)/data/blob URL and print by sniffed type ─
  W.fetchPrint = async function(port, url) {
    try {
      var resp = await fetch(url);
      if (!resp.ok) { W.boolDone(port, 0); return; }
      var bytes = new Uint8Array(await resp.arrayBuffer());
      var ct = (resp.headers.get('content-type') || "").toLowerCase();
      var o = W.parseOpts("");
      var isPdf = ct.indexOf('pdf') >= 0 ||
          (bytes.length > 4 && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46);
      var isImage = ct.indexOf('image/') === 0 ||
          (bytes.length > 3 && ((bytes[0] === 0x89 && bytes[1] === 0x50) || (bytes[0] === 0xFF && bytes[1] === 0xD8)));
      if (isPdf) {
        var purl = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
        W.printBlobUrl(port, 3, purl, 0); // kind 3 → completes as a bool
      } else if (isImage) {
        var iurl = URL.createObjectURL(new Blob([bytes], { type: ct.indexOf('image/') === 0 ? ct : 'image/png' }));
        W.printHtml(port, 3, W.imgHtml(iurl, o));
        setTimeout(function() { URL.revokeObjectURL(iurl); }, 15000);
      } else {
        W.printHtml(port, 3, W.textPagesHtml(new TextDecoder().decode(bytes), o));
      }
    } catch (e) { W.boolDone(port, 0); }
  };

  // ── Download (printToFile) ─────────────────────────────────────────────
  W.download = function(bytes, mime, name) {
    var url = URL.createObjectURL(new Blob([bytes], { type: mime }));
    var a = document.createElement('a');
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
  };
});

// ── EM_JS entry points (thin wrappers over the helpers above) ────────────────

EM_JS(void, js_print_text, (int64_t port, int kind, const char* text, const char* opts), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  W.printHtml(port, kind, W.textPagesHtml(UTF8ToString(text), W.parseOpts(UTF8ToString(opts))));
});

EM_JS(void, js_print_html, (int64_t port, int kind, const char* html, const char* opts), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  W.printHtml(port, kind, W.htmlDocHtml(UTF8ToString(html), W.parseOpts(UTF8ToString(opts))));
});

EM_JS(void, js_print_blob, (int64_t port, int kind, const uint8_t* data, int len, const char* mime, int asImage, const char* opts), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  var bytes = HEAPU8.slice(data, data + len); // copy — blob outlives wasm heap views
  var url = URL.createObjectURL(new Blob([bytes], { type: UTF8ToString(mime) }));
  if (asImage) {
    W.printHtml(port, kind, W.imgHtml(url, W.parseOpts(UTF8ToString(opts))));
    setTimeout(function() { URL.revokeObjectURL(url); }, 15000);
  } else {
    W.printBlobUrl(port, kind, url, 0); // PDF — prints as-is (opts n/a)
  }
});

EM_JS(void, js_raw_print, (int64_t port, const uint8_t* data, int len, const char* printerId, int copies, int timeoutMs), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  W.routeRaw(port, HEAPU8.slice(data, data + len), UTF8ToString(printerId), copies, timeoutMs);
});

EM_JS(void, js_image_escpos, (int64_t port, const uint8_t* data, int len, const char* printerId, int copies, int timeoutMs, int widthDots), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  W.imageEscPos(port, HEAPU8.slice(data, data + len), UTF8ToString(printerId), copies, timeoutMs, widthDots);
});

EM_JS(void, js_html_to_jpegs, (int64_t port, const char* html, double pageWpt, double pageHpt, const char* opts), {
  js_ensure_helpers();
  globalThis.__nitroWeb.htmlToJpegs(port, UTF8ToString(html), pageWpt, pageHpt, UTF8ToString(opts));
});

EM_JS(void, js_text_preview_jpegs, (int64_t port, const char* text, const char* opts, double pageWpt, double pageHpt), {
  js_ensure_helpers();
  globalThis.__nitroWeb.textPreviewJpegs(port, UTF8ToString(text), UTF8ToString(opts), pageWpt, pageHpt);
});

EM_JS(void, js_resume_job, (int64_t port, const char* jobId), {
  js_ensure_helpers();
  globalThis.__nitroWeb.resumeJob(port, UTF8ToString(jobId));
});

EM_JS(void, js_agent_print, (int64_t port, const char* kind, const uint8_t* data, int len, const char* printerId, int copies), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  W.agentPrint(port, UTF8ToString(kind), HEAPU8.slice(data, data + len), UTF8ToString(printerId), copies);
});

EM_JS(void, js_qz_pdf, (int64_t port, const uint8_t* data, int len, const char* printerId, int copies), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  W.qzPrint(port, HEAPU8.slice(data, data + len), UTF8ToString(printerId), copies, true);
});

EM_JS(void, js_raw_cancel, (int64_t port), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  if (W.rawAbort) { W.rawAbort(); W.rawAbort = null; W.boolDone(port, 1); }
  else W.boolDone(port, 0);
});

EM_JS(void, js_refresh_printers, (int64_t port), {
  js_ensure_helpers();
  globalThis.__nitroWeb.refreshPrinters(port);
});

EM_JS(void, js_discover, (int64_t port), {
  js_ensure_helpers();
  globalThis.__nitroWeb.discover(port);
});

EM_JS(void, js_test_connection, (int64_t port, const char* printerId, int timeoutMs), {
  js_ensure_helpers();
  globalThis.__nitroWeb.testConnection(port, UTF8ToString(printerId), timeoutMs);
});

EM_JS(void, js_wp_submit, (int64_t port, const char* printerId, const char* title, const uint8_t* data, int len, const char* attrs), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  W.wpSubmit(port, UTF8ToString(printerId), UTF8ToString(title), HEAPU8.slice(data, data + len), UTF8ToString(attrs));
});

// 1 when printerId names a Web Printing system printer from the cache.
EM_JS(int, js_wp_has_printer, (const char* printerId), {
  js_ensure_helpers();
  return globalThis.__nitroWeb.cache['wpPrinter:' + UTF8ToString(printerId)] ? 1 : 0;
});

EM_JS(void, js_download, (const uint8_t* data, int len, const char* mime, const char* name), {
  js_ensure_helpers();
  globalThis.__nitroWeb.download(HEAPU8.slice(data, data + len), UTF8ToString(mime), UTF8ToString(name));
});

EM_JS(void, js_image_to_jpeg, (int64_t port, const uint8_t* data, int len), {
  js_ensure_helpers();
  globalThis.__nitroWeb.imageToJpeg(port, HEAPU8.slice(data, data + len));
});

EM_JS(void, js_fetch_print, (int64_t port, const char* url), {
  js_ensure_helpers();
  globalThis.__nitroWeb.fetchPrint(port, UTF8ToString(url));
});

// ── Synchronous cache reads (serve the sync @NitroResult lookups) ────────────

EM_JS(int, js_sync_printer_count, (), {
  js_ensure_helpers();
  return globalThis.__nitroWeb.cache.printers.length;
});

// Returns a malloc'd printers-table row for index, or 0 when out of range.
EM_JS(char*, js_sync_printer_at, (int index), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  var id = W.cache.printers[index];
  if (id == null) return 0;
  var st = W.cache.status[id] || {};
  return W.cstr([id, id, id.indexOf('usb:') === 0 ? 'usb' : 'system', '0',
                 st.online === false ? '0' : '1'].join('\x1F'));
});

// Returns a malloc'd caps row for printerId, or 0 when unknown:
// color,duplex,maxCopies,dpi,a4,a5,letter,legal,draft,normal,high,trays
EM_JS(char*, js_sync_caps, (const char* printerId), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  var c = W.cache.caps[UTF8ToString(printerId)];
  if (!c) return 0;
  var b = function(v) { return v ? '1' : '0'; };
  return W.cstr([b(c.color), b(c.duplex), String(c.maxCopies), String(c.dpi),
                 b(c.a4), b(c.a5), b(c.letter), b(c.legal),
                 b(c.draft), b(c.normal), b(c.high), c.trays].join('\x1F'));
});

// Returns a malloc'd status row for printerId, or 0 when unknown:
// online,ready,state,reasons,msg
EM_JS(char*, js_sync_status, (const char* printerId), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  var s = W.cache.status[UTF8ToString(printerId)];
  if (!s) return 0;
  var b = function(v) { return v ? '1' : '0'; };
  return W.cstr([b(s.online), b(s.ready), s.state || "", s.reasons || "", s.msg || ""].join('\x1F'));
});

// Returns the malloc'd jobs table (may be empty).
EM_JS(char*, js_sync_jobs, (), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  return W.cstr(W.jobsTable());
});

// Cancels the Web Printing job with this id; 1 on success.
EM_JS(int, js_wp_cancel_job, (const char* jobId), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  var id = UTF8ToString(jobId);
  for (var rec of W.cache.jobs) {
    if (rec.id === id && rec.cancel) return rec.cancel() ? 1 : 0;
  }
  return 0;
});

// Cancels every non-terminal Web Printing job; count cancelled.
EM_JS(int, js_wp_clear_jobs, (), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  var n = 0;
  for (var rec of W.cache.jobs) {
    if (rec.state < 2 && rec.cancel && rec.cancel()) n++;
  }
  return n;
});

// ── Batch (sequential dialog prints) ─────────────────────────────────────────

// kind: 0 = dialog (item.type routes the flow), 1 = pre-encoded raw bytes
// (ESC/POS via the raw transports), 2 = Web Printing PDF job.
EM_JS(void, js_batch_add, (int kind, int type, const uint8_t* data, int len), {
  js_ensure_helpers();
  globalThis.__nitroWeb.batch.push({ kind: kind, type: type, bytes: HEAPU8.slice(data, data + len) });
});

EM_JS(void, js_batch_run, (int64_t port, int stopOnError, const char* opts, const char* printerId, const char* wpAttrs, int timeoutMs), {
  js_ensure_helpers();
  var W = globalThis.__nitroWeb;
  var items = W.batch;
  W.batch = [];
  var o = W.parseOpts(UTF8ToString(opts));
  var id = UTF8ToString(printerId);
  var attrs = UTF8ToString(wpAttrs);
  var mask = 0n;
  var dialogMask = 0n;
  var ran = 0;
  var runOne = function(i) {
    if (i >= items.length) {
      wasmExports.nitro_printing_web_batch_done(port, mask, dialogMask, ran);
      return;
    }
    var item = items[i];
    if (item.kind === 0) dialogMask |= (1n << BigInt(i));
    var localPort = -1n - BigInt(i); // sentinel — routed to W.batchDone
    W.batchDone = function(ok) {
      ran++;
      if (ok) mask |= (1n << BigInt(i));
      if (!ok && stopOnError) {
        wasmExports.nitro_printing_web_batch_done(port, mask, dialogMask, ran);
      } else {
        runOne(i + 1);
      }
    };
    if (item.kind === 1) {        // raw transport (sentinel flows via rawDone)
      W.routeRaw(localPort, item.bytes, id, 1, timeoutMs);
      return;
    }
    if (item.kind === 2) {        // Web Printing PDF job
      W.wpSubmit(localPort, id, "", item.bytes, attrs);
      return;
    }
    var td = new TextDecoder();
    if (item.type === 0) {        // plainText
      W.printHtml(localPort, 2, W.textPagesHtml(td.decode(item.bytes), o));
    } else if (item.type === 1) { // html
      W.printHtml(localPort, 2, W.htmlDocHtml(td.decode(item.bytes), o));
    } else if (item.type === 3) { // image
      var iurl = URL.createObjectURL(new Blob([item.bytes], { type: 'image/png' }));
      W.printHtml(localPort, 2, W.imgHtml(iurl, o));
      setTimeout(function() { URL.revokeObjectURL(iurl); }, 15000);
    } else {                       // pdf — prints as-is (opts n/a)
      var url = URL.createObjectURL(new Blob([item.bytes], { type: 'application/pdf' }));
      W.printBlobUrl(localPort, 2, url, 0);
    }
  };
  runOne(0);
});

// ── Wasm-exported completion callbacks (invoked from the JS flows) ───────────

namespace { void emitDiscovered(const std::vector<std::string>& f); }
namespace { void emitJobChanged(const std::vector<std::string>& f); }
namespace { void emitStatusChanged(const std::vector<std::string>& f); }

extern "C" {

EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_done(int64_t port, int kind, int ok, char* jobId, int dialogMs) {
    std::string id = jobId ? jobId : "";
    ::free(jobId);
    if (kind == kDoneBatchItem) {
        EM_ASM({
          var W = globalThis.__nitroWeb;
          if (W && W.batchDone) W.batchDone($0);
        }, ok);
        return;
    }
    if (kind == kDoneBool) { // printFile: dialog outcome as a bool
        postBool(port, ok != 0);
        return;
    }
    if (kind == kDoneDialog) {
        PrintDialogResult result{};
        auto it = g_pendingDialogs.find(port);
        result.confirmedSettings = (it != g_pendingDialogs.end()) ? it->second : defaultSettings();
        if (it != g_pendingDialogs.end()) g_pendingDialogs.erase(it);
        //Dialog shown and closed; Print-vs-Cancel is unknowable.
        result.confirmed = ok != 0;
        result.errorMessage = ok ? "" : "Browser print dialog failed to open";
        NitroRecordWriter w;
        result.encodeInto(w);
        postRecord(port, w);
        return;
    }
    if (ok) {
        //Dialog shown and closed (Print-vs-Cancel unknowable): informational code +
        //measured dialog-open time in errorMessage (PrintResult.dialogDurationMs).
        postPrintResult(port, PrintResult{true, id.empty() ? makeJobId() : id,
                                          "dialogMs=" + std::to_string(dialogMs),
                                          "DIALOG_OUTCOME_UNKNOWN"});
    } else {
        postPrintResult(port, failedResult("Browser print failed or timed out", "DIALOG_FAILED"));
    }
}

/// Raw-transport / Web Printing submit completion. On success `msg` carries
/// the tracked job id; on failure it is "CODE|human message".
EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_raw_done(int64_t port, int ok, char* msg) {
    std::string m = msg ? msg : "";
    ::free(msg);
    if (ok) {
        postPrintResult(port, PrintResult{true, m.empty() ? makeJobId() : m, "", ""});
        return;
    }
    std::string code = "WEB_PRINT_FAILED";
    std::string human = m;
    size_t bar = m.find('|');
    if (bar != std::string::npos) {
        code = m.substr(0, bar);
        human = m.substr(bar + 1);
    }
    postPrintResult(port, failedResult(human, code.c_str()));
}

EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_bool_done(int64_t port, int v) {
    postBool(port, v != 0);
}

EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_batch_done(int64_t port, int64_t mask, int64_t dialogMask, int ran) {
    std::vector<std::vector<uint8_t>> blobs;
    blobs.reserve((size_t)ran);
    for (int i = 0; i < ran; i++) {
        bool ok = i < 64 && ((mask >> i) & 1); // i ≥ 64 would be shift UB
        bool viaDialog = i < 64 && ((dialogMask >> i) & 1);
        NitroRecordWriter w;
        PrintResult r = ok ? PrintResult{true, makeJobId(), "",
                                         viaDialog ? "DIALOG_OUTCOME_UNKNOWN" : ""}
                           : failedResult("Browser print failed or timed out", "WEB_PRINT_FAILED");
        r.encodeInto(w);
        blobs.push_back(std::move(w._buf));
    }
    postRecordList(port, blobs);
}

/// getAllPrinters completion: `table` is the printers table (malloc'd).
EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_printers_done(int64_t port, char* table) {
    auto rows = splitTable(table);
    ::free(table);
    std::vector<std::vector<uint8_t>> blobs;
    blobs.reserve(rows.size());
    for (const auto& f : rows) {
        NitroRecordWriter w;
        printerFromRow(f).encodeInto(w);
        blobs.push_back(std::move(w._buf));
    }
    postRecordList(port, blobs);
}

/// The browser finished re-encoding an image to JPEG (renderPreview /
/// printToFile). jpeg == nullptr signals a decode failure.
EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_image_jpeg(int64_t port, uint8_t* jpeg, int len, int wPx, int hPx) {
    auto it = g_pendingImagePdf.find(port);
    if (it == g_pendingImagePdf.end()) {
        ::free(jpeg);
        return;
    }
    PendingImagePdf job = std::move(it->second);
    g_pendingImagePdf.erase(it);
    std::vector<uint8_t> pdf;
    if (jpeg != nullptr && len > 0) {
        pdf = jpegToPdf(jpeg, (size_t)len, wPx, hPx, job.geom);
    }
    ::free(jpeg);
    if (job.intent == 1) { // download
        if (pdf.empty()) {
            postBool(port, false);
            return;
        }
        js_download(pdf.data(), (int)pdf.size(), "application/pdf", job.name.c_str());
        postBool(port, true);
        return;
    }
    // preview — empty pdf degrades to an empty preview
    auto* bytes = new std::vector<uint8_t>(std::move(pdf));
    PreviewResult* pv = (PreviewResult*)::malloc(sizeof(PreviewResult));
    if (pv == nullptr) {
        delete bytes;
        postNull(port);
        return;
    }
    static uint8_t emptyPreviewByte = 0;
    delete g_lastPreview;
    g_lastPreview = bytes;
    pv->bytes = bytes->empty() ? &emptyPreviewByte : bytes->data();
    pv->length = (int64_t)bytes->size();
    postOwnedBlob(port, (uint8_t*)pv);
}

/// HTML rasterization finished: [pack] = [u32 count]([u32 w][u32 h][u32 len])×
/// count + JPEG payloads. pack == nullptr signals failure.
EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_html_jpegs(int64_t port, uint8_t* pack, int packLen) {
    auto it = g_pendingHtmlPdf.find(port);
    if (it == g_pendingHtmlPdf.end()) {
        ::free(pack);
        return;
    }
    PendingHtmlPdf job = std::move(it->second);
    g_pendingHtmlPdf.erase(it);

    std::vector<JpegSlice> slices;
    if (pack != nullptr && packLen >= 4) {
        uint32_t count;
        memcpy(&count, pack, 4);
        size_t head = 4 + (size_t)count * 12;
        size_t off = head;
        for (uint32_t i = 0; i < count && head <= (size_t)packLen; i++) {
            uint32_t w, h, len;
            memcpy(&w, pack + 4 + i * 12, 4);
            memcpy(&h, pack + 8 + i * 12, 4);
            memcpy(&len, pack + 12 + i * 12, 4);
            if (off + len > (size_t)packLen) break;
            slices.push_back({pack + off, len, (int)w, (int)h});
            off += len;
        }
    }

    if (job.intent == 2) { // page count
        postInt64(port, (int64_t)slices.size());
        ::free(pack);
        return;
    }
    std::vector<uint8_t> pdf;
    if (!slices.empty()) pdf = jpegsToPdf(slices, job.geom, job.pad);
    ::free(pack);
    if (job.intent == 1) { // download
        if (pdf.empty()) {
            postBool(port, false);
            return;
        }
        js_download(pdf.data(), (int)pdf.size(), "application/pdf", job.name.c_str());
        postBool(port, true);
        return;
    }
    // preview — empty degrades to an empty PreviewResult
    auto* bytes = new std::vector<uint8_t>(std::move(pdf));
    PreviewResult* pv = (PreviewResult*)::malloc(sizeof(PreviewResult));
    if (pv == nullptr) {
        delete bytes;
        postNull(port);
        return;
    }
    static uint8_t emptyPreviewByte = 0;
    delete g_lastPreview;
    g_lastPreview = bytes;
    pv->bytes = bytes->empty() ? &emptyPreviewByte : bytes->data();
    pv->length = (int64_t)bytes->size();
    postOwnedBlob(port, (uint8_t*)pv);
}

/// A Web Printing printer changed state (row: id, online, printing, state,
/// reasons) — emitted on onPrinterStatusChanged.
EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_status_changed(char* row) {
    auto f = splitFields(row ? row : "");
    ::free(row);
    emitStatusChanged(f);
}

/// A USB device was granted through the discovery picker.
EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_discovered(char* row) {
    auto f = splitFields(row ? row : "");
    ::free(row);
    emitDiscovered(f);
}

/// A Web Printing job changed state.
EMSCRIPTEN_KEEPALIVE
void nitro_printing_web_job_changed(char* row) {
    auto f = splitFields(row ? row : "");
    ::free(row);
    emitJobChanged(f);
}

} // extern "C"

namespace {

/// Takes ownership of a malloc'd C string from a js_sync_* call.
std::optional<std::string> takeString(char* p) {
    if (p == nullptr) return std::nullopt;
    std::string s(p);
    ::free(p);
    return s;
}

class HybridNitroPrintingImpl final : public HybridNitroPrinting {
public:
    // ── Synchronous quick-lookup ─────────────────────────────────────────

    //Dialog printing always works; WebUSB / Web Printing add raw and system
    //printing where available.
    bool isPrintingSupported() override { return true; }

    /// Printers known to the cache (granted USB + system printers from the
    /// last getAllPrinters() refresh).
    int64_t getPrintersCount() override { return js_sync_printer_count(); }

    std::string getPrinterDriverVersion(const std::string& printerId) override {
        (void)printerId;
        return ""; // drivers are invisible to the sandbox
    }

    // ── @NitroResult sync lookups — served from the JS-side cache ────────
    // (populated by getAllPrinters(); throwing encodes NitroErr for Dart.)

    NitroCppBuffer getPrinterAt(int64_t index) override {
        auto row = takeString(js_sync_printer_at((int)index));
        if (!row) throw std::runtime_error("Printer index out of range — call getAllPrinters() first");
        return printerFromRow(splitFields(*row)).toNativeBuffer();
    }

    NitroCppBuffer getDefaultPrinter() override {
        //No default-printer concept on the web.
        throw std::runtime_error("No default printer on the web");
    }

    NitroCppBuffer getPrinterCapabilities(const std::string& printerId) override {
        auto row = takeString(js_sync_caps(printerId.c_str()));
        if (!row) throw std::runtime_error("Unknown printer '" + printerId + "' — call getAllPrinters() first");
        auto f = splitFields(*row);
        if (f.size() < 12) throw std::runtime_error("Malformed capabilities");
        PrinterCapabilities c{};
        c.supportsColor = toBool(f[0]);
        c.supportsDuplex = toBool(f[1]);
        c.supportsCopy = toInt(f[2]) > 1;
        c.maxCopies = toInt(f[2]);
        c.maxResolutionDpi = toInt(f[3]);
        c.supportsA4 = toBool(f[4]);
        c.supportsA5 = toBool(f[5]);
        c.supportsLetter = toBool(f[6]);
        c.supportsLegal = toBool(f[7]);
        c.supportsDraftQuality = toBool(f[8]);
        c.supportsNormalQuality = toBool(f[9]);
        c.supportsHighQuality = toBool(f[10]);
        c.supportsBestQuality = false;
        c.supportsCustomPaper = false;
        c.supportsBorderless = false;
        c.inputTrays = f[11];
        return c.toNativeBuffer();
    }

    NitroCppBuffer getPrintJobAt(int64_t index) override {
        auto jobs = currentJobs();
        if (index < 0 || (size_t)index >= jobs.size()) {
            throw std::runtime_error("Job index out of range");
        }
        return jobs[(size_t)index].toNativeBuffer();
    }

    NitroCppBuffer getPrintJobStatus(const std::string& jobId) override {
        for (const auto& j : currentJobs()) {
            if (j.id == jobId) return j.toNativeBuffer();
        }
        throw std::runtime_error("Unknown job '" + jobId + "'");
    }

    NitroCppBuffer getPrinterStatusDetail(const std::string& printerId,
                                          std::optional<int64_t> timeoutSeconds) override {
        (void)timeoutSeconds;
        auto row = takeString(js_sync_status(printerId.c_str()));
        if (!row) throw std::runtime_error("Unknown printer '" + printerId + "' — call getAllPrinters() first");
        auto f = splitFields(*row);
        if (f.size() < 5) throw std::runtime_error("Malformed status");
        PrinterStatusDetail d{};
        d.printerId = printerId;
        d.isOnline = toBool(f[0]);
        d.isReady = toBool(f[1]);
        d.printerState = f[2];
        d.stateReasons = f[3];
        d.statusMessage = f[4];
        d.hasPaperJam = f[3].find("media-jam") != std::string::npos;
        d.isOutOfPaper = f[3].find("media-empty") != std::string::npos;
        d.isOutOfInk = f[3].find("toner-empty") != std::string::npos ||
                       f[3].find("marker-supply-empty") != std::string::npos;
        d.inkLevelBlack = d.inkLevelCyan = d.inkLevelMagenta = d.inkLevelYellow = -1;
        d.tonerLevel = d.paperLevel = -1;
        d.jobsInQueue = (int64_t)currentJobs().size();
        auto caps = takeString(js_sync_caps(printerId.c_str()));
        if (caps) {
            auto cf = splitFields(*caps);
            if (cf.size() >= 2) {
                d.isColorSupported = toBool(cf[0]);
                d.isDuplexSupported = toBool(cf[1]);
            }
        }
        return d.toNativeBuffer();
    }

    // ── Printer enumeration / discovery ──────────────────────────────────

    /// Granted WebUSB devices merged with Web Printing system printers
    /// (Isolated Web Apps). Also refreshes the caches serving the sync
    /// lookups above.
    void getAllPrinters(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        js_refresh_printers(dartPort);
    }

    /// Opens the WebUSB device picker (requires a user gesture — call from a
    /// button tap). True when the user granted a device; the granted printer
    /// is also emitted on onPrinterDiscovered.
    void startPrinterDiscovery(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        js_discover(dartPort);
    }

    void stopPrinterDiscovery(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postBool(dartPort, false); // the picker is modal; nothing to stop
    }

    // ── Document printing ────────────────────────────────────────────────

    /// A raw-capable printerId (usb:/ws://socket://) routes text to the
    /// thermal printer as an ESC/POS job; anything else uses the dialog.
    void printText(const std::string& text, NitroCppBuffer settings,
                   NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        auto s = decodeSettings(settings);
        if (s && s->printerId.rfind("agent:", 0) == 0) {
            //Agent: the native backend lays the text out (any OS printer).
            js_agent_print(dartPort, "text", (const uint8_t*)text.data(), (int)text.size(),
                           s->printerId.c_str(), s->copies > 1 ? (int)s->copies : 1);
            return;
        }
        if (s && isRawPrinterId(s->printerId)) {
            auto escPos = textToEscPos(text);
            rawPrintDecoded(escPos.data(), escPos.size(), s, dartPort, /*forceSingle=*/false);
            return;
        }
        js_print_text(dartPort, kDonePrint, text.c_str(), buildDialogOpts(s).c_str());
    }

    /// A raw-capable printerId rasters the image to ESC/POS (GS v 0) for
    /// thermal printers; anything else uses the dialog.
    void printImage(const uint8_t* imageData, size_t imageData_length, NitroCppBuffer settings,
                    NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        auto s = decodeSettings(settings);
        if (s && s->printerId.rfind("agent:", 0) == 0) {
            js_agent_print(dartPort, "image", imageData, (int)imageData_length,
                           s->printerId.c_str(), s->copies > 1 ? (int)s->copies : 1);
            return;
        }
        if (s && isRawPrinterId(s->printerId)) {
            // 58 mm heads are 384 dots wide, 80 mm are 576 (at 203 dpi).
            int widthDots = (s->paperSize == PAPERSIZE_CUSTOM && s->customPaperWidth > 200) ? 576 : 384;
            int copies = s->copies > 1 ? (int)s->copies : 1;
            int64_t t = s->networkTimeoutSeconds > 0 ? s->networkTimeoutSeconds : 30;
            js_image_escpos(dartPort, imageData, (int)imageData_length,
                            s->printerId.c_str(), copies, (int)(t * 1000), widthDots);
            return;
        }
        js_print_blob(dartPort, kDonePrint, imageData, (int)imageData_length,
                      sniffImageMime(imageData, imageData_length), 1,
                      buildDialogOpts(s).c_str());
    }

    ///PDF to a Web Printing system printer → real job (silent, tracked, IPP
    ///attributes); otherwise the dialog.
    void printPdf(const uint8_t* pdfData, size_t pdfData_length, NitroCppBuffer settings,
                  NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        auto s = decodeSettings(settings);
        if (s && !s->printerId.empty() && js_wp_has_printer(s->printerId.c_str())) {
            js_wp_submit(dartPort, s->printerId.c_str(), s->jobName.c_str(),
                         pdfData, (int)pdfData_length, buildWpAttrs(s).c_str());
            return;
        }
        if (s && s->printerId.rfind("qz:", 0) == 0) {
            //QZ: silent driver print, resolved on spooler accept (PrintOutcome.printed).
            js_qz_pdf(dartPort, pdfData, (int)pdfData_length,
                      s->printerId.c_str(), s->copies > 1 ? (int)s->copies : 1);
            return;
        }
        if (s && s->printerId.rfind("agent:", 0) == 0) {
            js_agent_print(dartPort, "pdf", pdfData, (int)pdfData_length,
                           s->printerId.c_str(), s->copies > 1 ? (int)s->copies : 1);
            return;
        }
        // Dialog path: apply pageRange by rewriting the page tree in wasm
        // (classic-xref PDFs; exotic files print in full).
        if (s && (s->pageRangeFrom > 0 || s->pageRangeTo > 0)) {
            auto sub = extractPdfPages(pdfData, pdfData_length,
                                       s->pageRangeFrom, s->pageRangeTo);
            if (!sub.empty()) {
                js_print_blob(dartPort, kDonePrint, sub.data(), (int)sub.size(),
                              "application/pdf", 0, "");
                return;
            }
        }
        js_print_blob(dartPort, kDonePrint, pdfData, (int)pdfData_length,
                      "application/pdf", 0, "");
    }

    void printDocument(NitroCppBuffer document, NitroCppBuffer settings,
                       NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        PrintDocument doc = PrintDocument::fromNative(document);
        auto s = decodeSettings(settings);
        if (doc.type == DOCUMENTTYPE_PDF && s && !s->printerId.empty() &&
            js_wp_has_printer(s->printerId.c_str())) {
            std::string title = !doc.title.empty() ? doc.title : s->jobName;
            js_wp_submit(dartPort, s->printerId.c_str(), title.c_str(),
                         doc.data.data(), (int)doc.data.size(), buildWpAttrs(s).c_str());
            return;
        }
        if (doc.type == DOCUMENTTYPE_PDF && s && s->printerId.rfind("qz:", 0) == 0) {
            js_qz_pdf(dartPort, doc.data.data(), (int)doc.data.size(),
                      s->printerId.c_str(), s->copies > 1 ? (int)s->copies : 1);
            return;
        }
        if (s && s->printerId.rfind("agent:", 0) == 0 &&
            doc.type != DOCUMENTTYPE_HTML) {
            const char* kind = doc.type == DOCUMENTTYPE_PDF ? "pdf"
                : doc.type == DOCUMENTTYPE_IMAGE ? "image" : "text";
            js_agent_print(dartPort, kind, doc.data.data(), (int)doc.data.size(),
                           s->printerId.c_str(), s->copies > 1 ? (int)s->copies : 1);
            return;
        }
        if (doc.type == DOCUMENTTYPE_PLAIN_TEXT && s && isRawPrinterId(s->printerId)) {
            auto escPos = textToEscPos(std::string(doc.data.begin(), doc.data.end()));
            rawPrintDecoded(escPos.data(), escPos.size(), s, dartPort, /*forceSingle=*/false);
            return;
        }
        if (doc.type == DOCUMENTTYPE_IMAGE && s && isRawPrinterId(s->printerId)) {
            int widthDots = (s->paperSize == PAPERSIZE_CUSTOM && s->customPaperWidth > 200) ? 576 : 384;
            int copies = s->copies > 1 ? (int)s->copies : 1;
            int64_t t = s->networkTimeoutSeconds > 0 ? s->networkTimeoutSeconds : 30;
            js_image_escpos(dartPort, doc.data.data(), (int)doc.data.size(),
                            s->printerId.c_str(), copies, (int)(t * 1000), widthDots);
            return;
        }
        if (doc.type == DOCUMENTTYPE_PDF && s &&
            (s->pageRangeFrom > 0 || s->pageRangeTo > 0)) {
            auto sub = extractPdfPages(doc.data.data(), doc.data.size(),
                                       s->pageRangeFrom, s->pageRangeTo);
            if (!sub.empty()) {
                js_print_blob(dartPort, kDonePrint, sub.data(), (int)sub.size(),
                              "application/pdf", 0, "");
                return;
            }
        }
        dispatchDoc(doc, dartPort, kDonePrint, buildDialogOpts(s));
    }

    ///Per item: plain text to a raw printerId → ESC/POS, PDF to a Web Printing
    ///printer → real job, everything else → dialog; sequential.
    void printBatch(NitroCppBuffer documents, bool stopOnError, NitroCppBuffer settings,
                    NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        auto s = decodeSettings(settings);
        bool rawId = s && isRawPrinterId(s->printerId);
        bool wpId = s && !s->printerId.empty() && js_wp_has_printer(s->printerId.c_str());
        // Param wire format: [int32 count][int64 offsets×count][item bytes...]
        NitroRecordReader r(documents);
        int32_t count = r.readInt32();
        if (count < 0) throw std::runtime_error("printBatch: malformed document list");
        //Per-item success is a 64-bit mask; items past 64 report as failed.
        std::vector<int64_t> offsets((size_t)count);
        for (int32_t i = 0; i < count; i++) offsets[(size_t)i] = r.readInt();
        for (int32_t i = 0; i < count; i++) {
            int64_t off = offsets[(size_t)i];
            if (off < 0 || (size_t)off > documents.size) {
                throw std::runtime_error("printBatch: document offset out of range");
            }
            NitroRecordReader itemReader(documents.data + off, documents.size - (size_t)off);
            PrintDocument doc = PrintDocument::fromReader(itemReader);
            if (rawId && doc.type == DOCUMENTTYPE_PLAIN_TEXT) {
                auto escPos = textToEscPos(std::string(doc.data.begin(), doc.data.end()));
                js_batch_add(1, (int)doc.type, escPos.data(), (int)escPos.size());
            } else if (wpId && doc.type == DOCUMENTTYPE_PDF) {
                js_batch_add(2, (int)doc.type, doc.data.data(), (int)doc.data.size());
            } else {
                js_batch_add(0, (int)doc.type, doc.data.data(), (int)doc.data.size());
            }
        }
        int64_t t = (s && s->networkTimeoutSeconds > 0) ? s->networkTimeoutSeconds : 30;
        js_batch_run(dartPort, stopOnError ? 1 : 0, buildDialogOpts(s).c_str(),
                     s ? s->printerId.c_str() : "", buildWpAttrs(s).c_str(),
                     (int)(t * 1000));
    }

    ///http(s)/data/blob URLs are fetched and printed by sniffed type; plain
    ///paths return false (no local filesystem).
    void printFile(const std::string& filePath, NitroCppBuffer settings,
                   NitroError* _nitro_err, int64_t dartPort) override {
        (void)settings; (void)_nitro_err;
        bool isUrl = filePath.rfind("http://", 0) == 0 ||
                     filePath.rfind("https://", 0) == 0 ||
                     filePath.rfind("data:", 0) == 0 ||
                     filePath.rfind("blob:", 0) == 0;
        if (isUrl) {
            js_fetch_print(dartPort, filePath.c_str());
            return;
        }
        postBool(dartPort, false);
    }

    // ── Dialog / preview / page count ────────────────────────────────────

    void showPrintDialog(NitroCppBuffer document, NitroCppBuffer initialSettings,
                         NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        auto s = decodeSettings(initialSettings);
        g_pendingDialogs[dartPort] = s ? *s : defaultSettings();
        PrintDocument doc = PrintDocument::fromNative(document);
        dispatchDoc(doc, dartPort, kDoneDialog, buildDialogOpts(s));
    }

    /// PDF documents pass through (pageRange extracts a sub-document); plain
    /// text renders to a generated PDF sized by PrintSettings; images and
    /// HTML rasterize through the browser canvas into real PDFs.
    void renderPreview(NitroCppBuffer document, NitroCppBuffer settings,
                       NitroError* _nitro_err, int64_t dartPort) override {
        PrintDocument doc = PrintDocument::fromNative(document);
        auto s = decodeSettings(settings);
        if (doc.type == DOCUMENTTYPE_IMAGE && !doc.data.empty()) {
            g_pendingImagePdf[dartPort] = {0, pageGeomFrom(s), ""};
            js_image_to_jpeg(dartPort, doc.data.data(), (int)doc.data.size());
            return; // completes via nitro_printing_web_image_jpeg
        }
        if (doc.type == DOCUMENTTYPE_HTML && !doc.data.empty()) {
            PageGeom g = pageGeomFrom(s);
            g_pendingHtmlPdf[dartPort] = {0, g, ""};
            std::string html(doc.data.begin(), doc.data.end());
            js_html_to_jpegs(dartPort, html.c_str(), g.w, g.h, buildDialogOpts(s).c_str());
            return; // completes via nitro_printing_web_html_jpegs
        }
        if (doc.type == DOCUMENTTYPE_PLAIN_TEXT) {
            //Same logical→copies→N-up pipeline as the dialog, one JPEG per physical sheet.
            PageGeom g = pageGeomFrom(s);
            g_pendingHtmlPdf[dartPort] = {0, g, "", 0};
            std::string text(doc.data.begin(), doc.data.end());
            js_text_preview_jpegs(dartPort, text.c_str(),
                                  buildDialogOpts(s).c_str(), g.w, g.h);
            return; // completes via nitro_printing_web_html_jpegs
        }
        auto* bytes = new std::vector<uint8_t>();
        if (doc.type == DOCUMENTTYPE_PDF) {
            if (s && (s->pageRangeFrom > 0 || s->pageRangeTo > 0)) {
                *bytes = extractPdfPages(doc.data.data(), doc.data.size(),
                                         s->pageRangeFrom, s->pageRangeTo);
            }
            if (bytes->empty()) *bytes = std::move(doc.data);
        }
        PreviewResult* pv = (PreviewResult*)::malloc(sizeof(PreviewResult));
        if (pv == nullptr) {
            delete bytes;
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
        // Dart frees only the shell; the bytes stay native-owned and must
        // outlive the Dart view — retire the previous preview instead.
        static uint8_t emptyPreviewByte = 0;
        delete g_lastPreview;
        g_lastPreview = bytes;
        pv->bytes = bytes->empty() ? &emptyPreviewByte : bytes->data();
        pv->length = (int64_t)bytes->size();
        postOwnedBlob(dartPort, (uint8_t*)pv);
    }

    void getPageCount(NitroCppBuffer document, NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        PrintDocument doc = PrintDocument::fromNative(document);
        int64_t pages = 0;
        switch (doc.type) {
            case DOCUMENTTYPE_PDF: {
                PdfDoc parsed = parsePdf(doc.data.data(), doc.data.size());
                pages = parsed.leaves.empty()
                            ? countPdfPages(doc.data.data(), doc.data.size())
                            : (int64_t)parsed.leaves.size();
                break;
            }
            case DOCUMENTTYPE_PLAIN_TEXT: {
                int64_t lines = 1;
                for (uint8_t c : doc.data) {
                    if (c == '\n') lines++;
                }
                pages = (lines + 59) / 60; // matches textToPdf's 60 lines/page
                break;
            }
            case DOCUMENTTYPE_IMAGE:
                pages = 1;
                break;
            default: { // HTML — rasterize at A4 geometry and count the slices
                PageGeom g;
                g_pendingHtmlPdf[dartPort] = {2, g, ""};
                std::string html(doc.data.begin(), doc.data.end());
                js_html_to_jpegs(dartPort, html.c_str(), g.w, g.h, "");
                return; // completes via nitro_printing_web_html_jpegs
            }
        }
        postInt64(dartPort, pages);
    }

    void printToFile(NitroCppBuffer document, const std::string& outputPath, NitroCppBuffer settings,
                     NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        //Browser download named after outputPath's basename; text and images
        //render to PDF first.
        PrintDocument doc = PrintDocument::fromNative(document);
        auto s = decodeSettings(settings);
        std::string name = outputPath;
        size_t slash = name.find_last_of("/\\");
        if (slash != std::string::npos) name = name.substr(slash + 1);
        if (name.empty()) name = doc.title.empty() ? "document" : doc.title;
        if (doc.type == DOCUMENTTYPE_IMAGE && !doc.data.empty()) {
            g_pendingImagePdf[dartPort] = {1, pageGeomFrom(s), name};
            js_image_to_jpeg(dartPort, doc.data.data(), (int)doc.data.size());
            return; // completes via nitro_printing_web_image_jpeg
        }
        if (doc.type == DOCUMENTTYPE_HTML && !doc.data.empty()) {
            PageGeom g = pageGeomFrom(s);
            g_pendingHtmlPdf[dartPort] = {1, g, name};
            std::string html(doc.data.begin(), doc.data.end());
            js_html_to_jpegs(dartPort, html.c_str(), g.w, g.h, buildDialogOpts(s).c_str());
            return; // completes via nitro_printing_web_html_jpegs
        }
        std::vector<uint8_t> out;
        const char* mime;
        switch (doc.type) {
            case DOCUMENTTYPE_PLAIN_TEXT:
                out = textToPdf(std::string(doc.data.begin(), doc.data.end()),
                                pageGeomFrom(s), s ? s->headerText : "",
                                s ? s->footerText : "",
                                s ? s->pageRangeFrom : 0, s ? s->pageRangeTo : 0);
                mime = "application/pdf";
                break;
            case DOCUMENTTYPE_PDF:
                out = std::move(doc.data);
                mime = "application/pdf";
                break;
            default:
                out = std::move(doc.data);
                mime = "text/html";
        }
        js_download(out.data(), (int)out.size(), mime, name.c_str());
        postBool(dartPort, true);
    }

    // ── Job management (Web Printing jobs; empty elsewhere) ──────────────

    void cancelPrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postBool(dartPort, js_wp_cancel_job(jobId.c_str()) != 0);
    }

    void pausePrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)jobId; (void)_nitro_err;
        postBool(dartPort, false); // no pause in the Web Printing API
    }

    ///Resume re-dispatches a finished raw job's kept payload; Web Printing jobs
    ///and dialog prints are not resumable.
    void resumePrintJob(const std::string& jobId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        js_resume_job(dartPort, jobId.c_str());
    }

    void clearPrintQueue(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postBool(dartPort, js_wp_clear_jobs() > 0);
    }

    void getPrintJobsCount(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        postInt64(dartPort, (int64_t)currentJobs().size());
    }

    // ── Connection / admin ───────────────────────────────────────────────

    void testPrinterConnection(const std::string& printerId, std::optional<int64_t> timeoutSeconds,
                               NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        int64_t t = (timeoutSeconds && *timeoutSeconds > 0) ? *timeoutSeconds : 5;
        js_test_connection(dartPort, printerId.c_str(), (int)(t * 1000));
    }

    void setDefaultPrinter(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId; (void)_nitro_err;
        postBool(dartPort, false); // no default-printer concept on the web
    }

    void openSystemPrintQueue(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId; (void)_nitro_err;
        postBool(dartPort, false); // OS UI is unreachable
    }

    void openPrinterProperties(const std::string& printerId, NitroError* _nitro_err, int64_t dartPort) override {
        (void)printerId; (void)_nitro_err;
        postBool(dartPort, false); // OS UI is unreachable
    }

    // ── Raw protocol printing (WebUSB / WS relay / Direct Sockets) ───────

    void printRaw(const uint8_t* data, size_t data_length, NitroCppBuffer settings,
                  NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        rawPrint(data, data_length, settings, dartPort, /*forceSingle=*/false);
    }

    void printEscPos(const uint8_t* escPosData, size_t escPosData_length, NitroCppBuffer settings,
                     NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        rawPrint(escPosData, escPosData_length, settings, dartPort, /*forceSingle=*/false);
    }

    void printZpl(const std::string& zpl, NitroCppBuffer settings,
                  NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        //ZPL carries its own quantity commands: always one write.
        rawPrint((const uint8_t*)zpl.data(), zpl.size(), settings, dartPort, /*forceSingle=*/true);
    }

    void cancelRawPrint(NitroError* _nitro_err, int64_t dartPort) override {
        (void)_nitro_err;
        js_raw_cancel(dartPort);
    }

    // Streams: onPrinterDiscovered fires when the WebUSB picker grants a
    // device; onPrintJobChanged follows Web Printing job states;
    // onPrinterStatusChanged never fires (no push source in the sandbox).

private:
    static void rawPrint(const uint8_t* data, size_t len, NitroCppBuffer settings,
                         int64_t port, bool forceSingle) {
        rawPrintDecoded(data, len, decodeSettings(settings), port, forceSingle);
    }

    static void rawPrintDecoded(const uint8_t* data, size_t len,
                                const std::optional<PrintSettings>& s,
                                int64_t port, bool forceSingle) {
        std::string printerId = s ? s->printerId : "";
        int copies = (!forceSingle && s && s->copies > 1) ? (int)s->copies : 1;
        int64_t t = (s && s->networkTimeoutSeconds > 0) ? s->networkTimeoutSeconds : 30;
        js_raw_print(port, data, (int)len, printerId.c_str(), copies, (int)(t * 1000));
    }

    /// Routes a PrintDocument to the matching dialog print flow.
    static void dispatchDoc(const PrintDocument& doc, int64_t port, int kind,
                            const std::string& opts) {
        switch (doc.type) {
            case DOCUMENTTYPE_PLAIN_TEXT: {
                std::string text(doc.data.begin(), doc.data.end());
                js_print_text(port, kind, text.c_str(), opts.c_str());
                break;
            }
            case DOCUMENTTYPE_HTML: {
                std::string html(doc.data.begin(), doc.data.end());
                js_print_html(port, kind, html.c_str(), opts.c_str());
                break;
            }
            case DOCUMENTTYPE_PDF:
                js_print_blob(port, kind, doc.data.data(), (int)doc.data.size(),
                              "application/pdf", 0, "");
                break;
            case DOCUMENTTYPE_IMAGE:
            default:
                js_print_blob(port, kind, doc.data.data(), (int)doc.data.size(),
                              sniffImageMime(doc.data.data(), doc.data.size()), 1,
                              opts.c_str());
                break;
        }
    }

    /// Web Printing jobs from the JS cache.
    static std::vector<PrintJob> currentJobs() {
        auto table = takeString(js_sync_jobs());
        std::vector<PrintJob> jobs;
        if (!table) return jobs;
        for (const auto& row : splitTable(table->c_str())) {
            jobs.push_back(jobFromRow(row));
        }
        return jobs;
    }
};

//Registers during module instantiation (__wasm_call_ctors), before any
//Dart call; single-instance register_impl API.
HybridNitroPrintingImpl g_nitro_printing_impl;

void emitDiscovered(const std::vector<std::string>& f) {
    // row: id, name, host, port(unused=""), serviceType, uri, isAvailable
    if (f.size() < 7) return;
    DiscoveredPrinter p{};
    p.id = f[0];
    p.name = f[1];
    p.host = f[2];
    p.port = toInt(f[3]);
    p.serviceType = f[4];
    p.uri = f[5];
    p.isAvailable = toBool(f[6]);
    g_nitro_printing_impl.emit_onPrinterDiscovered(p.toNativeBuffer());
}

void emitJobChanged(const std::vector<std::string>& f) {
    if (f.size() < 9) return;
    PrintJob j = jobFromRow(f);
    PrintJobUpdate u{};
    u.jobId = j.id;
    u.state = j.state;
    u.progress = j.progress;
    u.message = j.errorMessage;
    g_nitro_printing_impl.emit_onPrintJobChanged(u.toNativeBuffer());
}

// row: id, online, printing, state, reasons
void emitStatusChanged(const std::vector<std::string>& f) {
    if (f.size() < 5) return;
    PrinterStatus s{};
    s.printerId = f[0];
    s.isOnline = toBool(f[1]);
    s.isPrinting = toBool(f[2]);
    s.statusMessage = f[3];
    s.errorCode = f[4];
    s.inkLevel = s.tonerLevel = s.paperLevel = -1;
    s.jobsInQueue = 0;
    g_nitro_printing_impl.emit_onPrinterStatusChanged(s.toNativeBuffer());
}

__attribute__((constructor))
void nitro_printing_auto_register() {
    nitro_printing_register_impl(&g_nitro_printing_impl);
}

} // namespace

#endif // __EMSCRIPTEN__
