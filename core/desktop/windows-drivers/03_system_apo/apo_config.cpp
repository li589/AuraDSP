// apo_config.cpp — AuraAPO 端点挂载管理 CLI（apo_config.py 的原生移植，
// 真机报告 2026-11-09 §2.3 方案 A：去除 Python 运行时依赖）。
//
// 语义与 apo_config.py 1:1 对齐（注册表 Child APOs 隔离快照、!KEY /
// !VALUE 哨兵、复合槽 MULTI_SZ、双层备份、心跳握手、服务重启、
// --json 输出形状与退出码），Python 版保留为开发参照。差异仅两处：
//  ① 端点枚举直接调 auraapo_inspect 库（不再子进程跑 apo_inspect.exe）；
//  ② DLL/备份目录按 exe 所在目录解析（安装布局 driver/ 与开发布局
//     out/<Config> 均成立），不再依赖仓库相对路径推导。
//
// 安全守则与 Python 版相同：变更前先落双层备份；卸载按快照精确
// 还原原始厂商 APO；物理声卡挂载必须 --force；写操作必须 --yes。
#include <windows.h>
#include <shellapi.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <fcntl.h>
#include <functional>
#include <io.h>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "ApoInspector.h"
#include "AuraHeartbeat.h"

namespace {

// ---------------------------------------------------------------------------
// 常量（与 apo_config.py 对齐）
// ---------------------------------------------------------------------------

const wchar_t* kOurClsid = L"{415AD8ED-7A45-4F4F-AC69-043830EBC174}";
const std::string kOurClsidUtf8 = "{415AD8ED-7A45-4F4F-AC69-043830EBC174}";
const wchar_t* kFxBase = L"{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}";
const wchar_t* kProcModes = L"{d3993a3f-99c2-4402-b5ec-a92a0367664b}";
const wchar_t* kDisableEnh = L"{1da5d803-d492-4edd-8c23-e0c0ffee7f0e}";
const wchar_t* kDefaultMode = L"{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}";
const wchar_t* kNullGuid = L"{00000000-0000-0000-0000-000000000000}";

const wchar_t* kMmBase =
    L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio";
const wchar_t* kChildApoRoot = L"SOFTWARE\\AuraDSP\\Child APOs";
const wchar_t* kTestEnvKey =
    L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Audio";
const wchar_t* kTestEnvVal = L"DisableProtectedAudioDG";

const wchar_t* kSentinelNoKey = L"!KEY";
const wchar_t* kSentinelNoValue = L"!VALUE";

std::vector<std::wstring> SlotKeys() {
    const std::wstring fx = kFxBase;
    return {
        fx + L",0",   // PKEY_FX_Association
        fx + L",1",   // LFX
        fx + L",2",   // GFX
        fx + L",5",   // SFX
        fx + L",6",   // MFX
        fx + L",7",   // EFX
        fx + L",13",  // Composite Multi-SFX (Win10 1803+)
        fx + L",14",  // Composite Multi-MFX
        fx + L",15",  // Composite Multi-EFX
        std::wstring(kDisableEnh) + L",5",
        std::wstring(kProcModes) + L",5",
        std::wstring(kProcModes) + L",6",
        std::wstring(kProcModes) + L",7",
    };
}

// ---------------------------------------------------------------------------
// 字符串转换 / 工具
// ---------------------------------------------------------------------------

std::string WideToUtf8(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(),
                                      static_cast<int>(w.size()), nullptr, 0,
                                      nullptr, nullptr);
    std::string s(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()),
                        s.data(), n, nullptr, nullptr);
    return s;
}

std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                      static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                        w.data(), n);
    return w;
}

std::wstring ToLowerW(std::wstring s) {
    for (auto& c : s) c = static_cast<wchar_t>(towlower(c));
    return s;
}

std::string ToLowerA(std::string s) {
    for (auto& c : s) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    return s;
}

bool ContainsCi(const std::wstring& hay, const std::wstring& needle) {
    if (needle.empty()) return true;
    return ToLowerW(hay).find(ToLowerW(needle)) != std::wstring::npos;
}

// 与 Python re 搜索 GUID 模式等价：找首个 {8-4-4-4-12 hex} 子串。
std::wstring ShortGuid(const std::wstring& longId) {
    auto isHex = [](wchar_t c) {
        return (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') ||
               (c >= L'A' && c <= L'F');
    };
    for (size_t i = 0; i + 38 <= longId.size(); ++i) {
        if (longId[i] != L'{') continue;
        const size_t segLens[5] = {8, 4, 4, 4, 12};
        size_t p = i + 1;
        bool ok = true;
        for (int seg = 0; seg < 5 && ok; ++seg) {
            for (size_t j = 0; j < segLens[seg]; ++j, ++p) {
                if (p >= longId.size() || !isHex(longId[p])) {
                    ok = false;
                    break;
                }
            }
            if (seg < 4) {
                if (p >= longId.size() || longId[p] != L'-') ok = false;
                ++p;
            }
        }
        if (ok && p < longId.size() && longId[p] == L'}') {
            return longId.substr(i, 38);
        }
    }
    return longId;
}

std::wstring NowStamp() {
    SYSTEMTIME st{};
    GetLocalTime(&st);
    wchar_t buf[32];
    swprintf(buf, 32, L"%04u%02u%02u_%02u%02u%02u", st.wYear, st.wMonth,
             st.wDay, st.wHour, st.wMinute, st.wSecond);
    return buf;
}

std::wstring ModuleDir() {
    wchar_t path[MAX_PATH * 4];
    const DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH * 4);
    std::wstring p(path, n);
    const size_t slash = p.find_last_of(L"\\/");
    return slash == std::wstring::npos ? L"." : p.substr(0, slash);
}

bool FileExists(const std::wstring& p) {
    const DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

bool DirExists(const std::wstring& p) {
    const DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

void MakeDirs(const std::wstring& p) {
    if (p.empty() || DirExists(p)) return;
    const size_t slash = p.find_last_of(L"\\/");
    if (slash != std::wstring::npos && slash > 2) MakeDirs(p.substr(0, slash));
    CreateDirectoryW(p.c_str(), nullptr);
}

// 备份目录：开发布局（exe 在 out/<Config>）→ out/apo-backups（对齐
// Python 版 OUT/apo-backups）；安装布局（exe 在 driver/）→ 同级
// apo-backups（对齐 Python 版回退 SCRIPT_DIR/apo-backups）。
std::wstring BackupDir() {
    const std::wstring dir = ModuleDir();
    const size_t slash = dir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
        const std::wstring parent = dir.substr(0, slash);
        const std::wstring leaf = dir.substr(slash + 1);
        (void)leaf;
        const size_t pslash = parent.find_last_of(L"\\/");
        const std::wstring parentLeaf =
            pslash == std::wstring::npos ? parent : parent.substr(pslash + 1);
        if (ToLowerW(parentLeaf) == L"out") return parent + L"\\apo-backups";
    }
    return dir + L"\\apo-backups";
}

// AuraApo.dll 候选路径（exe 同级优先：安装布局与 out/<Config> 均命中）。
std::wstring FindDll() {
    const std::wstring dir = ModuleDir();
    const std::wstring cands[] = {
        dir + L"\\AuraApo.dll",
        dir + L"\\..\\AuraApo.dll",
        dir + L"\\bin\\AuraApo.dll",
        dir + L"\\..\\bin\\AuraApo.dll",
    };
    for (const auto& c : cands) {
        if (FileExists(c)) return c;
    }
    return cands[0];
}

// 管理员判定（等价 Python 版 IsUserAnAdmin；用 CheckTokenMembership
// 避免引入 shlobj 头依赖）。
bool IsAdmin() {
    SID_IDENTIFIER_AUTHORITY ntAuth = SECURITY_NT_AUTHORITY;
    PSID sid = nullptr;
    BOOL member = FALSE;
    if (AllocateAndInitializeSid(&ntAuth, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                 DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                 &sid)) {
        CheckTokenMembership(nullptr, sid, &member);
        FreeSid(sid);
    }
    return member != FALSE;
}

bool IsWin7OrEarlier() {
    OSVERSIONINFOW vi{};
    vi.dwOSVersionInfoSize = sizeof(vi);
    // GetVersionEx 已弃用但对本判断足够且无清单依赖问题；失败按新系统处理。
#pragma warning(push)
#pragma warning(disable : 4996)
    if (GetVersionExW(&vi) == FALSE) return false;
#pragma warning(pop)
    return vi.dwMajorVersion < 6 ||
           (vi.dwMajorVersion == 6 && vi.dwMinorVersion <= 1);
}

// ---------------------------------------------------------------------------
// 极简 JSON（值模型 + 序列化 + 解析；仅覆盖本工具读写所需子集）
// ---------------------------------------------------------------------------

struct Json {
    enum class Type { Null, Bool, Num, Str, Arr, Obj };
    Type type = Type::Null;
    bool boolean = false;
    double num = 0;
    std::string str;
    std::vector<Json> arr;
    // 对象成员走 shared_ptr 装箱：vector<pair<string,Json>> 直接作
    // 成员会形成析构递归实例化环，部分 STL（libstdc++）直接拒绝；
    // 装箱后成员表在 Json 完整后才实例化，全实现可移植。
    struct ObjData;
    std::shared_ptr<ObjData> objData;
    using Member = std::pair<std::string, Json>;
    using MemberList = std::vector<Member>;
    const MemberList& ObjMembers() const;
    void AddMember(std::string key, Json value);

    static Json Bool(bool b);
    static Json Num(double n);
    static Json Str(std::string s);
    static Json Arr(std::vector<Json> a);
    static Json Obj(MemberList o);
    const Json* Find(const std::string& key) const;
};

struct Json::ObjData {
    MemberList members;
};

inline const Json::MemberList& Json::ObjMembers() const {
    static const MemberList kEmpty;
    return objData ? objData->members : kEmpty;
}
inline void Json::AddMember(std::string key, Json value) {
    if (!objData) objData = std::make_shared<ObjData>();
    objData->members.emplace_back(std::move(key), std::move(value));
}

inline Json Json::Bool(bool b) {
    Json j;
    j.type = Type::Bool;
    j.boolean = b;
    return j;
}
inline Json Json::Num(double n) {
    Json j;
    j.type = Type::Num;
    j.num = n;
    return j;
}
inline Json Json::Str(std::string s) {
    Json j;
    j.type = Type::Str;
    j.str = std::move(s);
    return j;
}
inline Json Json::Arr(std::vector<Json> a) {
    Json j;
    j.type = Type::Arr;
    j.arr = std::move(a);
    return j;
}
inline Json Json::Obj(MemberList o) {
    Json j;
    j.type = Type::Obj;
    j.objData = std::make_shared<ObjData>();
    j.objData->members = std::move(o);
    return j;
}
inline const Json* Json::Find(const std::string& key) const {
    if (type != Type::Obj) return nullptr;
    for (const auto& [k, v] : ObjMembers()) {
        if (k == key) return &v;
    }
    return nullptr;
}

std::string JsonEscape(const std::string& s) {
    std::string o;
    for (const unsigned char c : s) {
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, 8, "\\u%04x", c);
                    o += buf;
                } else {
                    o += static_cast<char>(c);
                }
        }
    }
    return o;
}

void JsonWrite(const Json& j, std::string& out) {
    switch (j.type) {
        case Json::Type::Null:
            out += "null";
            break;
        case Json::Type::Bool:
            out += j.boolean ? "true" : "false";
            break;
        case Json::Type::Num: {
            // 整数语义优先（DWORD/计数），与 Python json 对 int 的输出一致。
            if (j.num == static_cast<double>(static_cast<long long>(j.num))) {
                out += std::to_string(static_cast<long long>(j.num));
            } else {
                char buf[32];
                snprintf(buf, 32, "%g", j.num);
                out += buf;
            }
            break;
        }
        case Json::Type::Str:
            out += '"';
            out += JsonEscape(j.str);
            out += '"';
            break;
        case Json::Type::Arr: {
            out += '[';
            bool first = true;
            for (const auto& e : j.arr) {
                if (!first) out += ',';
                first = false;
                JsonWrite(e, out);
            }
            out += ']';
            break;
        }
        case Json::Type::Obj: {
            out += '{';
            bool first = true;
            for (const auto& [k, v] : j.ObjMembers()) {
                if (!first) out += ',';
                first = false;
                out += '"';
                out += JsonEscape(k);
                out += "\":";
                JsonWrite(v, out);
            }
            out += '}';
            break;
        }
    }
}

std::string JsonString(const Json& j) {
    std::string s;
    JsonWrite(j, s);
    return s;
}

struct JsonParser {
    const char* p;
    const char* end;

    void SkipWs() {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'))
            ++p;
    }
    bool Consume(char c) {
        SkipWs();
        if (p < end && *p == c) {
            ++p;
            return true;
        }
        return false;
    }
    bool ParseValue(Json& out) {
        SkipWs();
        if (p >= end) return false;
        switch (*p) {
            case '{': {
                ++p;
                out = Json::Obj({});
                if (Consume('}')) return true;
                while (true) {
                    Json key;
                    if (!ParseValue(key) || key.type != Json::Type::Str)
                        return false;
                    if (!Consume(':')) return false;
                    Json val;
                    if (!ParseValue(val)) return false;
                    out.AddMember(key.str, std::move(val));
                    if (Consume('}')) return true;
                    if (!Consume(',')) return false;
                }
            }
            case '[': {
                ++p;
                out = Json::Arr({});
                if (Consume(']')) return true;
                while (true) {
                    Json val;
                    if (!ParseValue(val)) return false;
                    out.arr.push_back(std::move(val));
                    if (Consume(']')) return true;
                    if (!Consume(',')) return false;
                }
            }
            case '"': {
                ++p;
                std::string s;
                while (p < end && *p != '"') {
                    if (*p == '\\' && p + 1 < end) {
                        ++p;
                        switch (*p) {
                            case 'n': s += '\n'; break;
                            case 't': s += '\t'; break;
                            case 'r': s += '\r'; break;
                            case 'u': {
                                if (p + 4 >= end) return false;
                                unsigned cp = 0;
                                for (int i = 1; i <= 4; ++i) {
                                    cp <<= 4;
                                    const char h = p[i];
                                    cp += (h >= '0' && h <= '9')
                                              ? static_cast<unsigned>(h - '0')
                                          : (h >= 'a' && h <= 'f')
                                              ? static_cast<unsigned>(h - 'a' + 10)
                                              : static_cast<unsigned>(h - 'A' + 10);
                                }
                                p += 4;
                                // 仅 BMP 基础处理（磁盘快照键值均为 ASCII/中文；
                                // 中文以原始 UTF-8 字节写入，不经 \u 转义）。
                                if (cp < 0x80) {
                                    s += static_cast<char>(cp);
                                } else if (cp < 0x800) {
                                    s += static_cast<char>(0xC0 | (cp >> 6));
                                    s += static_cast<char>(0x80 | (cp & 0x3F));
                                } else {
                                    s += static_cast<char>(0xE0 | (cp >> 12));
                                    s += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                                    s += static_cast<char>(0x80 | (cp & 0x3F));
                                }
                                break;
                            }
                            default: s += *p; break;
                        }
                        ++p;
                    } else {
                        s += *p;
                        ++p;
                    }
                }
                if (p >= end) return false;
                ++p;
                out = Json::Str(std::move(s));
                return true;
            }
            case 't':
                if (end - p >= 4 && memcmp(p, "true", 4) == 0) {
                    p += 4;
                    out = Json::Bool(true);
                    return true;
                }
                return false;
            case 'f':
                if (end - p >= 5 && memcmp(p, "false", 5) == 0) {
                    p += 5;
                    out = Json::Bool(false);
                    return true;
                }
                return false;
            case 'n':
                if (end - p >= 4 && memcmp(p, "null", 4) == 0) {
                    p += 4;
                    out = Json{};
                    return true;
                }
                return false;
            default: {
                const char* start = p;
                while (p < end && (isdigit(static_cast<unsigned char>(*p)) ||
                                   *p == '-' || *p == '+' || *p == '.' ||
                                   *p == 'e' || *p == 'E'))
                    ++p;
                if (p == start) return false;
                out = Json::Num(strtod(start, nullptr));
                return true;
            }
        }
    }
};

bool JsonParse(const std::string& text, Json& out) {
    JsonParser parser{text.data(), text.data() + text.size()};
    return parser.ParseValue(out);
}

bool ReadFileUtf8(const std::wstring& path, std::string& out) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(h, &size) || size.QuadPart > (1 << 24)) {
        CloseHandle(h);
        return false;
    }
    out.resize(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    const BOOL ok = ReadFile(h, out.data(), static_cast<DWORD>(out.size()),
                             &read, nullptr);
    CloseHandle(h);
    if (!ok) return false;
    out.resize(read);
    // 容忍 UTF-8 BOM（Python 版 json.load 对带 BOM 文件同样失败，此处更宽容）。
    if (out.size() >= 3 && out[0] == '\xEF' && out[1] == '\xBB' &&
        out[2] == '\xBF') {
        out.erase(0, 3);
    }
    return true;
}

bool WriteFileUtf8(const std::wstring& path, const std::string& data) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const BOOL ok = WriteFile(h, data.data(), static_cast<DWORD>(data.size()),
                              &written, nullptr);
    CloseHandle(h);
    return ok != FALSE;
}

// ---------------------------------------------------------------------------
// 注册表层（RegValue 值模型 + 读写枚举）
// ---------------------------------------------------------------------------

struct RegValue {
    DWORD type = REG_NONE;
    std::wstring sz;                 // REG_SZ / REG_EXPAND_SZ
    std::vector<std::wstring> multi; // REG_MULTI_SZ
    DWORD dword = 0;                 // REG_DWORD
    std::vector<BYTE> raw;           // 其它类型原样保存（写回保真）

    bool IsSentinel() const {
        return type == REG_SZ && (sz == kSentinelNoKey || sz == kSentinelNoValue);
    }
    Json ToJson() const {
        switch (type) {
            case REG_SZ:
            case REG_EXPAND_SZ:
                return Json::Str(WideToUtf8(sz));
            case REG_MULTI_SZ: {
                std::vector<Json> a;
                for (const auto& s : multi) a.push_back(Json::Str(WideToUtf8(s)));
                return Json::Arr(std::move(a));
            }
            case REG_DWORD:
                return Json::Num(static_cast<double>(dword));
            default:
                return Json::Str({});
        }
    }
    // 从磁盘 JSON 快照还原（Python 版 restore 的类型推断：list→MULTI_SZ，
    // 其余→REG_SZ；数值在注册表快照路径不会出现于 JSON 槽位）。
    static RegValue FromJson(const Json& j) {
        RegValue v;
        if (j.type == Json::Type::Arr) {
            v.type = REG_MULTI_SZ;
            for (const auto& e : j.arr) {
                if (e.type == Json::Type::Str) v.multi.push_back(Utf8ToWide(e.str));
            }
        } else if (j.type == Json::Type::Num) {
            v.type = REG_DWORD;
            v.dword = static_cast<DWORD>(j.num);
        } else if (j.type == Json::Type::Str) {
            v.type = REG_SZ;
            v.sz = Utf8ToWide(j.str);
        } else {
            v.type = REG_SZ;
            v.sz = L"";
        }
        return v;
    }
};

// 读单个值；键或值不存在返回 nullopt（对齐 Python reg_read 的 (None,None)）。
std::optional<RegValue> RegRead(HKEY root, const std::wstring& sub,
                                const std::wstring& name) {
    HKEY k = nullptr;
    if (RegOpenKeyExW(root, sub.c_str(), 0, KEY_QUERY_VALUE, &k) != ERROR_SUCCESS)
        return std::nullopt;
    DWORD type = 0;
    DWORD cb = 0;
    LONG r = RegQueryValueExW(k, name.c_str(), nullptr, &type, nullptr, &cb);
    if (r != ERROR_SUCCESS) {
        RegCloseKey(k);
        return std::nullopt;
    }
    std::vector<BYTE> data(cb ? cb : 1);
    r = RegQueryValueExW(k, name.c_str(), nullptr, &type, data.data(), &cb);
    RegCloseKey(k);
    if (r != ERROR_SUCCESS) return std::nullopt;
    RegValue v;
    v.type = type;
    switch (type) {
        case REG_SZ:
        case REG_EXPAND_SZ: {
            if (cb >= sizeof(wchar_t)) {
                const size_t chars = cb / sizeof(wchar_t);
                v.sz.assign(reinterpret_cast<const wchar_t*>(data.data()), chars);
                while (!v.sz.empty() && v.sz.back() == L'\0') v.sz.pop_back();
            }
            break;
        }
        case REG_MULTI_SZ: {
            const wchar_t* cur =
                reinterpret_cast<const wchar_t*>(data.data());
            const wchar_t* const last = cur + cb / sizeof(wchar_t);
            while (cur < last && *cur != L'\0') {
                const std::wstring s(cur);
                v.multi.push_back(s);
                cur += s.size() + 1;
            }
            break;
        }
        case REG_DWORD:
            if (cb >= sizeof(DWORD))
                memcpy(&v.dword, data.data(), sizeof(DWORD));
            break;
        default:
            v.raw.assign(data.begin(), data.begin() + cb);
            break;
    }
    return v;
}

bool RegWrite(HKEY root, const std::wstring& sub, const std::wstring& name,
              const RegValue& v) {
    HKEY k = nullptr;
    if (RegCreateKeyExW(root, sub.c_str(), 0, nullptr, 0, KEY_SET_VALUE,
                        nullptr, &k, nullptr) != ERROR_SUCCESS)
        return false;
    LONG r;
    switch (v.type) {
        case REG_SZ:
        case REG_EXPAND_SZ: {
            const DWORD cb = static_cast<DWORD>((v.sz.size() + 1) * sizeof(wchar_t));
            r = RegSetValueExW(k, name.c_str(), 0, v.type,
                               reinterpret_cast<const BYTE*>(v.sz.c_str()), cb);
            break;
        }
        case REG_MULTI_SZ: {
            std::vector<wchar_t> buf;
            for (const auto& s : v.multi) {
                buf.insert(buf.end(), s.begin(), s.end());
                buf.push_back(L'\0');
            }
            buf.push_back(L'\0');
            r = RegSetValueExW(k, name.c_str(), 0, REG_MULTI_SZ,
                               reinterpret_cast<const BYTE*>(buf.data()),
                               static_cast<DWORD>(buf.size() * sizeof(wchar_t)));
            break;
        }
        case REG_DWORD: {
            r = RegSetValueExW(k, name.c_str(), 0, REG_DWORD,
                               reinterpret_cast<const BYTE*>(&v.dword),
                               sizeof(DWORD));
            break;
        }
        default: {
            r = RegSetValueExW(k, name.c_str(), 0, v.type, v.raw.data(),
                               static_cast<DWORD>(v.raw.size()));
            break;
        }
    }
    RegCloseKey(k);
    return r == ERROR_SUCCESS;
}

RegValue RegSz(const std::wstring& s) {
    RegValue v;
    v.type = REG_SZ;
    v.sz = s;
    return v;
}
RegValue RegDword(DWORD d) {
    RegValue v;
    v.type = REG_DWORD;
    v.dword = d;
    return v;
}
RegValue RegMulti(std::vector<std::wstring> m) {
    RegValue v;
    v.type = REG_MULTI_SZ;
    v.multi = std::move(m);
    return v;
}

// 枚举一键下全部值（顺序 = 注册表枚举序，对齐 winreg.EnumValue）。
std::vector<std::pair<std::wstring, RegValue>> RegEnumValues(
    HKEY root, const std::wstring& sub) {
    std::vector<std::pair<std::wstring, RegValue>> out;
    HKEY k = nullptr;
    if (RegOpenKeyExW(root, sub.c_str(), 0, KEY_QUERY_VALUE, &k) != ERROR_SUCCESS)
        return out;
    for (DWORD i = 0;; ++i) {
        wchar_t nameBuf[16384];
        DWORD nameCb = 16384;
        DWORD type = 0;
        DWORD cb = 0;
        LONG r = RegEnumValueW(k, i, nameBuf, &nameCb, nullptr, &type, nullptr, &cb);
        if (r != ERROR_SUCCESS) break;
        std::vector<BYTE> data(cb ? cb : 1);
        DWORD cb2 = cb;
        DWORD nameCb2 = 16384;
        r = RegEnumValueW(k, i, nameBuf, &nameCb2, nullptr, &type, data.data(), &cb2);
        if (r != ERROR_SUCCESS) continue;
        nameCb = nameCb2;
        RegValue v;
        v.type = type;
        switch (type) {
            case REG_SZ:
            case REG_EXPAND_SZ: {
                if (cb2 >= sizeof(wchar_t)) {
                    v.sz.assign(reinterpret_cast<const wchar_t*>(data.data()),
                                cb2 / sizeof(wchar_t));
                    while (!v.sz.empty() && v.sz.back() == L'\0') v.sz.pop_back();
                }
                break;
            }
            case REG_MULTI_SZ: {
                const wchar_t* cur = reinterpret_cast<const wchar_t*>(data.data());
                const wchar_t* const last = cur + cb2 / sizeof(wchar_t);
                while (cur < last && *cur != L'\0') {
                    const std::wstring s(cur);
                    v.multi.push_back(s);
                    cur += s.size() + 1;
                }
                break;
            }
            case REG_DWORD:
                if (cb2 >= sizeof(DWORD)) memcpy(&v.dword, data.data(), sizeof(DWORD));
                break;
            default:
                v.raw.assign(data.begin(), data.begin() + cb2);
                break;
        }
        out.emplace_back(std::wstring(nameBuf, nameCb), std::move(v));
    }
    RegCloseKey(k);
    return out;
}

std::vector<std::wstring> RegEnumSubkeys(HKEY root, const std::wstring& sub) {
    std::vector<std::wstring> out;
    HKEY k = nullptr;
    if (RegOpenKeyExW(root, sub.c_str(), 0, KEY_ENUMERATE_SUB_KEYS, &k) !=
        ERROR_SUCCESS)
        return out;
    for (DWORD i = 0;; ++i) {
        wchar_t nameBuf[256];
        DWORD cb = 256;
        if (RegEnumKeyExW(k, i, nameBuf, &cb, nullptr, nullptr, nullptr,
                          nullptr) != ERROR_SUCCESS)
            break;
        out.emplace_back(nameBuf, cb);
    }
    RegCloseKey(k);
    return out;
}

bool RegKeyExists(HKEY root, const std::wstring& sub) {
    HKEY k = nullptr;
    if (RegOpenKeyExW(root, sub.c_str(), 0, KEY_QUERY_VALUE, &k) != ERROR_SUCCESS)
        return false;
    RegCloseKey(k);
    return true;
}

// ---------------------------------------------------------------------------
// 子进程（sc.exe / reg.exe / regsvr32；对齐 Python sh()）
// ---------------------------------------------------------------------------

struct ProcResult {
    int exitCode = -1;
    std::string stdOut;  // UTF-8（子进程输出按本地代码页解码后转码）
};

std::wstring QuoteArg(const std::wstring& a) {
    if (a.find_first_of(L" \t\"") == std::wstring::npos) return a;
    std::wstring q = L"\"";
    for (const wchar_t c : a) {
        if (c == L'"') q += L'\\';
        q += c;
    }
    q += L'"';
    return q;
}

ProcResult RunCmd(const std::vector<std::wstring>& args, int timeoutSec = 120) {
    ProcResult res;
    if (args.empty()) return res;
    std::wstring cmdline;
    for (size_t i = 0; i < args.size(); ++i) {
        if (i) cmdline += L' ';
        cmdline += QuoteArg(args[i]);
    }
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE readPipe = nullptr, writePipe = nullptr;
    if (!CreatePipe(&readPipe, &writePipe, &sa, 0)) return res;
    SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = writePipe;
    si.hStdError = writePipe;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    HANDLE nulIn = nullptr;
    if (si.hStdInput == nullptr ||
        si.hStdInput == INVALID_HANDLE_VALUE) {
        nulIn = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ, &sa,
                            OPEN_EXISTING, 0, nullptr);
        si.hStdInput = nulIn;
    }
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> cmd(cmdline.begin(), cmdline.end());
    cmd.push_back(L'\0');
    if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, 0, nullptr,
                        nullptr, &si, &pi)) {
        CloseHandle(readPipe);
        CloseHandle(writePipe);
        if (nulIn) CloseHandle(nulIn);
        return res;
    }
    if (nulIn) CloseHandle(nulIn);
    CloseHandle(writePipe);
    std::string raw;
    // 边等边排空管道，避免子进程输出填满管道缓冲死锁。
    const DWORD waitMs = timeoutSec > 0 ? timeoutSec * 1000u : INFINITE;
    const ULONGLONG deadlineMs = GetTickCount64() + waitMs;
    while (true) {
        DWORD avail = 0;
        while (PeekNamedPipe(readPipe, nullptr, 0, nullptr, &avail, nullptr) &&
               avail > 0) {
            std::vector<char> buf(avail);
            DWORD got = 0;
            if (!ReadFile(readPipe, buf.data(), avail, &got, nullptr) || got == 0)
                break;
            raw.append(buf.data(), got);
        }
        const DWORD w = WaitForSingleObject(pi.hProcess, 50);
        if (w == WAIT_OBJECT_0) break;
        if (GetTickCount64() >= deadlineMs) {
            TerminateProcess(pi.hProcess, 1);
            WaitForSingleObject(pi.hProcess, 5000);
            break;
        }
    }
    CloseHandle(readPipe);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    res.exitCode = static_cast<int>(code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    // 子进程（sc/reg）输出为系统代码页，转 UTF-8 供 SERVICE_NAME 解析。
    if (!raw.empty()) {
        const int n = MultiByteToWideChar(CP_ACP, 0, raw.data(),
                                          static_cast<int>(raw.size()), nullptr, 0);
        std::wstring w(static_cast<size_t>(n), L'\0');
        MultiByteToWideChar(CP_ACP, 0, raw.data(), static_cast<int>(raw.size()),
                            w.data(), n);
        res.stdOut = WideToUtf8(w);
    }
    return res;
}

// ---------------------------------------------------------------------------
// 心跳（Global\AuraAPO_Heartbeat，与 AuraHeartbeat.h 布局一致）
// ---------------------------------------------------------------------------

struct Heartbeat {
    bool seen = false;       // 至少读到一次合法快照
    bool alive = false;      // seq 在超时内推进
    uint32_t seq = 0;
    uint32_t sr = 0;
    uint64_t frames = 0;
    uint32_t nbs = 0;
    uint32_t pid = 0;
    uint32_t firstSeq = 0;
    uint64_t firstFrames = 0;
};

Heartbeat ReadHeartbeat(double timeoutSec) {
    Heartbeat hb;
    const ULONGLONG deadline = GetTickCount64() +
        static_cast<ULONGLONG>(timeoutSec * 1000.0);
    bool haveFirst = false;
    while (true) {
        HANDLE h = OpenFileMappingW(FILE_MAP_READ, FALSE,
                                    AURA_HEARTBEAT_MAP_NAME);
        if (h) {
            void* view = MapViewOfFile(h, FILE_MAP_READ, 0, 0,
                                       sizeof(AuraHeartbeat));
            if (view) {
                AuraHeartbeat snap{};
                memcpy(&snap, view, sizeof(snap));
                UnmapViewOfFile(view);
                if (snap.magic == AURA_HEARTBEAT_MAGIC &&
                    snap.version == AURA_HEARTBEAT_VERSION) {
                    if (!haveFirst) {
                        haveFirst = true;
                        hb.seen = true;
                        hb.firstSeq = snap.seq;
                        hb.firstFrames = snap.framesTotal;
                    } else if (snap.seq != hb.firstSeq &&
                               snap.framesTotal >= hb.firstFrames) {
                        hb.alive = true;
                        hb.seq = snap.seq;
                        hb.sr = snap.sampleRate;
                        hb.frames = snap.framesTotal;
                        hb.nbs = snap.lastNbs;
                        hb.pid = snap.pid;
                        CloseHandle(h);
                        return hb;
                    }
                }
            }
            CloseHandle(h);
        }
        if (GetTickCount64() >= deadline) break;
        Sleep(300);
    }
    hb.alive = hb.seen;
    return hb;
}

Json HeartbeatJson(const Heartbeat& hb, bool forStatus) {
    if (hb.alive) {
        return Json::Obj({
            {"alive", Json::Bool(true)},
            {"seq", Json::Num(hb.seq)},
            {"frames", Json::Num(static_cast<double>(hb.frames))},
            {"sr", Json::Num(hb.sr)},
            {"nbs", Json::Num(hb.nbs)},
            {"pid", Json::Num(hb.pid)},
        });
    }
    // Python 版未活时返回 {'alive': False, 'first': (seq, frames) | None}；
    // verify-heartbeat 直出该形状，status 内嵌同一形状。
    (void)forStatus;
    Json first = Json{};
    if (hb.seen) {
        first = Json::Arr({Json::Num(hb.firstSeq),
                           Json::Num(static_cast<double>(hb.firstFrames))});
    }
    return Json::Obj({
        {"alive", Json::Bool(false)},
        {"first", std::move(first)},
    });
}

// ---------------------------------------------------------------------------
// 端点枚举（auraapo_inspect 直调；对齐 Python find_endpoints 的过滤）
// ---------------------------------------------------------------------------

struct Endpoint {
    std::string id;         // UTF-8（含花括号 GUID）
    std::string direction;  // "render" / "capture"（ApoInspector 口径）
    std::wstring name;      // name 优先、friendlyName 兜底
    std::wstring rawName;
    std::wstring friendlyName;

    std::wstring DirectionTitle() const {
        std::wstring d = Utf8ToWide(direction);
        if (!d.empty()) d[0] = static_cast<wchar_t>(towupper(d[0]));
        return d;
    }
    std::wstring FxSub() const {
        return std::wstring(kMmBase) + L"\\" + DirectionTitle() + L"\\" +
               ShortGuid(Utf8ToWide(id)) + L"\\FxProperties";
    }
};

std::vector<Endpoint> FindEndpoints(const std::wstring& substr) {
    const ApoInspect r = ApoInspectRun();
    std::vector<Endpoint> out;
    for (const auto& e : r.endpoints) {
        Endpoint ep;
        ep.id = e.id;
        ep.direction = e.direction;
        ep.rawName = Utf8ToWide(e.name);
        ep.friendlyName = Utf8ToWide(e.friendlyName);
        ep.name = !ep.rawName.empty() ? ep.rawName : ep.friendlyName;
        if (!substr.empty()) {
            if (!ContainsCi(ep.rawName, substr) &&
                !ContainsCi(ep.friendlyName, substr) &&
                !ContainsCi(Utf8ToWide(e.id), substr)) {
                continue;
            }
        }
        out.push_back(std::move(ep));
    }
    return out;
}

// COM 注册就绪检查（对齐 Python ensure_com_registered）。
bool EnsureComRegistered() {
    const std::wstring apoSub =
        std::wstring(L"AudioEngine\\AudioProcessingObjects\\") + kOurClsid;
    const std::wstring clsidSub =
        std::wstring(L"CLSID\\") + kOurClsid + L"\\InprocServer32";
    auto hasApo = RegRead(HKEY_CLASSES_ROOT, apoSub, L"FriendlyName");
    auto hasClsid = RegRead(HKEY_CLASSES_ROOT, clsidSub, L"");
    if (hasApo && hasClsid) return true;
    const std::wstring dll = FindDll();
    if (FileExists(dll)) {
        RunCmd({L"regsvr32", L"/s", dll});
        hasApo = RegRead(HKEY_CLASSES_ROOT, apoSub, L"FriendlyName");
        hasClsid = RegRead(HKEY_CLASSES_ROOT, clsidSub, L"");
        return hasApo.has_value() && hasClsid.has_value();
    }
    return false;
}

// 已挂载端点（HKLM\SOFTWARE\AuraDSP\Child APOs 子键全量）。
struct InstalledEndpoint {
    std::wstring shortGuid;
    std::vector<std::pair<std::wstring, RegValue>> values;
    const RegValue* Get(const std::wstring& name) const {
        for (const auto& [n, v] : values) {
            if (n == name) return &v;
        }
        return nullptr;
    }
    std::wstring GetSz(const std::wstring& name) const {
        const RegValue* v = Get(name);
        return (v && v->type == REG_SZ) ? v->sz : L"";
    }
};

std::vector<InstalledEndpoint> GetInstalledChildApos() {
    std::vector<InstalledEndpoint> out;
    for (const auto& guid : RegEnumSubkeys(HKEY_LOCAL_MACHINE, kChildApoRoot)) {
        InstalledEndpoint ep;
        ep.shortGuid = guid;
        ep.values = RegEnumValues(
            HKEY_LOCAL_MACHINE, std::wstring(kChildApoRoot) + L"\\" + guid);
        out.push_back(std::move(ep));
    }
    return out;
}

// ---------------------------------------------------------------------------
// 音频服务重启（对齐 Python restart_audio：依赖倒序起停）
// ---------------------------------------------------------------------------

bool RestartAudio() {
    std::vector<std::wstring> deps;
    const ProcResult r = RunCmd({L"sc", L"enumdepend", L"Audiosrv"});
    const std::string out = r.stdOut;
    size_t pos = 0;
    while (pos < out.size()) {
        size_t eol = out.find('\n', pos);
        if (eol == std::string::npos) eol = out.size();
        std::string line = out.substr(pos, eol - pos);
        pos = eol + 1;
        const size_t b = line.find_first_not_of(" \t\r");
        if (b == std::string::npos) continue;
        line = line.substr(b);
        if (line.rfind("SERVICE_NAME:", 0) == 0) {
            std::string name = line.substr(strlen("SERVICE_NAME:"));
            const size_t nb = name.find_first_not_of(" \t");
            if (nb != std::string::npos) deps.push_back(Utf8ToWide(name.substr(nb)));
        }
    }
    for (const auto& svc : deps) RunCmd({L"sc", L"stop", svc}, 15);
    RunCmd({L"sc", L"stop", L"Audiosrv"}, 20);
    Sleep(1000);
    RunCmd({L"sc", L"stop", L"AudioEndpointBuilder"}, 20);
    Sleep(1000);
    ProcResult r1 = RunCmd({L"sc", L"start", L"AudioEndpointBuilder"}, 25);
    if (r1.exitCode != 0) {
        Sleep(2000);
        RunCmd({L"sc", L"start", L"AudioEndpointBuilder"}, 25);
    }
    Sleep(1000);
    ProcResult r2 = RunCmd({L"sc", L"start", L"Audiosrv"}, 25);
    if (r2.exitCode != 0) {
        Sleep(2000);
        r2 = RunCmd({L"sc", L"start", L"Audiosrv"}, 25);
    }
    Sleep(1000);
    for (const auto& svc : deps) RunCmd({L"sc", L"start", svc}, 15);
    return r2.exitCode == 0;
}

// ---------------------------------------------------------------------------
// 双层备份（对齐 Python backup_endpoint）
// ---------------------------------------------------------------------------

Json BackupEndpoint(const Endpoint& ep, const std::wstring& mode) {
    const std::wstring shortGuid = ShortGuid(Utf8ToWide(ep.id));
    const std::wstring fxSub = ep.FxSub();
    const std::wstring childSub = std::wstring(kChildApoRoot) + L"\\" + shortGuid;
    const std::wstring stamp = NowStamp();
    const std::wstring backupDir = BackupDir();
    MakeDirs(backupDir);

    const bool hadKey = RegKeyExists(HKEY_LOCAL_MACHINE, fxSub);
    std::vector<std::pair<std::wstring, RegValue>> snapshot;
    for (const auto& keyName : SlotKeys()) {
        if (!hadKey) {
            snapshot.emplace_back(keyName, RegSz(kSentinelNoKey));
            continue;
        }
        auto v = RegRead(HKEY_LOCAL_MACHINE, fxSub, keyName);
        if (v) {
            snapshot.emplace_back(keyName, std::move(*v));
        } else {
            snapshot.emplace_back(keyName, RegSz(kSentinelNoValue));
        }
    }

    // 1. 注册表 Child APOs 快照
    RegWrite(HKEY_LOCAL_MACHINE, childSub, L"Version", RegSz(L"1"));
    RegWrite(HKEY_LOCAL_MACHINE, childSub, L"EndpointId", RegSz(Utf8ToWide(ep.id)));
    RegWrite(HKEY_LOCAL_MACHINE, childSub, L"DeviceName", RegSz(ep.name));
    RegWrite(HKEY_LOCAL_MACHINE, childSub, L"Direction",
             RegSz(ep.DirectionTitle()));
    RegWrite(HKEY_LOCAL_MACHINE, childSub, L"InstallMode", RegSz(mode));
    RegWrite(HKEY_LOCAL_MACHINE, childSub, L"HadFxPropertiesKey",
             RegDword(hadKey ? 1 : 0));
    RegWrite(HKEY_LOCAL_MACHINE, childSub, L"BackupTimestamp", RegSz(stamp));
    for (const auto& [kn, v] : snapshot) {
        RegWrite(HKEY_LOCAL_MACHINE, childSub, kn, v);
    }

    // 2. 磁盘 .reg / .json 快照
    std::wstring safe;
    for (const wchar_t c : shortGuid) {
        safe += iswalnum(c) ? c : L'_';
        if (safe.size() >= 16) break;
    }
    const std::wstring regFile =
        backupDir + L"\\fx_" + safe + L"_" + stamp + L".reg";
    const std::wstring jsonFile =
        backupDir + L"\\fx_" + safe + L"_" + stamp + L".json";
    bool regExported = false;
    if (hadKey) {
        RunCmd({L"reg", L"export", L"HKLM\\" + fxSub, regFile, L"/y"});
        regExported = FileExists(regFile);
    }

    std::vector<std::pair<std::string, Json>> slotObj;
    for (const auto& [kn, v] : snapshot) {
        slotObj.emplace_back(WideToUtf8(kn), v.ToJson());
    }
    Json meta = Json::Obj({
        {"endpoint", Json::Str(ep.id)},
        {"short_guid", Json::Str(WideToUtf8(shortGuid))},
        {"direction", Json::Str(WideToUtf8(ep.DirectionTitle()))},
        {"had_key", Json::Bool(hadKey)},
        {"reg_file",
         regExported ? Json::Str(WideToUtf8(regFile)) : Json{}},
        {"backup_at", Json::Str(WideToUtf8(stamp))},
        {"install_mode", Json::Str(WideToUtf8(mode))},
        {"slots", Json::Obj(std::move(slotObj))},
    });
    // 与 Python json.dump(indent=2) 的可读落盘等价（缩进不影响解析）。
    WriteFileUtf8(jsonFile, JsonString(meta));
    return meta;
}

// ---------------------------------------------------------------------------
// 快照还原（对齐 Python restore_endpoint）
// ---------------------------------------------------------------------------

struct RestoreResult {
    bool ok;
    std::wstring message;
};

RestoreResult RestoreEndpoint(const std::wstring& shortId) {
    const std::wstring childSub = std::wstring(kChildApoRoot) + L"\\" + shortId;
    std::map<std::wstring, RegValue> stored;

    for (auto& [n, v] :
         RegEnumValues(HKEY_LOCAL_MACHINE, childSub)) {
        stored[n] = std::move(v);
    }

    // 注册表快照缺失 → 回退磁盘 JSON（文件名倒序，首个匹配）。
    if (stored.empty()) {
        const std::wstring dir = BackupDir();
        std::vector<std::wstring> files;
        WIN32_FIND_DATAW fd{};
        HANDLE h = FindFirstFileW((dir + L"\\fx_*.json").c_str(), &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                files.emplace_back(fd.cFileName);
            } while (FindNextFileW(h, &fd));
            FindClose(h);
        }
        std::sort(files.begin(), files.end(), std::greater<>());
        for (const auto& f : files) {
            std::string text;
            if (!ReadFileUtf8(dir + L"\\" + f, text)) continue;
            Json d;
            if (!JsonParse(text, d)) continue;
            const Json* sg = d.Find("short_guid");
            const Json* epId = d.Find("endpoint");
            const std::string sgUtf8 =
                (sg && sg->type == Json::Type::Str) ? sg->str : "";
            const std::string epUtf8 =
                (epId && epId->type == Json::Type::Str) ? epId->str : "";
            if (sgUtf8 == WideToUtf8(shortId) ||
                epUtf8.find(WideToUtf8(shortId)) != std::string::npos) {
                const Json* dirJ = d.Find("direction");
                stored[L"Direction"] = RegSz(
                    dirJ && dirJ->type == Json::Type::Str
                        ? Utf8ToWide(dirJ->str)
                        : L"Render");
                const Json* hk = d.Find("had_key");
                stored[L"HadFxPropertiesKey"] = RegDword(
                    hk && hk->type == Json::Type::Bool && hk->boolean ? 1 : 0);
                const Json* im = d.Find("install_mode");
                stored[L"InstallMode"] = RegSz(
                    im && im->type == Json::Type::Str ? Utf8ToWide(im->str)
                                                      : L"sfx-efx");
                if (const Json* slots = d.Find("slots");
                    slots && slots->type == Json::Type::Obj) {
                    for (const auto& [k, v] : slots->ObjMembers()) {
                        stored[Utf8ToWide(k)] = RegValue::FromJson(v);
                    }
                }
                break;
            }
        }
    }

    if (stored.empty()) {
        return {false, L"未找到端点 " + shortId + L" 的备份数据"};
    }

    auto storedSz = [&](const std::wstring& n, const std::wstring& dflt) {
        const auto it = stored.find(n);
        return (it != stored.end() && it->second.type == REG_SZ)
                   ? it->second.sz
                   : dflt;
    };
    const std::wstring direction = storedSz(L"Direction", L"Render");
    bool hadKey = true;
    if (const auto it = stored.find(L"HadFxPropertiesKey");
        it != stored.end() && it->second.type == REG_DWORD) {
        hadKey = it->second.dword == 1;
    }
    const std::wstring installMode = storedSz(L"InstallMode", L"sfx-efx");
    const std::wstring fxSub = std::wstring(kMmBase) + L"\\" + direction +
                               L"\\" + shortId + L"\\FxProperties";

    if (!hadKey) {
        RegDeleteKeyW(HKEY_LOCAL_MACHINE, fxSub.c_str());
    } else {
        HKEY k = nullptr;
        if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, fxSub.c_str(), 0, nullptr, 0,
                            KEY_SET_VALUE | KEY_QUERY_VALUE, nullptr, &k,
                            nullptr) != ERROR_SUCCESS) {
            return {false, L"写入 FxProperties 失败: 无法打开键"};
        }
        auto setValue = [&](const std::wstring& name, const RegValue& v) {
            switch (v.type) {
                case REG_SZ:
                case REG_EXPAND_SZ:
                    return RegSetValueExW(
                               k, name.c_str(), 0, v.type,
                               reinterpret_cast<const BYTE*>(v.sz.c_str()),
                               static_cast<DWORD>((v.sz.size() + 1) *
                                                  sizeof(wchar_t))) ==
                           ERROR_SUCCESS;
                case REG_MULTI_SZ: {
                    std::vector<wchar_t> buf;
                    for (const auto& s : v.multi) {
                        buf.insert(buf.end(), s.begin(), s.end());
                        buf.push_back(L'\0');
                    }
                    buf.push_back(L'\0');
                    return RegSetValueExW(
                               k, name.c_str(), 0, REG_MULTI_SZ,
                               reinterpret_cast<const BYTE*>(buf.data()),
                               static_cast<DWORD>(buf.size() *
                                                  sizeof(wchar_t))) ==
                           ERROR_SUCCESS;
                }
                case REG_DWORD:
                    return RegSetValueExW(
                               k, name.c_str(), 0, REG_DWORD,
                               reinterpret_cast<const BYTE*>(&v.dword),
                               sizeof(DWORD)) == ERROR_SUCCESS;
                default:
                    return RegSetValueExW(k, name.c_str(), 0, v.type,
                                          v.raw.data(),
                                          static_cast<DWORD>(v.raw.size())) ==
                           ERROR_SUCCESS;
            }
        };
        bool writeOk = true;
        if (installMode == L"composite") {
            for (const std::wstring slot :
                 {std::wstring(kFxBase) + L",13",
                  std::wstring(kFxBase) + L",14"}) {
                const auto it = stored.find(slot);
                if (it == stored.end() || it->second.IsSentinel()) {
                    RegDeleteValueW(k, slot.c_str());  // 失败忽略（Python 同）
                } else if (it->second.type == REG_MULTI_SZ) {
                    std::vector<std::wstring> clean;
                    for (const auto& x : it->second.multi) {
                        if (ToLowerW(x) != ToLowerW(std::wstring(kOurClsid)))
                            clean.push_back(x);
                    }
                    if (!clean.empty()) {
                        if (!setValue(slot, RegMulti(clean))) writeOk = false;
                    } else {
                        RegDeleteValueW(k, slot.c_str());
                    }
                }
            }
        } else {
            for (const auto& kn : SlotKeys()) {
                const auto it = stored.find(kn);
                if (it == stored.end()) continue;
                const RegValue& v = it->second;
                if (v.IsSentinel()) {
                    RegDeleteValueW(k, kn.c_str());  // 失败忽略（Python 同）
                } else if (!setValue(kn, v)) {
                    writeOk = false;
                }
            }
        }
        RegCloseKey(k);
        if (!writeOk) return {false, L"写入 FxProperties 失败"};
    }

    RegDeleteKeyW(HKEY_LOCAL_MACHINE, childSub.c_str());
    if (RegEnumSubkeys(HKEY_LOCAL_MACHINE, kChildApoRoot).empty()) {
        RegDeleteKeyW(HKEY_LOCAL_MACHINE, kChildApoRoot);
    }
    return {true, L"端点 " + shortId + L" 恢复完成"};
}

// ---------------------------------------------------------------------------
// 命令实现（对齐 Python cmd_* 与 main 的参数/退出码/JSON 形状）
// ---------------------------------------------------------------------------

void Out(const std::string& utf8) { fwrite(utf8.data(), 1, utf8.size(), stdout); }
void OutLine(const std::string& utf8) {
    Out(utf8);
    Out("\n");
}
void OutJson(const Json& j) { OutLine(JsonString(j)); }

int CmdStatus(bool asJson, const std::optional<double>& timeout) {
    const bool admin = IsAdmin();
    const auto testenv =
        RegRead(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal);
    const double hbTimeout =
        timeout.has_value() ? *timeout : (asJson ? 0.4 : 1.5);
    const Heartbeat hb = ReadHeartbeat(hbTimeout);
    const auto installed = GetInstalledChildApos();

    const bool comRegistered =
        RegRead(HKEY_CLASSES_ROOT,
                std::wstring(L"AudioEngine\\AudioProcessingObjects\\") +
                    kOurClsid,
                L"FriendlyName")
            .has_value() &&
        RegRead(HKEY_CLASSES_ROOT,
                std::wstring(L"CLSID\\") + kOurClsid + L"\\InprocServer32",
                L"")
            .has_value();

    if (asJson) {
        std::vector<Json> eps;
        for (const auto& ep : installed) {
            std::vector<std::pair<std::string, Json>> o;
            o.emplace_back("short_guid", Json::Str(WideToUtf8(ep.shortGuid)));
            for (const auto& [n, v] : ep.values) {
                o.emplace_back(WideToUtf8(n), v.ToJson());
            }
            eps.push_back(Json::Obj(std::move(o)));
        }
        OutJson(Json::Obj({
            {"admin", Json::Bool(admin)},
            {"testenv", testenv ? testenv->ToJson() : Json{}},
            {"heartbeat", HeartbeatJson(hb, true)},
            {"com_registered", Json::Bool(comRegistered)},
            {"installed_endpoints", Json::Arr(std::move(eps))},
        }));
        return 0;
    }

    OutLine("=== AuraDSP System APO 状态报告 ===");
    OutLine(std::string("管理员权限: ") + (admin ? "True" : "False"));
    OutLine("未签名驱动加载环境 (DisableProtectedAudioDG): " +
            (testenv ? WideToUtf8(testenv->type == REG_DWORD
                                      ? std::to_wstring(testenv->dword)
                                      : testenv->sz)
                     : std::string("(absent=enforced)")));
    OutLine(std::string("COM 组件注册: ") +
            (comRegistered ? "已就绪" : "未注册"));
    OutLine(std::string("实时音频心跳: ") +
            (hb.alive ? "活跃处理中" : "静默 (无音频流或未激活)"));
    if (hb.alive) {
        OutLine("  采样率=" + std::to_string(hb.sr) +
                "Hz, 序列号=" + std::to_string(hb.seq) +
                ", 累计帧数=" + std::to_string(hb.frames) +
                ", audiodg_PID=" + std::to_string(hb.pid));
    }
    OutLine("已挂载端点数: " + std::to_string(installed.size()));
    for (const auto& ep : installed) {
        OutLine("  - [" + WideToUtf8(ep.GetSz(L"Direction")) + "] " +
                WideToUtf8(ep.GetSz(L"DeviceName")) + " (" +
                WideToUtf8(ep.shortGuid) +
                ") 模式:" + WideToUtf8(ep.GetSz(L"InstallMode")));
    }
    return 0;
}

int CmdInstall(const std::wstring& substr, std::wstring mode, bool force,
               bool asJson) {
    if (!IsAdmin()) {
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("admin_required")},
            }));
        } else {
            OutLine("FATAL: 安装 System APO 需要管理员权限。请使用管理员身份运行或加 --elevate 参数。");
        }
        return 1;
    }

    const auto hits = FindEndpoints(substr);
    if (hits.empty()) {
        const std::string msg =
            "未找到匹配 '" + WideToUtf8(substr) + "' 的音频端点";
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("no_endpoint")},
                {"message", Json::Str(msg)},
            }));
        } else {
            OutLine("FATAL: " + msg);
        }
        return 1;
    }
    if (hits.size() > 1) {
        const std::string msg = "匹配到多个端点 (" +
                                 std::to_string(hits.size()) +
                                 "个)，请提供更精确的名称子串";
        if (asJson) {
            std::vector<Json> cands;
            for (const auto& h : hits) {
                cands.push_back(Json::Obj({
                    {"id", Json::Str(h.id)},
                    {"direction", Json::Str(h.direction)},
                    {"name", Json::Str(WideToUtf8(h.rawName))},
                    {"friendlyName", Json::Str(WideToUtf8(h.friendlyName))},
                }));
            }
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("ambiguous")},
                {"message", Json::Str(msg)},
                {"candidates", Json::Arr(std::move(cands))},
            }));
        } else {
            OutLine("FATAL: " + msg + ":");
            for (const auto& h : hits) {
                OutLine("  - " + WideToUtf8(h.name) + " (ID: " + h.id + ")");
            }
        }
        return 1;
    }

    const Endpoint& ep = hits[0];
    const std::wstring name = ep.name;
    const std::wstring lower = ToLowerW(name);
    const bool isVirtual = lower.find(L"voicemeeter") != std::wstring::npos ||
                           lower.find(L"virtual") != std::wstring::npos ||
                           lower.find(L"cable") != std::wstring::npos;
    if (!isVirtual && !force) {
        const std::string msg = "目标为物理声卡设备 '" + WideToUtf8(name) +
                                "'。为保护系统原生驱动，必须显式指定 --force 才能挂载";
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("physical_device_requires_force")},
                {"message", Json::Str(msg)},
            }));
        } else {
            OutLine("WARN: " + msg);
        }
        return 2;
    }

    const bool win7 = IsWin7OrEarlier();
    if (win7 && mode == L"sfx-efx") mode = L"win7-sapo";

    EnsureComRegistered();

    const auto testenv =
        RegRead(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal);
    if (!testenv || testenv->type != REG_DWORD || testenv->dword != 1) {
        RegWrite(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal, RegDword(1));
    }

    Json meta = BackupEndpoint(ep, mode);

    const std::wstring shortGuid = ShortGuid(Utf8ToWide(ep.id));
    const std::wstring fxSub = ep.FxSub();
    HKEY k = nullptr;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, fxSub.c_str(), 0, nullptr, 0,
                        KEY_SET_VALUE | KEY_QUERY_VALUE, nullptr, &k,
                        nullptr) == ERROR_SUCCESS) {
        auto setSz = [&](const std::wstring& n, const std::wstring& v) {
            RegSetValueExW(k, n.c_str(), 0, REG_SZ,
                           reinterpret_cast<const BYTE*>(v.c_str()),
                           static_cast<DWORD>((v.size() + 1) * sizeof(wchar_t)));
        };
        setSz(std::wstring(kFxBase) + L",0", kNullGuid);
        if (win7 || mode == L"win7-sapo") {
            setSz(std::wstring(kFxBase) + L",1", kOurClsid);
            setSz(std::wstring(kFxBase) + L",2", kOurClsid);
        } else if (mode == L"composite") {
            for (const std::wstring slot :
                 {std::wstring(kFxBase) + L",13",
                  std::wstring(kFxBase) + L",14"}) {
                std::vector<std::wstring> list;
                const auto existing =
                    RegRead(HKEY_LOCAL_MACHINE, fxSub, slot);
                if (existing && existing->type == REG_MULTI_SZ) {
                    list = existing->multi;
                }
                bool present = false;
                for (const auto& x : list) {
                    if (x == kOurClsid) present = true;
                }
                if (!present) list.emplace_back(kOurClsid);
                std::vector<wchar_t> buf;
                for (const auto& s : list) {
                    buf.insert(buf.end(), s.begin(), s.end());
                    buf.push_back(L'\0');
                }
                buf.push_back(L'\0');
                RegSetValueExW(k, slot.c_str(), 0, REG_MULTI_SZ,
                               reinterpret_cast<const BYTE*>(buf.data()),
                               static_cast<DWORD>(buf.size() * sizeof(wchar_t)));
            }
        } else if (mode == L"sfx-only") {
            setSz(std::wstring(kFxBase) + L",5", kOurClsid);
        } else {
            setSz(std::wstring(kFxBase) + L",5", kOurClsid);
            setSz(std::wstring(kFxBase) + L",6", kOurClsid);
            setSz(std::wstring(kFxBase) + L",7", kOurClsid);
        }
        if (!win7) {
            for (const wchar_t* slot : {L"5", L"6", L"7"}) {
                const std::wstring pmKey = std::wstring(kProcModes) + L"," + slot;
                const auto cur = RegRead(HKEY_LOCAL_MACHINE, fxSub, pmKey);
                bool needSet = !cur.has_value();
                if (cur && cur->type == REG_MULTI_SZ) {
                    needSet = std::find(cur->multi.begin(), cur->multi.end(),
                                        std::wstring(kDefaultMode)) ==
                              cur->multi.end();
                } else if (cur && cur->type == REG_SZ) {
                    needSet = cur->sz.find(kDefaultMode) == std::wstring::npos;
                } else if (cur) {
                    needSet = true;
                }
                if (needSet) {
                    const std::vector<std::wstring> modes = {kDefaultMode};
                    std::vector<wchar_t> buf;
                    for (const auto& s : modes) {
                        buf.insert(buf.end(), s.begin(), s.end());
                        buf.push_back(L'\0');
                    }
                    buf.push_back(L'\0');
                    RegSetValueExW(k, pmKey.c_str(), 0, REG_MULTI_SZ,
                                   reinterpret_cast<const BYTE*>(buf.data()),
                                   static_cast<DWORD>(buf.size() *
                                                      sizeof(wchar_t)));
                }
            }
        }
        RegDeleteValueW(k, (std::wstring(kDisableEnh) + L",5").c_str());
        RegCloseKey(k);
    }

    const bool restarted = RestartAudio();

    if (asJson) {
        OutJson(Json::Obj({
            {"ok", Json::Bool(true)},
            {"endpoint_id", Json::Str(ep.id)},
            {"short_guid", Json::Str(WideToUtf8(shortGuid))},
            {"name", Json::Str(WideToUtf8(name))},
            {"mode", Json::Str(WideToUtf8(mode))},
            {"backup", std::move(meta)},
            {"audio_restarted", Json::Bool(restarted)},
        }));
    } else {
        OutLine("成功将 AuraAPO 挂载到 '" + WideToUtf8(name) + "' (" +
                WideToUtf8(shortGuid) + ")");
        OutLine("挂载模式: " + WideToUtf8(mode) +
                ", 音频服务重启: " + (restarted ? "成功" : "重试中"));
    }
    return 0;
}

int CmdUninstall(const std::wstring& target, bool asJson) {
    if (!IsAdmin()) {
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("admin_required")},
            }));
        } else {
            OutLine("FATAL: 卸载 System APO 需要管理员权限。请使用管理员身份运行或加 --elevate 参数。");
        }
        return 1;
    }

    const auto installed = GetInstalledChildApos();
    if (installed.empty()) {
        const std::string msg = "未发现任何挂载了 AuraAPO 的端点";
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(true)},
                {"restored", Json::Arr({})},
                {"message", Json::Str(msg)},
            }));
        } else {
            OutLine(msg);
        }
        return 0;
    }

    std::vector<const InstalledEndpoint*> toRestore;
    const std::wstring tLower = ToLowerW(target);
    if (target.empty() || tLower == L"all" || tLower == L"*") {
        for (const auto& ep : installed) toRestore.push_back(&ep);
    } else {
        for (const auto& ep : installed) {
            if (ContainsCi(ep.shortGuid, target) ||
                ContainsCi(ep.GetSz(L"DeviceName"), target) ||
                ContainsCi(ep.GetSz(L"EndpointId"), target)) {
                toRestore.push_back(&ep);
            }
        }
    }
    if (toRestore.empty()) {
        const std::string msg =
            "未找到匹配 '" + WideToUtf8(target) + "' 的已安装端点";
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("not_found")},
                {"message", Json::Str(msg)},
            }));
        } else {
            OutLine("WARN: " + msg);
        }
        return 1;
    }

    std::vector<Json> restored;
    std::vector<std::pair<std::wstring, RestoreResult>> restoredText;
    for (const auto* ep : toRestore) {
        RestoreResult r = RestoreEndpoint(ep->shortGuid);
        restored.push_back(Json::Obj({
            {"short_guid", Json::Str(WideToUtf8(ep->shortGuid))},
            {"ok", Json::Bool(r.ok)},
            {"message", Json::Str(WideToUtf8(r.message))},
        }));
        restoredText.emplace_back(ep->shortGuid, r);
    }

    // 全部卸载后清理全局未签名开关（testenv.json 从未由脚本写入时
    // prev 恒为空 → 删除该值，与 Python 版行为一致）。
    const auto remaining = GetInstalledChildApos();
    if (remaining.empty()) {
        std::optional<DWORD> prev;
        std::string text;
        if (ReadFileUtf8(BackupDir() + L"\\testenv.json", text)) {
            Json d;
            if (JsonParse(text, d)) {
                if (const Json* v = d.Find("DisableProtectedAudioDG");
                    v && v->type == Json::Type::Num) {
                    prev = static_cast<DWORD>(v->num);
                }
            }
        }
        if (!prev) {
            HKEY k = nullptr;
            if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kTestEnvKey, 0,
                              KEY_SET_VALUE, &k) == ERROR_SUCCESS) {
                RegDeleteValueW(k, kTestEnvVal);
                RegCloseKey(k);
            }
        } else {
            RegWrite(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal,
                     RegDword(*prev));
        }
    }

    const bool restarted = RestartAudio();

    if (asJson) {
        OutJson(Json::Obj({
            {"ok", Json::Bool(true)},
            {"restored", Json::Arr(std::move(restored))},
            {"audio_restarted", Json::Bool(restarted)},
            {"remaining_count",
             Json::Num(static_cast<double>(remaining.size()))},
        }));
    } else {
        for (const auto& [guid, r] : restoredText) {
            OutLine("还原结果: " + WideToUtf8(guid) + " -> " +
                    WideToUtf8(r.message));
        }
        OutLine(std::string("音频服务重启: ") + (restarted ? "成功" : "失败"));
    }
    return 0;
}

// --elevate 自提权（对齐 Python run_elevated：RunAs 重拉自身并透传退出码）。
int RelaunchElevated(const std::vector<std::wstring>& args) {
    wchar_t exe[MAX_PATH * 4];
    GetModuleFileNameW(nullptr, exe, MAX_PATH * 4);
    std::wstring params;
    for (const auto& a : args) {
        if (a == L"--elevate") continue;
        if (!params.empty()) params += L' ';
        params += QuoteArg(a);
    }
    SHELLEXECUTEINFOW sei{};
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = exe;
    sei.lpParameters = params.c_str();
    sei.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&sei)) return 1;
    DWORD code = 1;
    if (sei.hProcess) {
        WaitForSingleObject(sei.hProcess, INFINITE);
        GetExitCodeProcess(sei.hProcess, &code);
        CloseHandle(sei.hProcess);
    }
    return static_cast<int>(code);
}

void PrintHelp() {
    OutLine("apo_config — AuraAPO 端点安装/注册表原子保护/卸载/服务重启与心跳握手（原生版）");
    OutLine("用法:");
    OutLine("  apo_config status [--timeout <秒>] [--json]");
    OutLine("  apo_config verify-heartbeat [--timeout <秒>] [--json]");
    OutLine("  apo_config install <端点名子串> --yes [--force] [--mode sfx-efx|composite|sfx-only|win7-sapo] [--json] [--elevate]");
    OutLine("  apo_config uninstall [目标] --yes [--json] [--elevate]");
    OutLine("  apo_config testenv-on | testenv-off [--json] [--elevate]");
}

}  // namespace

int wmain(int argc, wchar_t* argv[]) {
    _setmode(_fileno(stdout), _O_BINARY);
    std::vector<std::wstring> args;
    for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);

    bool hasElevate = false;
    bool asJson = false;
    for (const auto& a : args) {
        if (a == L"--elevate") hasElevate = true;
        if (a == L"--json") asJson = true;
    }
    if (hasElevate && !IsAdmin()) {
        return RelaunchElevated(args);
    }

    if (args.empty()) {
        if (asJson) {
            OutJson(Json::Obj({{"error", Json::Str("help_requested")}}));
        } else {
            PrintHelp();
        }
        return 0;
    }
    const std::wstring verb = ToLowerW(args[0]);
    if (verb == L"-h" || verb == L"--help" || verb == L"help") {
        if (asJson) {
            OutJson(Json::Obj({{"error", Json::Str("help_requested")}}));
        } else {
            PrintHelp();
        }
        return 0;
    }

    auto optValue = [&](const std::wstring& flag) -> std::optional<std::wstring> {
        for (size_t i = 0; i + 1 < args.size(); ++i) {
            if (args[i] == flag) return args[i + 1];
        }
        return std::nullopt;
    };
    auto hasFlag = [&](const std::wstring& flag) {
        return std::find(args.begin(), args.end(), flag) != args.end();
    };

    if (verb == L"status") {
        std::optional<double> timeout;
        if (const auto v = optValue(L"--timeout")) {
            try {
                timeout = std::stod(*v);
            } catch (...) {
            }
        }
        return CmdStatus(asJson, timeout);
    }
    if (verb == L"verify-heartbeat") {
        double timeout = 5;
        if (const auto v = optValue(L"--timeout")) {
            try {
                timeout = std::stod(*v);
            } catch (...) {
            }
        }
        const Heartbeat hb = ReadHeartbeat(timeout);
        if (asJson) {
            OutJson(HeartbeatJson(hb, false));
        } else {
            OutLine("心跳检测结果: alive=" +
                    std::string(hb.alive ? "true" : "false") +
                    " seq=" + std::to_string(hb.seq) +
                    " frames=" + std::to_string(hb.frames));
        }
        return 0;
    }
    if (verb == L"testenv-on" || verb == L"testenv-off") {
        if (!IsAdmin()) {
            OutLine("FATAL: 需要管理员权限");
            return 1;
        }
        const bool on = verb == L"testenv-on";
        if (on) {
            RegWrite(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal, RegDword(1));
        } else {
            HKEY k = nullptr;
            if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kTestEnvKey, 0,
                              KEY_SET_VALUE, &k) == ERROR_SUCCESS) {
                RegDeleteValueW(k, kTestEnvVal);
                RegCloseKey(k);
            }
        }
        RestartAudio();
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(true)},
                {"DisableProtectedAudioDG", Json::Num(on ? 1 : 0)},
            }));
        } else {
            OutLine(on ? "已启用未签名驱动加载环境 (DisableProtectedAudioDG=1)"
                       : "已恢复签名驱动保护策略");
        }
        return 0;
    }
    if (verb == L"install") {
        if (args.size() < 2 || args[1].rfind(L"--", 0) == 0) {
            OutLine("用法: apo_config install <端点名子串> [--mode sfx-efx|composite|sfx-only] [--yes] [--force] [--json]");
            return 2;
        }
        if (!hasFlag(L"--yes")) {
            OutLine("FATAL: 修改底层驱动配置需提供 --yes 确认参数");
            return 1;
        }
        std::wstring mode = L"sfx-efx";
        if (const auto v = optValue(L"--mode")) {
            mode = *v;
        } else if (hasFlag(L"--composite")) {
            mode = L"composite";
        }
        return CmdInstall(args[1], mode, hasFlag(L"--force"), asJson);
    }
    if (verb == L"uninstall") {
        if (!hasFlag(L"--yes")) {
            OutLine("FATAL: 卸载底层驱动配置需提供 --yes 确认参数");
            return 1;
        }
        std::wstring target;
        if (args.size() > 1 && args[1].rfind(L"--", 0) != 0) target = args[1];
        return CmdUninstall(target, asJson);
    }

    OutLine("未知子命令: " + WideToUtf8(args[0]));
    return 2;
}
