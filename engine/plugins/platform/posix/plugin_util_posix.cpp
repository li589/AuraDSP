// plugin_util_posix.cpp —— win32_util.h 的 POSIX 实现（二期阶段一）。
// 与 platform/win32/win32_util.cpp 对位；语义差异见 win32_util.h 头注。
#include "win32_util.h"

#include <cstdlib>
#include <cstring>

namespace auradsp {

std::vector<std::string> defaultPluginSearchPaths() {
    std::vector<std::string> paths;
    if (const char* home = std::getenv("HOME")) {
        paths.push_back(std::string(home) + "/.vst3");
        paths.push_back(std::string(home) + "/.clap");
        paths.push_back(std::string(home) + "/.vst");
    }
    paths.push_back("/usr/lib/vst3");
    paths.push_back("/usr/local/lib/vst3");
    paths.push_back("/usr/lib/clap");
    paths.push_back("/usr/local/lib/clap");
    paths.push_back("/usr/lib/vst");
    paths.push_back("/usr/local/lib/vst");
    return paths;
}

std::string extractVendorFromPath(const std::string& filePath) {
    // 与 Win32 版同策略：父目录的父级名作厂商候选（粗略启发；
    // 元数据的正式来源是插件工厂信息，本函数只是回退）。
    std::error_code ec;
    fs::path parent = fs::path(filePath).parent_path().parent_path();
    if (parent.empty()) return std::string();
    return parent.filename().string();
}

int pluginBinaryBitness(const std::wstring& binaryPath) {
    const std::string path = wideToUtf8(binaryPath);
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return 0;
    unsigned char ident[5] = {0};
    const size_t n = std::fread(ident, 1, 5, f);
    std::fclose(f);
    if (n < 5 || ident[0] != 0x7F || ident[1] != 'E' || ident[2] != 'L' ||
        ident[3] != 'F') {
        return 0;
    }
    if (ident[4] == 1) return 32;  // ELFCLASS32
    if (ident[4] == 2) return 64;  // ELFCLASS64
    return 0;
}

bool peHasVst2Entry(const std::wstring& binaryPath) {
    // PE 版解析导出表；POSIX 版解析 ELF 动态符号表，同口径：只读
    // 文件、零代码执行。走程序头（PT_DYNAMIC → DT_SYMTAB/DT_STRTAB；
    // 符号数取 DT_HASH 的 nchain，无 DT_HASH 时由 DT_GNU_HASH 桶链
    // 推导——发行版工具链默认只发 GNU 哈希），不依赖节头——strip
    // 后的 .so 节头可能不全，程序头恒在。查 VSTPluginMain / main
    // （与 PE 版的导出名集合一致）。
    const std::string path = wideToUtf8(binaryPath);
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    const long fsize = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    // 上界比较必须走 int64_t：32 位进程里 long 只有 32 位，(1L << 31)
    // 溢出为负数会让一切正常文件都被判超限拒读（x86 宿主首跑实测：
    // 32 位 VST2 深扫全数回退快扫值，CI J3 抓到）。
    if (fsize < 64 || static_cast<int64_t>(fsize) > (static_cast<int64_t>(1) << 31)) {
        std::fclose(f);
        return false;
    }
    std::vector<unsigned char> buf(static_cast<size_t>(fsize));
    const bool readOk = std::fread(buf.data(), 1, buf.size(), f) == buf.size();
    std::fclose(f);
    if (!readOk) return false;
    const unsigned char* b = buf.data();
    const size_t n = buf.size();
    if (n < 52 || b[0] != 0x7F || b[1] != 'E' || b[2] != 'L' || b[3] != 'F') {
        return false;
    }
    const bool is64 = (b[4] == 2);
    if (b[4] != 1 && !is64) return false;
    const bool le = (b[5] == 1);
    if (!le) return false;  // 目标平台恒小端；大端 ELF 不在支持面

    auto rd16 = [&](size_t off) -> uint32_t {
        return static_cast<uint32_t>(b[off]) |
               (static_cast<uint32_t>(b[off + 1]) << 8);
    };
    auto rd32 = [&](size_t off) -> uint32_t {
        return rd16(off) | (static_cast<uint32_t>(rd16(off + 2)) << 16);
    };
    auto rd64 = [&](size_t off) -> uint64_t {
        return static_cast<uint64_t>(rd32(off)) |
               (static_cast<uint64_t>(rd32(off + 4)) << 32);
    };

    const uint64_t phoff = is64 ? rd64(32) : rd32(28);
    const uint32_t phentsize = rd16(is64 ? 54 : 42);
    const uint32_t phnum = rd16(is64 ? 56 : 44);
    if (phoff == 0 || phnum == 0 || phnum > 128 || phentsize < (is64 ? 56u : 32u)) {
        return false;
    }
    struct Seg { uint64_t vaddr, offset, filesz; };
    std::vector<Seg> loads;
    uint64_t dynOff = 0, dynSize = 0;
    for (uint32_t i = 0; i < phnum; ++i) {
        const size_t po = static_cast<size_t>(phoff) + i * phentsize;
        if (po + phentsize > n) return false;
        const uint32_t type = rd32(po);
        uint64_t off, vaddr, filesz;
        if (is64) {
            off = rd64(po + 8); vaddr = rd64(po + 16); filesz = rd64(po + 32);
        } else {
            off = rd32(po + 4); vaddr = rd32(po + 8); filesz = rd32(po + 16);
        }
        if (type == 1) {  // PT_LOAD
            loads.push_back({vaddr, off, filesz});
        } else if (type == 2) {  // PT_DYNAMIC
            dynOff = off; dynSize = filesz;
        }
    }
    if (dynOff == 0 || dynSize == 0) return false;
    auto v2o = [&](uint64_t vaddr) -> uint64_t {
        for (const Seg& s : loads) {
            if (vaddr >= s.vaddr && vaddr - s.vaddr < s.filesz) {
                return s.offset + (vaddr - s.vaddr);
            }
        }
        return 0;
    };
    uint64_t symtab = 0, strtab = 0, strsz = 0, hash = 0, gnuHash = 0;
    const size_t dynEnt = is64 ? 16 : 8;
    for (uint64_t doff = dynOff; doff + dynEnt <= dynOff + dynSize && doff + dynEnt <= n;
         doff += dynEnt) {
        const int64_t tag = is64 ? static_cast<int64_t>(rd64(static_cast<size_t>(doff)))
                                 : static_cast<int32_t>(rd32(static_cast<size_t>(doff)));
        const uint64_t val = is64 ? rd64(static_cast<size_t>(doff) + 8)
                                  : rd32(static_cast<size_t>(doff) + 4);
        if (tag == 0) break;  // DT_NULL
        if (tag == 6) symtab = val;        // DT_SYMTAB
        else if (tag == 5) strtab = val;   // DT_STRTAB
        else if (tag == 10) strsz = val;   // DT_STRSZ
        else if (tag == 4) hash = val;     // DT_HASH
        else if (tag == 0x6ffffef5) gnuHash = val;  // DT_GNU_HASH
    }
    if (!symtab || !strtab || !strsz || (!hash && !gnuHash)) return false;
    const uint64_t symOff = v2o(symtab), strOff = v2o(strtab);
    if (!symOff || !strOff) return false;
    uint32_t nsyms = 0;
    if (hash) {
        const uint64_t hashOff = v2o(hash);
        if (!hashOff || hashOff + 8 > n) return false;
        nsyms = rd32(static_cast<size_t>(hashOff) + 4);  // nchain
    } else {
        // DT_GNU_HASH：符号数由桶链推导（取最大桶值后沿链走到
        // 链尾）。现代发行版工具链默认只发 GNU 哈希（无 DT_HASH），
        // 这是主路径而非边角。
        const uint64_t gOff = v2o(gnuHash);
        if (!gOff || gOff + 16 > n) return false;
        const uint32_t nbuckets = rd32(static_cast<size_t>(gOff));
        const uint32_t symndx = rd32(static_cast<size_t>(gOff) + 4);
        const uint32_t bloomSize = rd32(static_cast<size_t>(gOff) + 8);
        if (nbuckets == 0 || nbuckets > (1u << 20)) return false;
        const uint64_t bucketsOff = gOff + 16 +
            static_cast<uint64_t>(bloomSize) * (is64 ? 8 : 4);
        if (bucketsOff + static_cast<uint64_t>(nbuckets) * 4 > n) return false;
        uint32_t maxSym = 0;
        for (uint32_t i = 0; i < nbuckets; ++i) {
            const uint32_t bv = rd32(static_cast<size_t>(bucketsOff) + i * 4);
            if (bv > maxSym) maxSym = bv;
        }
        if (maxSym < symndx) return false;
        const uint64_t chainOff = bucketsOff +
            static_cast<uint64_t>(nbuckets) * 4 -
            static_cast<uint64_t>(symndx) * 4;
        uint32_t cur = maxSym;
        for (;;) {
            const uint64_t coff = chainOff + static_cast<uint64_t>(cur) * 4;
            if (coff + 4 > n) return false;
            const uint32_t cv = rd32(static_cast<size_t>(coff));
            ++cur;
            if (cv & 1u) break;
            if (cur > (1u << 20)) return false;
        }
        nsyms = cur;
    }
    if (nsyms == 0 || nsyms > (1u << 20)) return false;
    const size_t symEnt = is64 ? 24 : 16;
    for (uint32_t i = 0; i < nsyms; ++i) {
        const uint64_t soff = symOff + static_cast<uint64_t>(i) * symEnt;
        if (soff + symEnt > n) return false;
        const uint32_t nameOff = rd32(static_cast<size_t>(soff));
        if (nameOff == 0 || nameOff >= strsz) continue;
        const uint64_t noff = strOff + nameOff;
        if (noff >= n) continue;
        const size_t maxLen = static_cast<size_t>(
            std::min<uint64_t>(strsz - nameOff, n - noff));
        const char* name = reinterpret_cast<const char*>(b + noff);
        if (std::memchr(name, '\0', maxLen) == nullptr) continue;
        if (std::strcmp(name, "VSTPluginMain") == 0 ||
            std::strcmp(name, "main") == 0) {
            return true;
        }
    }
    return false;
}

bool peIs64Bit(const std::wstring& binaryPath) {
    // Linux 对应物：判 ELF class（ELFCLASS64=2）。非 ELF/不可读
    // 返回 false（与 PE 判定失败同口径：不进入加载尝试）。
    const std::string path = wideToUtf8(binaryPath);
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    unsigned char ident[5] = {0};
    const size_t n = std::fread(ident, 1, 5, f);
    std::fclose(f);
    if (n < 5) return false;
    if (ident[0] != 0x7F || ident[1] != 'E' || ident[2] != 'L' ||
        ident[3] != 'F') {
        return false;
    }
    return ident[4] == 2; // ELFCLASS64
}

// ELF 无 PE 版本资源对应物：返回空，元数据走工厂信息/路径回退。
std::string extractCompanyFromVersionInfo(const std::wstring&) {
    return std::string();
}
std::string extractProductVersionFromVersionInfo(const std::wstring&) {
    return std::string();
}
std::string extractVendorFromLegalCopyright(const std::wstring&) {
    return std::string();
}

// dlopen 的依赖解析走 DT_NEEDED/RPATH/LD_LIBRARY_PATH，无
// AddDllDirectory 对应物：空操作（插件依赖目录问题在 Linux 由
// 插件自身 rpath/打包解决，属打包议题而非宿主 API）。
void setupPluginDllDirectories(const std::string&) {}
void releasePluginDllDirectories(const std::string&) {}
size_t pluginDllDirectoryCount() { return 0; }
std::vector<std::string> pluginDllDirectoryList() { return {}; }
size_t pluginDllDirectoryRefs() { return 0; }

// 编辑器窗口辅助：Linux 编辑器本体为后续阶段（X11 嵌入），
// 本阶段为空操作；编辑器入口由 instance 的 showEditor 在非
// Windows 显式返回不可用（阶段三收口），不依赖这里的假成功。
void ResizeDirectChildren(HWND) {}
void FlashEditorToFront(HWND) {}
void EnsureClapWindowClassRegistered() {}
void EnsureVst3WindowClassRegistered() {}
void EnsureVst2WindowClassRegistered() {}

} // namespace auradsp
