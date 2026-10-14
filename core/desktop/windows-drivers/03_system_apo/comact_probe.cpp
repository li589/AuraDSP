// comact_probe.cpp — CoCreateInstance 验证补回的两个 CLSID（正统 COM 激活）。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <unknwn.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <cstdio>

static const CLSID kClsidMmdevEnum = {0xbcdea5bc, 0xa646, 0x1186,
                                      {0xbf, 0x00, 0x00, 0xc0, 0x95, 0x8e, 0x50, 0xae}};
static const CLSID kClsidPolicy = {0x870af99c, 0x171d, 0x4f9e,
                                   {0xaf, 0x0d, 0x3c, 0xcf, 0xde, 0xbc, 0x34, 0x34}};
static const IID kIidPolicy = {0x568b9108, 0x44bf, 0x40b4,
                               {0x90, 0x06, 0x86, 0xaf, 0xe5, 0xb5, 0xa6, 0x20}};

int main() {
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 1;
    void* p = nullptr;
    HRESULT hr = CoCreateInstance(kClsidMmdevEnum, nullptr, CLSCTX_INPROC_SERVER,
                                  __uuidof(IMMDeviceEnumerator), &p);
    printf("MMDeviceEnumerator CoCreate: hr=0x%08lX ptr=%p\n", (unsigned long)hr, p);
    if (p) ((IUnknown*)p)->Release();
    p = nullptr;
    hr = CoCreateInstance(kClsidPolicy, nullptr, CLSCTX_INPROC_SERVER, kIidPolicy, &p);
    printf("PolicyConfig Vista CoCreate: hr=0x%08lX ptr=%p\n", (unsigned long)hr, p);
    if (p) ((IUnknown*)p)->Release();
    CoUninitialize();
    return 0;
}
