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

#ifndef _3RD_PARTY_STEINBERG_VST3_TEST_ITEST_H_
#define _3RD_PARTY_STEINBERG_VST3_TEST_ITEST_H_

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/test/ITestResult.h>

#ifndef kTestClass
#define kTestClass "Test Class" ///< A class for automated tests
#endif

namespace Steinberg
{
    /**
     * ITest interface declaration
     */
    #include <steinberg/vst3/base/WarningsPush.h>
    class ITest: public FUnknown
    {
        public:
            /**
             * Called immediately before the test is actually run.
             * Usually this will be used to setup the test environment.
             * @return true upon success
             */
            virtual bool PLUGIN_API setup() = 0;

            /**
             * execute the test.
             * @param testResult points to a test result where the test can (optionally) add an error message.
             * @return true upon success
             * @see ITestResult
             */
            virtual bool PLUGIN_API run(ITestResult *testResult) = 0;

            /**
             * Called after the test has run. This method shall be used to
             * deconstruct a test environment that has been setup with ITest::setup().
             * @return true upon success
             */
            virtual bool PLUGIN_API teardown() = 0;

            /**
             * This function is used to provide information about the performed
             * testcase. What is done, what is validated and what has to be prepared
             * before executing the test (in case of half-automated tests).
             * @return null-terminated string upon success, zero otherwise
             */
            virtual const char16 * PLUGIN_API getDescription() = 0;

        public:
            static const FUID iid;
    };
    #include <steinberg/vst3/base/WarningsPop.h>

} /* namespace Steinberg */

#endif /* _3RD_PARTY_STEINBERG_VST3_TEST_ITEST_H_ */
