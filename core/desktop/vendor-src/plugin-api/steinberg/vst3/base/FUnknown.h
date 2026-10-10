/*
 * Copyright 2023, Steinberg Media Technologies GmbH, All Rights Reserved
 * Copyright 2023 Linux Studio Plugins Project <lsp.plugin@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef _3RDPARTY_STEINBERG_VST3_BASE_FUNKNOWN_H_
#define _3RDPARTY_STEINBERG_VST3_BASE_FUNKNOWN_H_

#include <steinberg/vst3/base/Platform.h>
#include <steinberg/vst3/base/FUID.h>
#include <steinberg/vst3/base/Types.h>

#include <cstring>
#include <utility>

#if SMTG_CPP11_STDLIBSUPPORT
    #include <type_traits>
#endif /* SMTG_CPP11_STDLIBSUPPORT */

//------------------------------------------------------------------------
//  FUnknown implementation macros
//------------------------------------------------------------------------

#define DECLARE_FUNKNOWN_METHODS                                                                            \
    public:                                                                                                 \
        virtual ::Steinberg::tresult PLUGIN_API queryInterface (const ::Steinberg::TUID _iid, void** obj) SMTG_OVERRIDE; \
        virtual ::Steinberg::uint32 PLUGIN_API addRef () SMTG_OVERRIDE;                                     \
        virtual ::Steinberg::uint32 PLUGIN_API release () SMTG_OVERRIDE;                                    \
    protected:                                                                                              \
        ::Steinberg::int32 __funknownRefCount;                                                              \
    public:

//------------------------------------------------------------------------

#define DELEGATE_REFCOUNT(ClassName)                                                    \
    public:                                                                                    \
        virtual ::Steinberg::uint32 PLUGIN_API addRef() SMTG_OVERRIDE  { return ClassName::addRef ();  }    \
        virtual ::Steinberg::uint32 PLUGIN_API release() SMTG_OVERRIDE { return ClassName::release (); }

//------------------------------------------------------------------------
#define IMPLEMENT_REFCOUNT(ClassName)                                               \
    ::Steinberg::uint32 PLUGIN_API ClassName::addRef()                              \
    {                                                                               \
        return ::Steinberg::FUnknownPrivate::atomicAdd(__funknownRefCount, 1);      \
    }                                                                               \
    ::Steinberg::uint32 PLUGIN_API ClassName::release()                             \
    {                                                                               \
        if (::Steinberg::FUnknownPrivate::atomicAdd(__funknownRefCount, -1) == 0)   \
        {                                                                           \
            delete this;                                                            \
            return 0;                                                               \
        }                                                                           \
        return __funknownRefCount;                                                  \
    }

//------------------------------------------------------------------------
#define FUNKNOWN_CTOR   { __funknownRefCount = 1; }

#if defined(SMTG_FUNKNOWN_DTOR_ASSERT) && SMTG_FUNKNOWN_DTOR_ASSERT
    #include <cassert>
    #define FUNKNOWN_DTOR { assert (__funknownRefCount == 0); }
#else
    #define FUNKNOWN_DTOR
#endif

#define QUERY_INTERFACE(iid, obj, InterfaceIID, InterfaceName)  \
    if (::Steinberg::FUnknownPrivate::iidEqual (iid, InterfaceIID)) \
    {                                                               \
        addRef();                                                   \
        *obj = static_cast< InterfaceName* >(this);                 \
        return ::Steinberg::kResultOk;                              \
    }

#define IMPLEMENT_QUERYINTERFACE(ClassName, InterfaceName, ClassIID)                                \
    ::Steinberg::tresult PLUGIN_API ClassName::queryInterface (const ::Steinberg::TUID _iid, void** obj)\
    {                                                                                                   \
        QUERY_INTERFACE (_iid, obj, ::Steinberg::FUnknown::iid, InterfaceName)                          \
        QUERY_INTERFACE (_iid, obj, ClassIID, InterfaceName)                                            \
        *obj = nullptr;                                                                                 \
        return ::Steinberg::kNoInterface;                                                               \
    }

#define IMPLEMENT_FUNKNOWN_METHODS(ClassName,InterfaceName,ClassIID) \
    IMPLEMENT_REFCOUNT (ClassName)                                   \
    IMPLEMENT_QUERYINTERFACE (ClassName, InterfaceName, ClassIID)

namespace Steinberg
{
    /**
     * The basic interface of all interfaces.
     *   - The FUnknown::queryInterface method is used to retrieve pointers to other
     *     interfaces of the object.
     *   - FUnknown::addRef and FUnknown::release manage the lifetime of the object.
     *     If no more references exist, the object is destroyed in memory.
     *
     *     Interfaces are identified by 16 byte Globally Unique Identifiers.
     *     The SDK provides a class called FUID for this purpose.
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class FUnknown
    {
        public:
            /**
             * Query for a pointer to the specified interface.
             * @return kResultOk on success or kNoInterface if the object does not implement the interface.
             * The object has to call addRef when returning an interface.
             * @param _iid : (in) 16 Byte interface identifier (-> FUID)
             * @param obj : (out) On return, *obj points to the requested interface */
            virtual tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) = 0;

            /** Adds a reference and returns the new reference count.
             * @note The initial reference count after creating an object is 1.
             */
            virtual uint32 PLUGIN_API addRef() = 0;

            /** Releases a reference and returns the new reference count.
             * @note If the reference count reaches zero, the object will be destroyed in memory.
             */
            virtual uint32 PLUGIN_API release() = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#endif /* _3RDPARTY_STEINBERG_VST3_BASE_FUNKNOWN_H_ */

