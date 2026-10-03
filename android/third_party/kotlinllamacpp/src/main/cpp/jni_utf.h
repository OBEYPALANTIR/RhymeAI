#pragma once

#include <cstddef>
#include <string>

// JNI's GetStringUTFChars/NewStringUTF use modified UTF-8 (supplementary characters as
// CESU-8 surrogate pairs, NUL as C0 80). llama.cpp and nlohmann::json speak standard
// UTF-8, so strings cross the boundary through these explicit UTF-16 <-> UTF-8 conversions.
// Both directions are total: malformed input becomes U+FFFD instead of failing or crashing.
namespace jniutf {

constexpr char32_t kReplacement = 0xFFFD;

inline void appendUtf8(std::string &out, char32_t cp) {
    if (cp < 0x80) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
}

// UTF-16 code units -> standard UTF-8. Lone surrogates become U+FFFD. NUL stays 0x00.
inline std::string utf16ToUtf8(const char16_t *units, size_t length) {
    std::string out;
    out.reserve(length);
    for (size_t i = 0; i < length; ++i) {
        const char16_t u = units[i];
        if (u >= 0xD800 && u <= 0xDBFF) {
            if (i + 1 < length && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF) {
                const char32_t cp = 0x10000 + ((static_cast<char32_t>(u) - 0xD800) << 10)
                        + (static_cast<char32_t>(units[i + 1]) - 0xDC00);
                appendUtf8(out, cp);
                ++i;
            } else {
                appendUtf8(out, kReplacement);
            }
        } else if (u >= 0xDC00 && u <= 0xDFFF) {
            appendUtf8(out, kReplacement);
        } else {
            appendUtf8(out, u);
        }
    }
    return out;
}

// Standard UTF-8 -> UTF-16. Overlong forms, encoded surrogates, values above U+10FFFF,
// truncated and stray continuation bytes each become one U+FFFD per offending lead byte.
inline std::u16string utf8ToUtf16(const char *bytes, size_t length) {
    std::u16string out;
    out.reserve(length);
    size_t i = 0;
    while (i < length) {
        const unsigned char b = static_cast<unsigned char>(bytes[i]);
        if (b < 0x80) {
            out.push_back(b);
            ++i;
            continue;
        }
        size_t need = 0;
        char32_t cp = 0;
        char32_t min = 0;
        if (b >= 0xC2 && b <= 0xDF) { need = 1; cp = b & 0x1F; min = 0x80; }
        else if (b >= 0xE0 && b <= 0xEF) { need = 2; cp = b & 0x0F; min = 0x800; }
        else if (b >= 0xF0 && b <= 0xF4) { need = 3; cp = b & 0x07; min = 0x10000; }
        bool ok = need != 0;
        if (ok) {
            for (size_t k = 1; k <= need; ++k) {
                if (i + k >= length) { ok = false; break; }
                const unsigned char c = static_cast<unsigned char>(bytes[i + k]);
                if ((c & 0xC0) != 0x80) { ok = false; break; }
                cp = (cp << 6) | (c & 0x3F);
            }
        }
        if (ok && (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))) ok = false;
        if (!ok) {
            out.push_back(static_cast<char16_t>(kReplacement));
            ++i;
            continue;
        }
        if (cp >= 0x10000) {
            const char32_t v = cp - 0x10000;
            out.push_back(static_cast<char16_t>(0xD800 + (v >> 10)));
            out.push_back(static_cast<char16_t>(0xDC00 + (v & 0x3FF)));
        } else {
            out.push_back(static_cast<char16_t>(cp));
        }
        i += need + 1;
    }
    return out;
}

// Bound and NUL check shared by bounded string reads and file-system paths: an embedded NUL
// would silently truncate C-string consumers, so it is rejected rather than converted.
inline bool acceptBounded(const std::string &value, size_t maxBytes) {
    return value.size() < maxBytes && value.find('\0') == std::string::npos;
}

}  // namespace jniutf
