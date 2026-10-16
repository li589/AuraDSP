// AuraAsioClassFactory.h — AuraDSP ASIO 类厂定义
#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <unknwn.h>
#include <atomic>

class AuraAsioClassFactory : public IClassFactory {
public:
    AuraAsioClassFactory();
    virtual ~AuraAsioClassFactory();

    // IUnknown
    virtual HRESULT __stdcall QueryInterface(REFIID riid, void** ppvObject) override;
    virtual ULONG __stdcall AddRef() override;
    virtual ULONG __stdcall Release() override;

    // IClassFactory
    virtual HRESULT __stdcall CreateInstance(IUnknown* pUnkOuter, REFIID riid, void** ppvObject) override;
    virtual HRESULT __stdcall LockServer(BOOL fLock) override;

    static std::atomic<long> s_lockCount;

private:
    std::atomic<long> m_refCount{1};
};
