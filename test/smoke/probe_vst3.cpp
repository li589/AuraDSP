/*
 * probe_vst3.cpp — 门禁自建最小 VST3 探针（固定增益 0.5）。
 *
 * Linux 上长期缺少真实 VST3 二进制做活体断言（扫描节只能拿 CLAP
 * 探针充任 bundle 内层）。本探针以 vendored Steinberg 头（LSP
 * amalgamation）实现单组件模型：一个类同时实现 IComponent /
 * IAudioProcessor / IEditController，工厂经 GetPluginFactory 暴露，
 * Linux 入口 ModuleEntry/ModuleExit 为空转。行为与 probe_gain.c
 * 对齐：默认增益 0.5，参数 id=100 的 normalized 值即增益。
 *
 * 由 smoke_linux_plugin_host.py 在临时目录现编（g++，可加 -m32），
 * 不入仓库构建。
 */
#include <atomic>
#include <cstdio>
#include <cstring>

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IBStream.h>
#include <steinberg/vst3/base/IPluginFactory.h>
#include <steinberg/vst3/base/IPluginFactory2.h>
#include <steinberg/vst3/base/IPluginFactory3.h>
#include <steinberg/vst3_static.h>  // 单头 amalgamation 的 IID 定义单元（缺它 dlopen 报 FUnknown::iid 未定义）
#include <steinberg/vst3/gui/IPlugView.h>
#include <steinberg/vst3/vst/IAudioProcessor.h>
#include <steinberg/vst3/vst/IComponent.h>
#include <steinberg/vst3/vst/IComponentHandler.h>
#include <steinberg/vst3/vst/IEditController.h>
#include <steinberg/vst3/vst/ProcessData.h>
#include <steinberg/vst3/vst/Speaker.h>

namespace st = Steinberg;
namespace vst = Steinberg::Vst;

// 探针组件类 ID（固定；门禁按 name/vendor 断言，id 只验非空稳定）。
static const st::TUID kProbeCid = {0x41, 0x75, 0x72, 0x61, 0x44, 0x53, 0x50, 0x50,
                                   0x72, 0x6f, 0x62, 0x65, 0x56, 0x53, 0x54, 0x33};
static constexpr vst::ParamID kGainId = 100;

static bool iidEq(const st::TUID a, const st::TUID b) {
    return std::memcmp(a, b, sizeof(st::TUID)) == 0;
}

template <size_t N>
static void copyAscii(char (&dst)[N], const char* src) {
    std::strncpy(dst, src, N - 1);
    dst[N - 1] = '\0';
}

template <size_t N>
static void copyStr16(st::char16 (&dst)[N], const char16_t* src) {
    size_t i = 0;
    for (; src[i] && i + 1 < N; ++i) dst[i] = static_cast<st::char16>(src[i]);
    dst[i] = 0;
}

// ---------------------------------------------------------------- 组件
class ProbeComponent final : public vst::IComponent,
                             public vst::IAudioProcessor,
                             public vst::IEditController {
public:
    // FUnknown（多接口共用同一对象与引用计数）
    st::tresult PLUGIN_API queryInterface(const st::TUID iid, void** obj) override {
        if (!obj) return st::kInvalidArgument;
        *obj = nullptr;
        if (iidEq(iid, st::FUnknown::iid) || iidEq(iid, st::IPluginBase::iid) ||
            iidEq(iid, vst::IComponent::iid)) {
            *obj = static_cast<vst::IComponent*>(this);
        } else if (iidEq(iid, vst::IAudioProcessor::iid)) {
            *obj = static_cast<vst::IAudioProcessor*>(this);
        } else if (iidEq(iid, vst::IEditController::iid)) {
            *obj = static_cast<vst::IEditController*>(this);
        } else {
            return st::kNoInterface;
        }
        addRef();
        return st::kResultOk;
    }
    st::uint32 PLUGIN_API addRef() override {
        return static_cast<st::uint32>(++m_ref);
    }
    st::uint32 PLUGIN_API release() override {
        st::uint32 n = static_cast<st::uint32>(--m_ref);
        if (n == 0) delete this;
        return n;
    }

    // IPluginBase
    st::tresult PLUGIN_API initialize(st::FUnknown*) override { return st::kResultOk; }
    st::tresult PLUGIN_API terminate() override { return st::kResultOk; }

    // IComponent
    st::tresult PLUGIN_API getControllerClassId(st::TUID) override {
        return st::kNotImplemented;  // 单组件：控制器即本对象（QI 直达）
    }
    st::tresult PLUGIN_API setIoMode(vst::IoMode) override { return st::kResultOk; }
    st::int32 PLUGIN_API getBusCount(vst::MediaType type, vst::BusDirection dir) override {
        if (type != vst::kAudio) return 0;
        return (dir == vst::kInput || dir == vst::kOutput) ? 1 : 0;
    }
    st::tresult PLUGIN_API getBusInfo(vst::MediaType type, vst::BusDirection dir,
                                      st::int32 index, vst::BusInfo& bus) override {
        if (type != vst::kAudio || index != 0) return st::kInvalidArgument;
        bus.mediaType = type;
        bus.direction = dir;
        bus.channelCount = 2;
        bus.busType = vst::kMain;
        bus.flags = vst::BusInfo::kDefaultActive;
        copyStr16(bus.name, dir == vst::kInput ? u"In" : u"Out");
        return st::kResultOk;
    }
    st::tresult PLUGIN_API getRoutingInfo(vst::RoutingInfo&, vst::RoutingInfo&) override {
        return st::kResultFalse;
    }
    st::tresult PLUGIN_API activateBus(vst::MediaType, vst::BusDirection, st::int32,
                                       st::TBool) override {
        return st::kResultOk;
    }
    st::tresult PLUGIN_API setActive(st::TBool) override { return st::kResultOk; }
    st::tresult PLUGIN_API setState(st::IBStream*) override { return st::kResultOk; }
    st::tresult PLUGIN_API getState(st::IBStream*) override { return st::kResultOk; }

    // IAudioProcessor
    st::tresult PLUGIN_API setBusArrangements(vst::SpeakerArrangement* inputs, st::int32 numIns,
                                              vst::SpeakerArrangement* outputs,
                                              st::int32 numOuts) override {
        if (numIns > 1 || numOuts > 1) return st::kResultFalse;
        if (numIns == 1 && inputs[0] != vst::SpeakerArr::kStereo && inputs[0] != 0)
            return st::kResultFalse;
        if (numOuts == 1 && outputs[0] != vst::SpeakerArr::kStereo && outputs[0] != 0)
            return st::kResultFalse;
        return st::kResultTrue;
    }
    st::tresult PLUGIN_API getBusArrangement(vst::BusDirection, st::int32 index,
                                             vst::SpeakerArrangement& arr) override {
        if (index != 0) return st::kInvalidArgument;
        arr = vst::SpeakerArr::kStereo;
        return st::kResultOk;
    }
    st::tresult PLUGIN_API canProcessSampleSize(st::int32 size) override {
        return size == vst::kSample32 ? st::kResultTrue : st::kResultFalse;
    }
    st::uint32 PLUGIN_API getLatencySamples() override { return 0; }
    st::tresult PLUGIN_API setupProcessing(vst::ProcessSetup&) override {
        return st::kResultOk;
    }
    st::tresult PLUGIN_API setProcessing(st::TBool) override { return st::kResultOk; }
    st::tresult PLUGIN_API process(vst::ProcessData& data) override {
        if (data.numOutputs < 1) return st::kResultOk;
        vst::AudioBusBuffers& out = data.outputs[0];
        if (!out.channelBuffers32) return st::kResultOk;
        const float g = m_gain;
        vst::AudioBusBuffers* in =
            (data.numInputs >= 1 && data.inputs[0].channelBuffers32) ? &data.inputs[0] : nullptr;
        for (st::int32 c = 0; c < out.numChannels; ++c) {
            float* dst = out.channelBuffers32[c];
            if (!dst) continue;
            const float* src = (in && c < in->numChannels) ? in->channelBuffers32[c] : nullptr;
            if (src) {
                for (st::int32 i = 0; i < data.numSamples; ++i) dst[i] = src[i] * g;
            } else {
                std::memset(dst, 0, sizeof(float) * static_cast<size_t>(data.numSamples));
            }
        }
        out.silenceFlags = in ? 0 : ~0ull;
        return st::kResultOk;
    }
    st::uint32 PLUGIN_API getTailSamples() override { return 0; }

    // IEditController
    st::tresult PLUGIN_API setComponentState(st::IBStream*) override {
        return st::kResultOk;
    }
    // setState/getState 与 IComponent 同签名共用一槽，已在上方实现。
    st::tresult PLUGIN_API setComponentHandler(vst::IComponentHandler*) override {
        return st::kResultOk;
    }
    st::int32 PLUGIN_API getParameterCount() override { return 1; }
    st::tresult PLUGIN_API getParameterInfo(st::int32 index, vst::ParameterInfo& info) override {
        if (index != 0) return st::kInvalidArgument;
        info.id = kGainId;
        copyStr16(info.title, u"Gain");
        copyStr16(info.shortTitle, u"Gain");
        copyStr16(info.units, u"");
        info.stepCount = 0;
        info.defaultNormalizedValue = 0.5;
        info.unitId = 0;  // kRootUnitId
        info.flags = vst::ParameterInfo::kCanAutomate;
        return st::kResultOk;
    }
    st::tresult PLUGIN_API getParamStringByValue(vst::ParamID, vst::ParamValue value,
                                                 vst::String128 string) override {
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%.2f", static_cast<double>(value));
        std::memset(string, 0, sizeof(vst::String128));
        for (int i = 0; buf[i] && i < 127; ++i)
            string[i] = static_cast<st::char16>(buf[i]);
        return st::kResultOk;
    }
    st::tresult PLUGIN_API getParamValueByString(vst::ParamID, st::char16*,
                                                 vst::ParamValue& value) override {
        value = m_gain;
        return st::kResultOk;
    }
    vst::ParamValue PLUGIN_API normalizedParamToPlain(vst::ParamID, vst::ParamValue v) override {
        return v;
    }
    vst::ParamValue PLUGIN_API plainParamToNormalized(vst::ParamID, vst::ParamValue v) override {
        return v;
    }
    vst::ParamValue PLUGIN_API getParamNormalized(vst::ParamID id) override {
        return id == kGainId ? m_gain : 0.0;
    }
    st::tresult PLUGIN_API setParamNormalized(vst::ParamID id, vst::ParamValue v) override {
        if (id != kGainId) return st::kInvalidArgument;
        m_gain = static_cast<float>(v);
        return st::kResultOk;
    }
    st::IPlugView* PLUGIN_API createView(st::FIDString) override {
        return nullptr;  // 无编辑器（门禁只验扫描/加载/处理）
    }

private:
    std::atomic<st::int32> m_ref{1};
    float m_gain = 0.5f;
};

// ---------------------------------------------------------------- 工厂
class ProbeFactory final : public st::IPluginFactory3 {
public:
    st::tresult PLUGIN_API queryInterface(const st::TUID iid, void** obj) override {
        if (!obj) return st::kInvalidArgument;
        *obj = nullptr;
        if (iidEq(iid, st::FUnknown::iid) || iidEq(iid, st::IPluginFactory::iid)) {
            *obj = static_cast<st::IPluginFactory*>(this);
        } else if (iidEq(iid, st::IPluginFactory2::iid)) {
            *obj = static_cast<st::IPluginFactory2*>(this);
        } else if (iidEq(iid, st::IPluginFactory3::iid)) {
            *obj = static_cast<st::IPluginFactory3*>(this);
        } else {
            return st::kNoInterface;
        }
        addRef();
        return st::kResultOk;
    }
    st::uint32 PLUGIN_API addRef() override { return static_cast<st::uint32>(++m_ref); }
    st::uint32 PLUGIN_API release() override {
        st::uint32 n = static_cast<st::uint32>(--m_ref);
        if (n == 0) delete this;
        return n;
    }

    st::tresult PLUGIN_API getFactoryInfo(st::PFactoryInfo* info) override {
        if (!info) return st::kInvalidArgument;
        copyAscii(info->vendor, "AuraDSP Probe");
        copyAscii(info->url, "");
        copyAscii(info->email, "");
        info->flags = st::PFactoryInfo::kNoFlags;
        return st::kResultOk;
    }
    st::int32 PLUGIN_API countClasses() override { return 1; }
    st::tresult PLUGIN_API getClassInfo(st::int32 index, st::PClassInfo* info) override {
        if (index != 0 || !info) return st::kInvalidArgument;
        std::memcpy(info->cid, kProbeCid, sizeof(st::TUID));
        info->cardinality = st::PClassInfo::kManyInstances;
        copyAscii(info->category, kVstAudioEffectClass);
        copyAscii(info->name, "Probe VST3 Gain");
        return st::kResultOk;
    }
    st::tresult PLUGIN_API createInstance(st::FIDString cid, st::FIDString _iid,
                                          void** obj) override {
        if (!obj) return st::kInvalidArgument;
        *obj = nullptr;
        if (std::memcmp(cid, kProbeCid, sizeof(st::TUID)) != 0) return st::kInvalidArgument;  // 无 kNoClass（vendored 头未定义）
        auto* comp = new ProbeComponent();
        const st::TUID& wanted = *reinterpret_cast<const st::TUID*>(_iid);
        st::tresult r = comp->queryInterface(wanted, obj);
        comp->release();  // queryInterface 成功时已为调用方 addRef
        return r;
    }
    // IPluginFactory2
    st::tresult PLUGIN_API getClassInfo2(st::int32 index, st::PClassInfo2* info) override {
        if (index != 0 || !info) return st::kInvalidArgument;
        std::memcpy(info->cid, kProbeCid, sizeof(st::TUID));
        info->cardinality = st::PClassInfo::kManyInstances;
        copyAscii(info->category, kVstAudioEffectClass);
        copyAscii(info->name, "Probe VST3 Gain");
        info->classFlags = 0;
        copyAscii(info->subCategories, "Fx");
        copyAscii(info->vendor, "AuraDSP Probe");
        copyAscii(info->version, "1.0.0");
        copyAscii(info->sdkVersion, "AuraDSP Probe SDK");
        return st::kResultOk;
    }
    // IPluginFactory3
    st::tresult PLUGIN_API getClassInfoUnicode(st::int32 index, st::PClassInfoW* info) override {
        if (index != 0 || !info) return st::kInvalidArgument;
        std::memcpy(info->cid, kProbeCid, sizeof(st::TUID));
        info->cardinality = st::PClassInfo::kManyInstances;
        copyAscii(info->category, kVstAudioEffectClass);
        copyStr16(info->name, u"Probe VST3 Gain");
        info->classFlags = 0;
        copyAscii(info->subCategories, "Fx");
        copyStr16(info->vendor, u"AuraDSP Probe");
        copyStr16(info->version, u"1.0.0");
        copyStr16(info->sdkVersion, u"AuraDSP Probe SDK");
        return st::kResultOk;
    }
    st::tresult PLUGIN_API setHostContext(st::FUnknown*) override { return st::kResultOk; }

private:
    std::atomic<st::int32> m_ref{1};
};

static st::IPluginFactory* g_factory = nullptr;

extern "C" {

#if defined(_WIN32)
#define PROBE_EXPORT __declspec(dllexport)
#else
#define PROBE_EXPORT __attribute__((visibility("default")))
#endif

PROBE_EXPORT bool ModuleEntry(void*) { return true; }
PROBE_EXPORT bool ModuleExit() { return true; }

PROBE_EXPORT st::IPluginFactory* GetPluginFactory() {
    if (!g_factory) g_factory = new ProbeFactory();
    g_factory->addRef();
    return g_factory;
}

}  // extern "C"
