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

#ifndef _3RD_PARTY_STEINBERG_VST3_VST_TEST_H_
#define _3RD_PARTY_STEINBERG_VST3_VST_TEST_H_

#include <steinberg/vst3/test.h>

namespace Steinberg
{
    DEF_CLASS_IID(ITest, 0xFE64FC19, 0x95684F53, 0xAAA78DC8, 0x7228338E)
    DEF_CLASS_IID(ITestFactory, 0xAB483D3A, 0x15264650, 0xBF86EEF6, 0x9A327A93)
    DEF_CLASS_IID(ITestResult, 0x69796279, 0xF651418B, 0xB24D79B7, 0xD7C527F4)
    DEF_CLASS_IID(ITestSuite, 0x5CA7106F, 0x98784AA5, 0xB4D30D71, 0x2F5F1498)

} /* namespace Steinberg */



#endif /* _3RD_PARTY_STEINBERG_VST3_VST_TEST_H_ */
