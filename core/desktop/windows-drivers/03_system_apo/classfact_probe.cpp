// classfact_probe.cpp — 直接 DllGetClassObject 验证 mmdevapi 提供哪些类。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <unknwn.h>
#include <cstdio>

static const CLSID kClsidMmdevEnum = {0xbcdea5bc, 0xa646, 0x1186,
                                      {0xbf, 0x00, 0x00, 0xc0, 0x95, 0x8e, 0x50, 0xae}};
static const CLSID kClsidPolicy = {0x870af99c, 0x171d, 0x4f9e,
                                   {0xaf, 0x0d, 0x3c, 0xcf, 0xde, 0xbc, 0x34, 0x34}};

int main() {
    HMODULE h = LoadLibraryW(L"C:\\Windows\\System32\\mmdevapi.dll");
    if (!h) {
        printf("load fail %lu\n", GetLastError());
        return 1;
    }
    auto getClass = (HRESULT(__stdcall*)(REFCLSID, REFIID, void**))GetProcAddress(h, "DllGetClassObject");
    if (!getClass) {
        printf("no DllGetClassObject\n");
        return 1;
    }
    IID iidFactory = {0x00000001, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
    void* p = nullptr;
    HRESULT hr = getClass(kClsidMmdevEnum, iidFactory, &p);
    printf("mmdev enum: hr=0x%08lX factory=%p\n", (unsigned long)hr, p);
    if (p) ((IUnknown*)p)->Release();
    p = nullptr;
    hr = getClass(kClsidPolicy, iidFactory, &p);
    printf("policy    : hr=0x%08lX factory=%p\n", (unsigned long)hr, p);
    if (p) ((IUnknown*)p)->Release();
    FreeLibrary(h);
    return 0;
}
