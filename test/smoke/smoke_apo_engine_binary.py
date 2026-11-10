# smoke_apo_engine_binary.py — APO 专用引擎 DLL 的二进制纪律门（设计 D2）
#
# auradsp_engine_apo.dll 要住进 audiodg（全 CFG 进程 + LPAC）：两条
# 定罪纪律必须在产物层成立，光看 CMake 旗标不够——本门纯 Python
# 解析 PE 本体断言：
#   ① 导出面：auradsp_create / auradsp_abi 在位（.def 表面未丢）；
#   ② 导入表：不得出现动态 CRT（vcruntime140*/msvcp140*/concrt140/
#      vccorlib140）——/MT 的证据；ucrtbase 是 Windows 系统组件，不禁；
#   ③ Load Config：CFG 函数表在位（GuardFlags 的
#      IMAGE_GUARD_CF_FUNCTION_TABLE_PRESENT + 函数计数 > 0）。
# 文件缺失（非 Windows 构建环境）→ SKIP。J5 在默认构建后显式调用
# （与 smoke_release_strings 同位），runner 登记 PLATFORM_WINDOWS。
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_DLL = os.path.join(
    ROOT, 'core', 'desktop', 'windows', 'out', 'Release', 'auradsp_engine_apo.dll')
BANNED_IMPORTS = {
    'vcruntime140.dll', 'vcruntime140_1.dll', 'vcruntime140d.dll',
    'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140d.dll',
    'concrt140.dll', 'vccorlib140.dll',
}
FAIL = []


def check(cond, label):
    print(('  PASS ' if cond else '  FAIL ') + label)
    if not cond:
        FAIL.append(label)


class PE:
    def __init__(self, data):
        self.d = data
        assert data[:2] == b'MZ', 'not a PE (no MZ)'
        self.pe_off = struct.unpack_from('<I', data, 0x3C)[0]
        assert data[self.pe_off:self.pe_off + 4] == b'PE\0\0', 'no PE signature'
        coff = self.pe_off + 4
        self.machine, self.nsec = struct.unpack_from('<HH', data, coff)
        opt_size = struct.unpack_from('<H', data, coff + 16)[0]
        self.opt = coff + 20
        magic = struct.unpack_from('<H', data, self.opt)[0]
        assert magic == 0x20B, f'expected PE32+ optional header, got {magic:#x}'
        self.dirs = self.opt + 112  # 数据目录起始（PE32+）
        self.sections = []
        sec_off = self.opt + opt_size
        for i in range(self.nsec):
            o = sec_off + 40 * i
            _name, vsize, vaddr, rawsize, rawptr = struct.unpack_from(
                '<8sIIII', data, o)
            self.sections.append((vaddr, max(vsize, 1), rawptr, rawsize))

    def dir(self, idx):
        return struct.unpack_from('<II', self.d, self.dirs + 8 * idx)

    def rva2off(self, rva):
        for vaddr, vsize, rawptr, rawsize in self.sections:
            if vaddr <= rva < vaddr + max(vsize, rawsize):
                return rawptr + (rva - vaddr)
        raise ValueError(f'RVA {rva:#x} not in any section')

    def cstr(self, off):
        end = self.d.index(b'\0', off)
        return self.d[off:end].decode('ascii', 'replace')

    def imports(self):
        rva, _size = self.dir(1)
        out = []
        if rva == 0:
            return out
        off = self.rva2off(rva)
        while True:
            fields = struct.unpack_from('<IIIII', self.d, off)
            if fields == (0, 0, 0, 0, 0):
                break
            out.append(self.cstr(self.rva2off(fields[3])).lower())
            off += 20
        return out

    def exports(self):
        rva, _size = self.dir(0)
        out = []
        if rva == 0:
            return out
        off = self.rva2off(rva)
        n_names = struct.unpack_from('<I', self.d, off + 24)[0]
        names_rva = struct.unpack_from('<I', self.d, off + 32)[0]
        names_off = self.rva2off(names_rva)
        for i in range(n_names):
            name_rva = struct.unpack_from('<I', self.d, names_off + 4 * i)[0]
            out.append(self.cstr(self.rva2off(name_rva)))
        return out

    def load_config_guard(self):
        """→ (guard_flags, cf_function_count) 或 None（无 Load Config）。"""
        rva, size = self.dir(10)
        if rva == 0 or size < 148:
            return None
        off = self.rva2off(rva)
        # IMAGE_LOAD_CONFIG_DIRECTORY64：GuardCFFunctionTable @128、
        # GuardCFFunctionCount @136、GuardFlags @144。
        _table, count = struct.unpack_from('<QQ', self.d, off + 128)
        flags = struct.unpack_from('<I', self.d, off + 144)[0]
        return flags, count


def main():
    path = os.environ.get('AURADSP_APO_DLL', DEFAULT_DLL)
    if not os.path.exists(path):
        print(f'smoke_apo_engine_binary: SKIP (missing {path})')
        return 0
    print(f'target: {path}')
    pe = PE(open(path, 'rb').read())
    check(pe.machine == 0x8664, 'machine x64')

    exps = pe.exports()
    check('auradsp_create' in exps, 'export auradsp_create 在位')
    check('auradsp_abi' in exps, 'export auradsp_abi 在位')

    imps = pe.imports()
    print('    imports: ' + ', '.join(imps))
    check('kernel32.dll' in imps, 'imports 含 kernel32.dll（解析健全性）')
    bad = [i for i in imps if i in BANNED_IMPORTS]
    check(not bad, f'导入表无动态 CRT（/MT 证据）{": " + str(bad) if bad else ""}')

    guard = pe.load_config_guard()
    check(guard is not None, 'Load Config 目录在位')
    if guard is not None:
        flags, count = guard
        check(bool(flags & 0x100),
              f'CFG 函数表标志在位 (GuardFlags={flags:#x})')
        check(count > 0, f'CFG 函数计数 > 0 (count={count})')

    print('smoke_apo_engine_binary: ' + ('FAIL' if FAIL else 'PASS'))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
