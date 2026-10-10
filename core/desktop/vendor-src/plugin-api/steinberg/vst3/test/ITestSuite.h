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

#ifndef _3RD_PARTY_STEINBERG_VST3_TEST_ITESTSUITE_H_
#define _3RD_PARTY_STEINBERG_VST3_TEST_ITESTSUITE_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/test/ITest.h>

namespace Steinberg
{
    /**
     * A collection of tests supporting a hierarchical ordering
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class ITestSuite: public FUnknown
    {
        public:
            /**
             * Append a new test
             */
            virtual tresult PLUGIN_API addTest(FIDString name, ITest *test) = 0;

            /**
             * Append an entire test suite as a child suite
             */
            virtual tresult PLUGIN_API addTestSuite(FIDString name, ITestSuite *testSuite) = 0;

            virtual tresult PLUGIN_API setEnvironment(ITest *environment) = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_TEST_ITESTSUITE_H_ */
