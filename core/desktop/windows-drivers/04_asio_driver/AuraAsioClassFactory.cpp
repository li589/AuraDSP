// AuraAsioClassFactory.cpp — AuraDSP ASIO 类厂实现
#include "AuraAsioClassFactory.h"
#include "AuraAsioDriver.h"
#include "AuraAsioDriverGuid.h"

#include <new>

std::atomic<long> AuraAsioClassFactory::s_lockCount{0};

AuraAsioClassFactory::AuraAsioClassFactory() = default;
AuraAsioClassFactory::~AuraAsioClassFactory() = default;

HRESULT __stdcall AuraAsioClassFactory::QueryInterface(REFIID riid, void** ppvObject) {
    if (!ppvObject) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IClassFactory) {
        *ppvObject = static_cast<IClassFactory*>(this);
        AddRef();
        return S_OK;
    }
    *ppvObject = nullptr;
    return E_NOINTERFACE;
}

ULONG __stdcall AuraAsioClassFactory::AddRef() {
    return (ULONG)m_refCount.fetch_add(1, std::memory_order_relaxed) + 1;
}

ULONG __stdcall AuraAsioClassFactory::Release() {
    long prev = m_refCount.fetch_sub(1, std::memory_order_release);
    if (prev == 1) {
        std::atomic_thread_fence(std::memory_order_acquire);
        delete this;
        return 0;
    }
    return (ULONG)(prev - 1);
}

HRESULT __stdcall AuraAsioClassFactory::CreateInstance(IUnknown* pUnkOuter, REFIID riid, void** ppvObject) {
    if (!ppvObject) return E_POINTER;
    *ppvObject = nullptr;
    if (pUnkOuter && riid != IID_IUnknown) return CLASS_E_NOAGGREGATION;

    auto* driver = new (std::nothrow) AuraAsioDriver();
    if (!driver) return E_OUTOFMEMORY;

    const HRESULT hr = driver->QueryInterface(riid, ppvObject);
    driver->Release();
    return hr;
}

HRESULT __stdcall AuraAsioClassFactory::LockServer(BOOL fLock) {
    if (fLock) {
        s_lockCount.fetch_add(1, std::memory_order_relaxed);
    } else {
        s_lockCount.fetch_sub(1, std::memory_order_relaxed);
    }
    return S_OK;
}
