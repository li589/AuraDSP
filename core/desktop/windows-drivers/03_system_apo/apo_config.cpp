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

#include <aclapi.h>

#include "apo_install_plan.h"

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

// OS 内部版本号（注册表真值，避 GetVersionEx 的清单谎报）：
// Win7=7601 / Win8=9200 / Win8.1=9600 / Win10>=10240 / Win11>=22000。
int OsBuildNumber() {
    const auto v = RegRead(HKEY_LOCAL_MACHINE,
                           L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",
                           L"CurrentBuildNumber");
    if (v && v->type == REG_SZ) {
        try {
            return std::stoi(v->sz);
        } catch (...) {
            return 0;
        }
    }
    return 0;
}

struct ProcResult {
    int exitCode = -1;
    std::string stdOut;  // UTF-8（子进程输出按本地代码页解码后转码）
};

std::wstring QuoteArg(const std::wstring& a) {
    // 标准 Windows 命令行引用（细审 R-C L-4）：旧实现只给
    // 引号加反斜杠，参数尾随反斜杠会把闭合引号转义掉、反
    // 斜杠序列也不翻倍。规则：引号前的反斜杠串翻倍再加一
    // 条转义引号；结尾反斜杠串翻倍；空参数输出 ""（旧
    // 实现会让空参数在拼接后消失）。
    if (!a.empty() && a.find_first_of(L" \t\"") == std::wstring::npos)
        return a;
    std::wstring q = L"\"";
    size_t backslashes = 0;
    for (const wchar_t c : a) {
        if (c == L'\\') {
            backslashes++;
            continue;
        }
        if (c == L'"') {
            q.append(backslashes * 2 + 1, L'\\');
            q += L'"';
        } else {
            q.append(backslashes, L'\\');
            q += c;
        }
        backslashes = 0;
    }
    q.append(backslashes * 2, L'\\');
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
                        hb.sr = snap.sampleRate;
                        hb.nbs = snap.lastNbs;
                        hb.pid = snap.pid;
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
    if (hb.seen) {
        // 见过但未推进（细审 R-C L-3）：alive 按口径为真，
        // 但 seq/frames 此前恒 0、误导排障（APO 已加载但无
        // 音频流时正属此态）——回填首快照实测值。
        hb.alive = true;
        hb.seq = hb.firstSeq;
        hb.frames = hb.firstFrames;
    }
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

// 注册路径真值：InprocServer32 默认值指向的 DLL 路径。
std::optional<std::wstring> RegisteredDllPath() {
    auto v = RegRead(HKEY_CLASSES_ROOT,
                     std::wstring(L"CLSID\\") + kOurClsid +
                         L"\\InprocServer32",
                     L"");
    if (!v || v->type != REG_SZ || v->sz.empty()) return std::nullopt;
    return v->sz;
}

// 路径规范化比较（去包裹引号 + 绝对化 + 大小写不敏感）。
bool SameDllPath(const std::wstring& a, const std::wstring& b) {
    auto norm = [](std::wstring p) {
        if (p.size() >= 2 && p.front() == L'"' && p.back() == L'"')
            p = p.substr(1, p.size() - 2);
        wchar_t buf[MAX_PATH];
        const DWORD n = GetFullPathNameW(p.c_str(), MAX_PATH, buf, nullptr);
        if (n > 0 && n < MAX_PATH) p.assign(buf, n);
        return ToLowerW(p);
    };
    return norm(a) == norm(b);
}

// COM 注册「现行」判定：注册项齐全，且 InprocServer32 指向随包
// DLL。只查存在性会让旧版残留注册永久蒙混——vm-win10 第八轮
// 项 2 实证定罪（2026-11-11）：注册指向 System32 里的 v1 透传
// 副本（178,688 B），audiodg 按注册路径加载旧 DLL，引擎宿主
// 永不启动、telemetry 块永不出现，面板却恒显「已就绪」。
bool ComRegistrationCurrent() {
    auto hasApo = RegRead(HKEY_CLASSES_ROOT,
                          std::wstring(L"AudioEngine\\"
                                       L"AudioProcessingObjects\\") +
                              kOurClsid,
                          L"FriendlyName");
    auto reg = RegisteredDllPath();
    if (!hasApo || !reg) return false;
    const std::wstring dll = FindDll();
    return FileExists(dll) && SameDllPath(*reg, dll);
}

// COM 注册就绪检查：未注册或注册指向旧路径时，用随包 DLL 重新
// 注册并复核（自愈旧版残留注册）。
bool EnsureComRegistered() {
    if (ComRegistrationCurrent()) return true;
    const std::wstring dll = FindDll();
    if (FileExists(dll)) {
        RunCmd({L"regsvr32", L"/s", dll});
        return ComRegistrationCurrent();
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

    // 1. 注册表 Child APOs 快照。两条纪律（细审 R-C H-1/L-5）：
    // 其一，已有快照时保留首份——重复 install 无条件覆写会把
    // 已被改写的当前值当「原始值」存入，卸载还原的将是
    // AuraDSP 自己的值、厂商原始 APO 值永久丢失；首份快照
    // 才是原始基线。其二，写入成败必查并经 meta 的
    // backup_failed 回传，CmdInstall 据此中止——变更已发生
    // 却无备份，比不变更更危险。
    const bool snapExists = RegKeyExists(HKEY_LOCAL_MACHINE, childSub);
    bool snapOk = true;
    if (!snapExists) {
        snapOk &= RegWrite(HKEY_LOCAL_MACHINE, childSub, L"Version", RegSz(L"2"));
        snapOk &= RegWrite(HKEY_LOCAL_MACHINE, childSub, L"EndpointId",
                           RegSz(Utf8ToWide(ep.id)));
        snapOk &= RegWrite(HKEY_LOCAL_MACHINE, childSub, L"DeviceName",
                           RegSz(ep.name));
        snapOk &= RegWrite(HKEY_LOCAL_MACHINE, childSub, L"Direction",
                           RegSz(ep.DirectionTitle()));
        snapOk &= RegWrite(HKEY_LOCAL_MACHINE, childSub, L"InstallMode",
                           RegSz(mode));
        snapOk &= RegWrite(HKEY_LOCAL_MACHINE, childSub,
                           L"HadFxPropertiesKey", RegDword(hadKey ? 1 : 0));
        snapOk &= RegWrite(HKEY_LOCAL_MACHINE, childSub, L"BackupTimestamp",
                           RegSz(stamp));
        for (const auto& [kn, v] : snapshot) {
            snapOk &= RegWrite(HKEY_LOCAL_MACHINE, childSub, kn, v);
        }
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
        {"schema", Json::Num(2)},
        {"backup_preserved", Json::Bool(snapExists)},
        {"slots", Json::Obj(std::move(slotObj))},
    });
    // 与 Python json.dump(indent=2) 的可读落盘等价（缩进不影响解析）。
    const bool jsonOk = WriteFileUtf8(jsonFile, JsonString(meta));
    if (!snapOk || !jsonOk || (hadKey && !regExported)) {
        return Json::Obj({{"backup_failed", Json::Bool(true)}});
    }
    return meta;
}

// ---------------------------------------------------------------------------
// 快照还原（对齐 Python restore_endpoint）
// ---------------------------------------------------------------------------

// 按 RegValue 原类型写回单个值（RestoreEndpoint 与 CmdInstall 的
// 跨模式清理共用；语义与旧 RestoreEndpoint 内部 lambda 逐项一致）。
bool SetRegValueRaw(HKEY k, const std::wstring& name, const RegValue& v) {
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
            for (const auto& str : v.multi) {
                buf.insert(buf.end(), str.begin(), str.end());
                buf.push_back(L'\0');
            }
            buf.push_back(L'\0');
            return RegSetValueExW(
                       k, name.c_str(), 0, REG_MULTI_SZ,
                       reinterpret_cast<const BYTE*>(buf.data()),
                       static_cast<DWORD>(buf.size() * sizeof(wchar_t))) ==
                   ERROR_SUCCESS;
        }
        case REG_DWORD:
            return RegSetValueExW(k, name.c_str(), 0, REG_DWORD,
                                  reinterpret_cast<const BYTE*>(&v.dword),
                                  sizeof(DWORD)) == ERROR_SUCCESS;
        default:
            return RegSetValueExW(k, name.c_str(), 0, v.type, v.raw.data(),
                                  static_cast<DWORD>(v.raw.size())) ==
                   ERROR_SUCCESS;
    }
}

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

    // 快照版本先验（W2 书签版本化）：高于本工具支持的版本拒绝
    // 还原，防旧工具按旧语义毁新状态（EAPO 同口径）。
    int snapSchema = 1;
    if (!stored.empty()) {
        const auto it = stored.find(L"Version");
        if (it != stored.end() && it->second.type == REG_SZ) {
            snapSchema = apoplan::SnapshotVersionOf(it->second.sz);
        }
    }

    // 注册表快照缺失 → 回退磁盘 JSON（文件名正序，首个匹配：
    // 最早一份才是未被后续重复 install 污染的原始基线，细审 R-C H-1）。
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
        std::sort(files.begin(), files.end(), std::less<>());
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
                const Json* sc = d.Find("schema");
                const int fileSchema =
                    (sc && sc->type == Json::Type::Num)
                        ? static_cast<int>(sc->num)
                        : 1;
                if (fileSchema > 2) {
                    // 过新文件不采信，继续找更旧的兼容文件；若无，
                    // snapSchema 保留过新值，由下方守卫报错。
                    snapSchema = fileSchema;
                    continue;
                }
                snapSchema = fileSchema;
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

    if (snapSchema > 2) {
        return {false, L"备份数据版本 " + std::to_wstring(snapSchema) +
                            L" 高于本工具支持的 2，已中止还原（请使用新版 apo_config）"};
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
            return SetRegValueRaw(k, name, v);
        };
        bool writeOk = true;
        auto restoreSlot = [&](const std::wstring& kn) {
            const auto it = stored.find(kn);
            if (it == stored.end()) return;
            const RegValue& v = it->second;
            if (v.IsSentinel()) {
                RegDeleteValueW(k, kn.c_str());  // 失败忽略（Python 同）
            } else if (!setValue(kn, v)) {
                writeOk = false;
            }
        };
        if (installMode == L"composite") {
            const std::wstring slot13 = std::wstring(kFxBase) + L",13";
            const std::wstring slot14 = std::wstring(kFxBase) + L",14";
            for (const std::wstring slot : {slot13, slot14}) {
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
            // 复合模式下 install 同样改写了 ,0/ProcModes/
            // DisableEnh（全模式共用写段），还原必须一并回滚
            // （细审 R-C H-2）：旧实现只回 ,13/,14，其余槽在
            // 「卸载完成」后仍处修改态。
            for (const auto& kn : SlotKeys()) {
                if (kn == slot13 || kn == slot14) continue;
                restoreSlot(kn);
            }
        } else {
            for (const auto& kn : SlotKeys()) restoreSlot(kn);
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

// --result-file 目标（wmain 填充）：提权子进程的 stdout
// 跨不过 UAC 边界（Start-Process 无法重定向提权进程的
// 输出），结果 JSON 另写一份到此文件，供 App 读取工具
// 自报的真实成败与原因，而不是猜测失败层。
std::wstring g_resultFile;

void Out(const std::string& utf8) { fwrite(utf8.data(), 1, utf8.size(), stdout); }
void OutLine(const std::string& utf8) {
    Out(utf8);
    Out("\n");
}
void OutJson(const Json& j) {
    const std::string text = JsonString(j);
    OutLine(text);
    if (!g_resultFile.empty()) {
        if (HANDLE h = CreateFileW(g_resultFile.c_str(), GENERIC_WRITE, 0,
                                   nullptr, CREATE_ALWAYS,
                                   FILE_ATTRIBUTE_NORMAL, nullptr);
            h != INVALID_HANDLE_VALUE) {
            DWORD written = 0;
            WriteFile(h, text.data(), static_cast<DWORD>(text.size()),
                      &written, nullptr);
            CloseHandle(h);
        }
    }
}

int CmdStatus(bool asJson, const std::optional<double>& timeout) {
    const bool admin = IsAdmin();
    const auto testenv =
        RegRead(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal);
    const double hbTimeout =
        timeout.has_value() ? *timeout : (asJson ? 0.4 : 1.5);
    const Heartbeat hb = ReadHeartbeat(hbTimeout);
    const auto installed = GetInstalledChildApos();

    // 实时端点推断（W2）：不依赖书签，直接读各端点 FxProperties
    // 现值反推挂载形态、原厂跨代归属与推荐档（纯逻辑在
    // apo_install_plan.h）。书签可能缺失/过期，现值才是真相。
    struct LiveEp {
        Endpoint ep;
        apoplan::InferredState inf;
        std::wstring rec;
        bool bookkept = false;
    };
    std::vector<LiveEp> live;
    {
        const bool win81Plus = OsBuildNumber() >= 9600;
        std::vector<std::wstring> keptGuids;
        for (const auto& b : installed) keptGuids.push_back(b.shortGuid);
        for (const auto& ep : FindEndpoints(L"")) {
            auto rd = [&](const wchar_t* suffix) {
                return RegRead(HKEY_LOCAL_MACHINE, ep.FxSub(),
                               std::wstring(kFxBase) + suffix);
            };
            auto szOf = [&](const wchar_t* suffix) {
                const auto v = rd(suffix);
                return (v && v->type == REG_SZ) ? v->sz : std::wstring();
            };
            auto multiOf = [&](const wchar_t* suffix) {
                const auto v = rd(suffix);
                if (v && v->type == REG_MULTI_SZ) return v->multi;
                if (v && v->type == REG_SZ && !v->sz.empty())
                    return std::vector<std::wstring>{v->sz};
                return std::vector<std::wstring>{};
            };
            apoplan::SlotOccupancy occ;
            occ.lfx = szOf(L",1");
            occ.gfx = szOf(L",2");
            occ.sfx = szOf(L",5");
            occ.mfx = szOf(L",6");
            occ.efx = szOf(L",7");
            occ.compSfx = multiOf(L",13");
            occ.compMfx = multiOf(L",14");
            occ.compEfx = multiOf(L",15");
            LiveEp le;
            le.ep = ep;
            le.inf = apoplan::InferInstallState(occ, kOurClsid);
            le.rec = apoplan::RecommendMode(occ, win81Plus, kOurClsid);
            const std::wstring sg = ShortGuid(Utf8ToWide(ep.id));
            le.bookkept = std::find(keptGuids.begin(), keptGuids.end(),
                                    sg) != keptGuids.end();
            live.push_back(std::move(le));
        }
    }

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
    // 注册路径现行性（第八轮项 2）：键在不等于指向对——旧版残留
    // 注册指向 System32 旧副本时 com_registered 恒真却永不处理。
    // JSON 的 com_registered 收紧为「键齐 + 路径现行」，另附
    // com_registered_path / com_path_current 供判读。
    const auto registeredPath = RegisteredDllPath();
    const bool comPathCurrent =
        comRegistered && registeredPath.has_value() &&
        FileExists(FindDll()) && SameDllPath(*registeredPath, FindDll());

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
            {"com_registered", Json::Bool(comRegistered && comPathCurrent)},
            {"com_registered_path",
             registeredPath ? Json::Str(WideToUtf8(*registeredPath))
                            : Json{}},
            {"com_path_current", Json::Bool(comPathCurrent)},
            {"installed_endpoints", Json::Arr(std::move(eps))},
            {"endpoints", Json::Arr([&] {
                 std::vector<Json> arr;
                 for (const auto& le : live) {
                     arr.push_back(Json::Obj({
                         {"id", Json::Str(le.ep.id)},
                         {"name", Json::Str(WideToUtf8(le.ep.name))},
                         {"direction", Json::Str(le.ep.direction)},
                         {"bookkept", Json::Bool(le.bookkept)},
                         {"inferred_mode",
                          le.inf.mode.empty()
                              ? Json{}
                              : Json::Str(WideToUtf8(le.inf.mode))},
                         {"ours_pre", Json::Bool(le.inf.oursPre)},
                         {"ours_post", Json::Bool(le.inf.oursPost)},
                         {"original_pre",
                          le.inf.originalPre.empty()
                              ? Json{}
                              : Json::Str(WideToUtf8(le.inf.originalPre))},
                         {"original_post",
                          le.inf.originalPost.empty()
                              ? Json{}
                              : Json::Str(WideToUtf8(le.inf.originalPost))},
                         {"recommended_mode",
                          Json::Str(WideToUtf8(le.rec))},
                     }));
                 }
                 return arr;
             }())},
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
            (comRegistered
                 ? (comPathCurrent
                        ? "已就绪"
                        : "已注册但指向旧路径（附加/修复时自动改注册）")
                 : "未注册"));
    if (registeredPath)
        OutLine("  注册路径: " + WideToUtf8(*registeredPath));
    OutLine(std::string("实时音频心跳: ") +
            // 全面复审 S6（APO-9)：心跳存活只证明 APO 实例在跑、
            // 不证明引擎在处理（第五轮面板同口径教训）——文案对齐
            // 「心跳活跃」，不冒称处理中；处理真值看引擎 telemetry。
            (hb.alive ? "心跳活跃" : "静默 (无音频流或未激活)"));
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
    OutLine("实时端点推断（按注册表现值）:");
    for (const auto& le : live) {
        std::string line =
            "  - " + WideToUtf8(le.ep.name) + " 推断:" +
            (le.inf.mode.empty() ? std::string("未挂载")
                                 : WideToUtf8(le.inf.mode)) +
            " 推荐:" + WideToUtf8(le.rec);
        if (!le.inf.originalPre.empty())
            line += " 原厂流侧:" + WideToUtf8(le.inf.originalPre);
        if (!le.inf.originalPost.empty())
            line += " 原厂设备侧:" + WideToUtf8(le.inf.originalPost);
        OutLine(line);
    }
    return 0;
}


// ---------------------------------------------------------------------------
// doctor（计划书 Part II W3）：APO 环境自检/自修。默认只读六项
// 检查；--fix 逐项修复（需管理员），修复与裁定走既有 JSON/
// result-file 通道。借 EqualizerAPO 的 checkXxx(fix) 与权限自修。
// ---------------------------------------------------------------------------

bool FxKeyWritable(const std::wstring& fxSub) {
    HKEY k = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, fxSub.c_str(), 0, KEY_SET_VALUE,
                      &k) != ERROR_SUCCESS) {
        return false;
    }
    RegCloseKey(k);
    return true;
}

bool EnableTokenPrivilege(const wchar_t* name) {
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(),
                          TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok)) {
        return false;
    }
    TOKEN_PRIVILEGES tp{};
    tp.PrivilegeCount = 1;
    bool ok = false;
    if (LookupPrivilegeValueW(nullptr, name, &tp.Privileges[0].Luid)) {
        tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
        ok = AdjustTokenPrivileges(tok, FALSE, &tp, sizeof(tp), nullptr,
                                   nullptr) &&
             GetLastError() == ERROR_SUCCESS;
    }
    CloseHandle(tok);
    return ok;
}

// FxProperties 不可写时的退路：接管所有权为 Administrators，再授
// 予 Administrators/SYSTEM 完全控制。仅 doctor --fix 在探针失败
// 时调用；任何一步失败即返回 false（doctor 如实报告未修复）。
bool TakeOwnershipRepair(const std::wstring& fxSub) {
    // SE_TAKE_OWNERSHIP_NAME 在 winnt.h 里是窄字符串常量，
    // 与本函数的宽字符串形参不合，直接用字面量。
    if (!EnableTokenPrivilege(L"SeTakeOwnershipPrivilege")) return false;
    SID_IDENTIFIER_AUTHORITY ntAuth = SECURITY_NT_AUTHORITY;
    PSID admins = nullptr;
    PSID systemSid = nullptr;
    if (!AllocateAndInitializeSid(&ntAuth, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                  DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0,
                                  0, &admins)) {
        return false;
    }
    AllocateAndInitializeSid(&ntAuth, 1, SECURITY_LOCAL_SYSTEM_RID, 0, 0,
                             0, 0, 0, 0, 0, &systemSid);
    bool ok = false;
    HKEY k = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, fxSub.c_str(), 0, WRITE_OWNER,
                      &k) == ERROR_SUCCESS) {
        SECURITY_DESCRIPTOR sd{};
        if (InitializeSecurityDescriptor(&sd,
                                         SECURITY_DESCRIPTOR_REVISION) &&
            SetSecurityDescriptorOwner(&sd, admins, FALSE)) {
            ok = RegSetKeySecurity(k, OWNER_SECURITY_INFORMATION, &sd) ==
                 ERROR_SUCCESS;
        }
        RegCloseKey(k);
    }
    if (ok && systemSid) {
        ok = false;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, fxSub.c_str(), 0, WRITE_DAC,
                          &k) == ERROR_SUCCESS) {
            EXPLICIT_ACCESSW ea[2]{};
            for (int i = 0; i < 2; ++i) {
                ea[i].grfAccessPermissions = KEY_ALL_ACCESS;
                ea[i].grfAccessMode = SET_ACCESS;
                ea[i].grfInheritance =
                    SUB_CONTAINERS_AND_OBJECTS_INHERIT;
                ea[i].Trustee.TrusteeForm = TRUSTEE_IS_SID;
                ea[i].Trustee.TrusteeType = TRUSTEE_IS_GROUP;
            }
            ea[0].Trustee.ptstrName = reinterpret_cast<LPWSTR>(admins);
            ea[1].Trustee.ptstrName =
                reinterpret_cast<LPWSTR>(systemSid);
            PACL dacl = nullptr;
            if (SetEntriesInAclW(2, ea, nullptr, &dacl) ==
                ERROR_SUCCESS) {
                SECURITY_DESCRIPTOR sd{};
                if (InitializeSecurityDescriptor(
                        &sd, SECURITY_DESCRIPTOR_REVISION) &&
                    SetSecurityDescriptorDacl(&sd, TRUE, dacl, FALSE)) {
                    ok = RegSetKeySecurity(k, DACL_SECURITY_INFORMATION,
                                           &sd) == ERROR_SUCCESS;
                }
                LocalFree(dacl);
            }
            RegCloseKey(k);
        }
    }
    FreeSid(admins);
    if (systemSid) FreeSid(systemSid);
    return ok;
}

struct DoctorCheck {
    std::string name;
    bool ok = false;
    std::string detail;
    bool fixed = false;  // 本次 --fix 已修复
};

int CmdDoctor(bool fix, bool asJson) {
    if (fix && !IsAdmin()) {
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("admin_required")},
                {"message", Json::Str("doctor --fix 需要管理员权限")},
            }));
        } else {
            OutLine("FATAL: doctor --fix 需要管理员权限。请使用管理员身份运行或加 --elevate 参数。");
        }
        return 1;
    }
    std::vector<DoctorCheck> checks;
    const auto installed = GetInstalledChildApos();

    // 1. testenv（DisableProtectedAudioDG）
    {
        DoctorCheck c;
        c.name = "testenv";
        auto good = [](const std::optional<RegValue>& v) {
            return v && v->type == REG_DWORD && v->dword == 1;
        };
        c.ok = good(RegRead(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal));
        c.detail = c.ok ? "DisableProtectedAudioDG=1"
                        : "DisableProtectedAudioDG 未启用（测试签名 APO 链装不上）";
        if (!c.ok && fix) {
            RegWrite(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal,
                     RegDword(1));
            if (good(RegRead(HKEY_LOCAL_MACHINE, kTestEnvKey,
                             kTestEnvVal))) {
                c.ok = true;
                c.fixed = true;
            }
        }
        checks.push_back(c);
    }
    // 2. COM 注册（注册项齐全 + 注册路径指向随包 DLL；只验「路径
    // DLL 存在」会被旧版残留注册蒙混——第八轮项 2 定罪，见
    // ComRegistrationCurrent 注）。
    {
        DoctorCheck c;
        c.name = "com_registration";
        auto probe = [&] { return ComRegistrationCurrent(); };
        c.ok = probe();
        c.detail = c.ok ? "APO 注册项齐全且指向随包 DLL"
                        : "APO 未注册或注册指向旧路径/DLL 缺失";
        if (!c.ok && fix) {
            const std::wstring dll = FindDll();
            if (FileExists(dll)) RunCmd({L"regsvr32", L"/s", dll});
            EnsureComRegistered();
            if (probe()) {
                c.ok = true;
                c.fixed = true;
            }
        }
        checks.push_back(c);
    }
    // 3. AuraApo.dll 在位
    {
        DoctorCheck c;
        c.name = "apo_dll";
        const std::wstring dll = FindDll();
        c.ok = FileExists(dll);
        c.detail = c.ok ? WideToUtf8(dll)
                        : "AuraApo.dll 不在工具同级候选路径";
        checks.push_back(c);
    }
    // 4. 引擎 DLL 在位（APO 目录锚定：apo 变体优先、普通版可达）
    {
        DoctorCheck c;
        c.name = "engine_dll";
        const std::wstring dir = ModuleDir();
        const std::wstring apoDll = dir + L"\\auradsp_engine_apo.dll";
        const std::wstring plainDll = dir + L"\\auradsp_engine.dll";
        if (FileExists(apoDll)) {
            c.ok = true;
            c.detail = WideToUtf8(apoDll);
        } else if (FileExists(plainDll)) {
            c.ok = true;
            c.detail = WideToUtf8(plainDll) + "（普通版）";
        } else {
            c.detail = "auradsp_engine_apo.dll / auradsp_engine.dll 均缺失";
        }
        checks.push_back(c);
    }
    // 5. 已挂载端点 FxProperties 可写探针
    {
        DoctorCheck c;
        c.name = "fx_writable";
        std::vector<std::pair<std::wstring, std::wstring>> bad;
        for (const auto& ep : installed) {
            const std::wstring fxSub =
                std::wstring(kMmBase) + L"\\" +
                ep.GetSz(L"Direction") + L"\\" + ep.shortGuid +
                L"\\FxProperties";
            if (!FxKeyWritable(fxSub)) bad.emplace_back(ep.shortGuid, fxSub);
        }
        c.ok = bad.empty();
        if (c.ok) {
            c.detail = "已挂载端点 FxProperties 全部可写（" +
                       std::to_string(installed.size()) + " 个）";
        } else {
            std::string list;
            for (const auto& [g, f] : bad) {
                if (!list.empty()) list += ",";
                list += WideToUtf8(g);
            }
            c.detail = "不可写端点: " + list;
        }
        if (!c.ok && fix) {
            bool allFixed = true;
            for (const auto& [g, f] : bad) {
                if (!TakeOwnershipRepair(f) || !FxKeyWritable(f))
                    allFixed = false;
            }
            if (allFixed) {
                c.ok = true;
                c.fixed = true;
                c.detail += "（接管所有权后已可写）";
            }
        }
        checks.push_back(c);
    }
    // 6. 快照版本（过新只报告，不自动修）
    {
        DoctorCheck c;
        c.name = "snapshot_versions";
        std::string tooNew;
        for (const auto& ep : installed) {
            const RegValue* v = ep.Get(L"Version");
            if (v && v->type == REG_SZ &&
                !apoplan::SnapshotVersionSupported(v->sz)) {
                if (!tooNew.empty()) tooNew += ",";
                tooNew += WideToUtf8(ep.shortGuid);
            }
        }
        c.ok = tooNew.empty();
        c.detail = c.ok ? "已挂载端点快照版本均受支持"
                        : "过新快照端点: " + tooNew + "（需新版工具）";
        checks.push_back(c);
    }

    bool allOk = true;
    for (const auto& c : checks) allOk = allOk && c.ok;
    if (asJson) {
        std::vector<Json> arr;
        for (const auto& c : checks) {
            arr.push_back(Json::Obj({
                {"name", Json::Str(c.name)},
                {"ok", Json::Bool(c.ok)},
                {"detail", Json::Str(c.detail)},
                {"fixed", Json::Bool(c.fixed)},
            }));
        }
        OutJson(Json::Obj({
            {"ok", Json::Bool(allOk)},
            {"fix", Json::Bool(fix)},
            {"checks", Json::Arr(std::move(arr))},
        }));
    } else {
        OutLine("=== AuraDSP APO 环境自检 (doctor) ===");
        for (const auto& c : checks) {
            OutLine(std::string(c.ok ? "[OK] " : "[FAIL] ") + c.name +
                    ": " + c.detail + (c.fixed ? "（已修复）" : ""));
        }
        OutLine(allOk ? "结论: 全部通过"
                      : "结论: 有未通过项（可修项用 --fix 处理）");
    }
    return allOk ? 0 : 1;
}

int CmdInstall(const std::wstring& substr, std::wstring mode, bool force,
               bool asJson, apoplan::Only onlyReq) {
    if (!IsAdmin()) {
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("admin_required")},
                {"message", Json::Str("安装 System APO 需要管理员权限")},
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
    // 安装计划（计划书 Part II W1）：模式/前后混限定/端点方向/OS
    // 代际 → 写集合与跨模式清理集合，纯逻辑在 apo_install_plan.h。
    const bool isCapture = ToLowerA(ep.direction) == "capture";
    const apoplan::InstallPlan plan =
        apoplan::ResolveInstallPlan(mode, onlyReq, isCapture, win7);
    if (!plan.valid) {
        const std::string msg =
            "--only post 与 --mode sfx-only 不能组合（sfx-only 只有流侧位置）";
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("invalid_only")},
                {"message", Json::Str(msg)},
            }));
        } else {
            OutLine("FATAL: " + msg);
        }
        return 2;
    }
    mode = plan.mode;

    if (!EnsureComRegistered()) {
        const std::string msg = "AuraApo.dll 未注册且自动注册失败";
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("apo_dll_register_failed")},
                {"message", Json::Str(msg)},
            }));
        } else {
            OutLine("FATAL: " + msg);
        }
        return 1;
    }

    const auto testenv =
        RegRead(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal);
    if (!testenv || testenv->type != REG_DWORD || testenv->dword != 1) {
        RegWrite(HKEY_LOCAL_MACHINE, kTestEnvKey, kTestEnvVal, RegDword(1));
    }

    Json meta = BackupEndpoint(ep, mode);
    if (const Json* bf = meta.Find("backup_failed");
        bf && bf->type == Json::Type::Bool && bf->boolean) {
        const std::string msg = "备份端点原始值失败，已中止安装（未做任何改动）";
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("backup_failed")},
                {"message", Json::Str(msg)},
            }));
        } else {
            OutLine("FATAL: " + msg);
        }
        return 1;
    }

    const std::wstring shortGuid = ShortGuid(Utf8ToWide(ep.id));
    const std::wstring fxSub = ep.FxSub();
    const std::wstring childSub =
        std::wstring(kChildApoRoot) + L"\\" + shortGuid;
    const std::vector<std::wstring> slotKeys = SlotKeys();
    // 写成败必查（细审 R-C M-2）：旧实现 RegCreateKeyEx 失败
    // 整段静默跳过、RegSetValueExW 返回值全弃，末尾仍报
    // ok:true——ACL 异常/DLL 缺失时全链假成功。
    bool fxOk = true;
    HKEY k = nullptr;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, fxSub.c_str(), 0, nullptr, 0,
                        KEY_SET_VALUE | KEY_QUERY_VALUE, nullptr, &k,
                        nullptr) == ERROR_SUCCESS) {
        auto setSz = [&](const std::wstring& n, const std::wstring& v) {
            if (RegSetValueExW(
                    k, n.c_str(), 0, REG_SZ,
                    reinterpret_cast<const BYTE*>(v.c_str()),
                    static_cast<DWORD>((v.size() + 1) * sizeof(wchar_t))) !=
                ERROR_SUCCESS) {
                fxOk = false;
            }
        };
        setSz(std::wstring(kFxBase) + L",0", kNullGuid);
        // 跨模式清理（计划书 Part II W1，借 EqualizerAPO）：本次
        // 不写的其他代际/模式槽位恢复到首份快照原始值，消除换
        // 模式残留双注册。快照条目缺失时退化为按现值剥离我方
        // CLSID。删除失败忽略（值不存在即 no-op，与 restore
        // 同）；写回失败计入 fxOk 诚实上报。
        for (const int idx : plan.foreignIdx) {
            const std::wstring& slot = slotKeys[idx];
            const auto stored =
                RegRead(HKEY_LOCAL_MACHINE, childSub, slot);
            if (stored && stored->IsSentinel()) {
                RegDeleteValueW(k, slot.c_str());
            } else if (stored) {
                RegValue v = *stored;
                if (v.type == REG_MULTI_SZ) {
                    std::vector<std::wstring> clean;
                    for (const auto& x : v.multi) {
                        if (ToLowerW(x) !=
                            ToLowerW(std::wstring(kOurClsid)))
                            clean.push_back(x);
                    }
                    v.multi = clean;
                }
                if (v.type == REG_MULTI_SZ && v.multi.empty()) {
                    RegDeleteValueW(k, slot.c_str());
                } else if (!SetRegValueRaw(k, slot, v)) {
                    fxOk = false;
                }
            } else {
                const auto cur =
                    RegRead(HKEY_LOCAL_MACHINE, fxSub, slot);
                if (cur && cur->type == REG_SZ &&
                    ToLowerW(cur->sz) ==
                        ToLowerW(std::wstring(kOurClsid))) {
                    RegDeleteValueW(k, slot.c_str());
                } else if (cur && cur->type == REG_MULTI_SZ) {
                    std::vector<std::wstring> clean;
                    for (const auto& x : cur->multi) {
                        if (ToLowerW(x) !=
                            ToLowerW(std::wstring(kOurClsid)))
                            clean.push_back(x);
                    }
                    if (clean.size() != cur->multi.size()) {
                        if (clean.empty()) {
                            RegDeleteValueW(k, slot.c_str());
                        } else if (!SetRegValueRaw(
                                       k, slot, RegMulti(clean))) {
                            fxOk = false;
                        }
                    }
                }
            }
        }
        for (const int idx : plan.singleIdx) {
            setSz(slotKeys[idx], kOurClsid);
        }
        for (const int idx : plan.multiIdx) {
            const std::wstring& slot = slotKeys[idx];
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
            for (const auto& str : list) {
                buf.insert(buf.end(), str.begin(), str.end());
                buf.push_back(L'\0');
            }
            buf.push_back(L'\0');
            if (RegSetValueExW(
                    k, slot.c_str(), 0, REG_MULTI_SZ,
                    reinterpret_cast<const BYTE*>(buf.data()),
                    static_cast<DWORD>(buf.size() * sizeof(wchar_t))) !=
                ERROR_SUCCESS) {
                fxOk = false;
            }
        }
        if (!win7) {
            for (const int pos : plan.procModePos) {
                const std::wstring pmKey =
                    std::wstring(kProcModes) + L"," + std::to_wstring(pos);
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
                    if (RegSetValueExW(
                            k, pmKey.c_str(), 0, REG_MULTI_SZ,
                            reinterpret_cast<const BYTE*>(buf.data()),
                            static_cast<DWORD>(buf.size() *
                                               sizeof(wchar_t))) !=
                        ERROR_SUCCESS) {
                        fxOk = false;
                    }
                }
            }
        }
        RegDeleteValueW(k, (std::wstring(kDisableEnh) + L",5").c_str());
        RegCloseKey(k);
    } else {
        fxOk = false;
    }
    if (!fxOk) {
        const std::string msg = "写入 FxProperties 失败（注册表键不可写）";
        if (asJson) {
            OutJson(Json::Obj({
                {"ok", Json::Bool(false)},
                {"error", Json::Str("fx_write_failed")},
                {"message", Json::Str(msg)},
            }));
        } else {
            OutLine("FATAL: " + msg);
        }
        return 1;
    }

    const bool restarted = RestartAudio();

    if (asJson) {
        OutJson(Json::Obj({
            {"ok", Json::Bool(true)},
            {"endpoint_id", Json::Str(ep.id)},
            {"short_guid", Json::Str(WideToUtf8(shortGuid))},
            {"name", Json::Str(WideToUtf8(name))},
            {"mode", Json::Str(WideToUtf8(mode))},
            {"only", plan.only == apoplan::Only::Pre
                         ? Json::Str("pre")
                         : plan.only == apoplan::Only::Post
                               ? Json::Str("post")
                               : Json{}},
            {"capture_pre_only", Json::Bool(plan.capturePreOnly)},
            {"backup", std::move(meta)},
            {"audio_restarted", Json::Bool(restarted)},
        }));
    } else {
        OutLine("成功将 AuraAPO 挂载到 '" + WideToUtf8(name) + "' (" +
                WideToUtf8(shortGuid) + ")");
        OutLine("挂载模式: " + WideToUtf8(mode) +
                (plan.only == apoplan::Only::Pre
                     ? ", 位置限定: pre" +
                           std::string(plan.capturePreOnly
                                           ? "（捕获端点默认）"
                                           : "")
                     : plan.only == apoplan::Only::Post
                           ? ", 位置限定: post"
                           : "") +
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
                {"message", Json::Str("卸载 System APO 需要管理员权限")},
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

    // 顶层 ok 必须反映端点级成败（细审 R-C M-1）：旧实现恒
    // true，某端点还原失败时 App 全链假报卸载成功、APO 实
    // 际仍挂载而用户无从知晓。
    bool allOk = true;
    for (const auto& [guid, r] : restoredText) {
        if (!r.ok) allOk = false;
    }

    if (asJson) {
        std::vector<std::pair<std::string, Json>> fields;
        fields.emplace_back("ok", Json::Bool(allOk));
        fields.emplace_back("restored", Json::Arr(std::move(restored)));
        fields.emplace_back("audio_restarted", Json::Bool(restarted));
        fields.emplace_back(
            "remaining_count",
            Json::Num(static_cast<double>(remaining.size())));
        if (!allOk) {
            fields.emplace_back(
                "message", Json::Str("部分端点还原失败，见 restored 明细"));
        }
        OutJson(Json::Obj(std::move(fields)));
    } else {
        for (const auto& [guid, r] : restoredText) {
            OutLine("还原结果: " + WideToUtf8(guid) + " -> " +
                    WideToUtf8(r.message));
        }
        OutLine(std::string("音频服务重启: ") + (restarted ? "成功" : "失败"));
    }
    return allOk ? 0 : 1;
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
    OutLine("  apo_config install <端点名子串> --yes [--force] [--mode sfx-efx|composite|sfx-only|win7-sapo] [--only pre|post] [--json] [--elevate] [--result-file <文件>]");
    OutLine("  apo_config uninstall [目标] --yes [--json] [--elevate] [--result-file <文件>]");
    OutLine("  apo_config testenv-on | testenv-off [--json] [--elevate]");
    OutLine("  apo_config doctor [--fix] [--json] [--elevate] [--result-file <文件>]");
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
    for (size_t i = 0; i + 1 < args.size(); ++i) {
        if (args[i] == L"--result-file") g_resultFile = args[i + 1];
    }
    // 带结果文件时强制 JSON 发射：install/uninstall 的成败
    // 结果都经 OutJson 唯一出口，文件里留下的即
    // 最终裁定（含 error/message），App 据此呈现真实原因。
    if (!g_resultFile.empty() && !args.empty() &&
        (args[0] == L"install" || args[0] == L"uninstall" ||
         args[0] == L"doctor")) {
        asJson = true;
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
    if (verb == L"doctor") {
        return CmdDoctor(hasFlag(L"--fix"), asJson);
    }
    if (verb == L"install") {
        if (args.size() < 2 || args[1].rfind(L"--", 0) == 0) {
            // 早期参数错误也走结果文件通道（细审 R-C L-1）：
            // 此前只 OutLine 纯文本，带 result-file 的 App
            // 调用读不到任何裁定（App 恒传 --yes+端点，此修
            // 主要保 CLI/通道一致性）。
            if (asJson) {
                OutJson(Json::Obj({
                    {"ok", Json::Bool(false)},
                    {"error", Json::Str("missing_endpoint")},
                    {"message", Json::Str("用法: apo_config install <端点名子串> [--mode sfx-efx|composite|sfx-only] [--only pre|post] [--yes] [--force] [--json]")},
                }));
            } else {
                OutLine("用法: apo_config install <端点名子串> [--mode sfx-efx|composite|sfx-only] [--only pre|post] [--yes] [--force] [--json]");
            }
            return 2;
        }
        if (!hasFlag(L"--yes")) {
            if (asJson) {
                OutJson(Json::Obj({
                    {"ok", Json::Bool(false)},
                    {"error", Json::Str("confirmation_required")},
                    {"message", Json::Str("修改底层驱动配置需提供 --yes 确认参数")},
                }));
            } else {
                OutLine("FATAL: 修改底层驱动配置需提供 --yes 确认参数");
            }
            return 1;
        }
        std::wstring mode = L"sfx-efx";
        if (const auto v = optValue(L"--mode")) {
            mode = *v;
        } else if (hasFlag(L"--composite")) {
            mode = L"composite";
        }
        apoplan::Only onlyReq = apoplan::Only::None;
        if (const auto v = optValue(L"--only")) {
            if (*v == L"pre") {
                onlyReq = apoplan::Only::Pre;
            } else if (*v == L"post") {
                onlyReq = apoplan::Only::Post;
            } else {
                if (asJson) {
                    OutJson(Json::Obj({
                        {"ok", Json::Bool(false)},
                        {"error", Json::Str("invalid_only")},
                        {"message", Json::Str("--only 只接受 pre 或 post")},
                    }));
                } else {
                    OutLine("FATAL: --only 只接受 pre 或 post");
                }
                return 2;
            }
        }
        return CmdInstall(args[1], mode, hasFlag(L"--force"), asJson,
                          onlyReq);
    }
    if (verb == L"uninstall") {
        if (!hasFlag(L"--yes")) {
            if (asJson) {
                OutJson(Json::Obj({
                    {"ok", Json::Bool(false)},
                    {"error", Json::Str("confirmation_required")},
                    {"message", Json::Str("卸载底层驱动配置需提供 --yes 确认参数")},
                }));
            } else {
                OutLine("FATAL: 卸载底层驱动配置需提供 --yes 确认参数");
            }
            return 1;
        }
        std::wstring target;
        if (args.size() > 1 && args[1].rfind(L"--", 0) != 0) target = args[1];
        return CmdUninstall(target, asJson);
    }

    if (asJson) {
        OutJson(Json::Obj({
            {"ok", Json::Bool(false)},
            {"error", Json::Str("unknown_command")},
            {"message", Json::Str("未知子命令: " + WideToUtf8(args[0]))},
        }));
    } else {
        OutLine("未知子命令: " + WideToUtf8(args[0]));
    }
    return 2;
}
