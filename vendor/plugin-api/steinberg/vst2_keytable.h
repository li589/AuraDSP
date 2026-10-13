/*
  Copyright 2017 Linux Studio Plugins Project <lsp.plugin@gmail.com>

  Permission to use, copy, modify, and/or distribute this software for any
  purpose with or without fee is hereby granted, provided that the above
  copyright notice and this permission notice appear in all copies.

  THIS SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
*/

#ifndef _3RDPARTY_STEINBERG_VST2_KEYTABLE_H_
#define _3RDPARTY_STEINBERG_VST2_KEYTABLE_H_

#include <stdint.h>
#include "vst2.h"

/**
 * This is VST2.x key table definition of pairs:
 * VST key code and translated into the ASCII character.
 */
static uint8_t keyTable[] =
{
    VKEY_BACK,      0x33,
    VKEY_TAB,       0x30,
    VKEY_RETURN,    0x24,
    VKEY_PAUSE,     0x71,
    VKEY_ESCAPE,    0x35,
    VKEY_SPACE,     0x31,

    VKEY_END,       0x77,
    VKEY_HOME,      0x73,

    VKEY_LEFT,      0x7B,
    VKEY_UP,        0x7E,
    VKEY_RIGHT,     0x7C,
    VKEY_DOWN,      0x7D,
    VKEY_PAGEUP,    0x74,
    VKEY_PAGEDOWN,  0x79,

    VKEY_PRINT,     0x69,
    VKEY_ENTER,     0x4C,
    VKEY_HELP,      0x72,
    VKEY_DELETE,    0x75,
    VKEY_NUMPAD0,   0x52,
    VKEY_NUMPAD1,   0x53,
    VKEY_NUMPAD2,   0x54,
    VKEY_NUMPAD3,   0x55,
    VKEY_NUMPAD4,   0x56,
    VKEY_NUMPAD5,   0x57,
    VKEY_NUMPAD6,   0x58,
    VKEY_NUMPAD7,   0x59,
    VKEY_NUMPAD8,   0x5B,
    VKEY_NUMPAD9,   0x5C,
    VKEY_MULTIPLY,  0x43,
    VKEY_ADD,       0x45,
    VKEY_SUBTRACT,  0x4E,
    VKEY_DECIMAL,   0x41,
    VKEY_DIVIDE,    0x4B,
    VKEY_F1,        0x7A,
    VKEY_F2,        0x78,
    VKEY_F3,        0x63,
    VKEY_F4,        0x76,
    VKEY_F5,        0x60,
    VKEY_F6,        0x61,
    VKEY_F7,        0x62,
    VKEY_F8,        0x64,
    VKEY_F9,        0x65,
    VKEY_F10,       0x6D,
    VKEY_F11,       0x67,
    VKEY_F12,       0x6F,
    VKEY_NUMLOCK,   0x47,
    VKEY_EQUALS,    0x51
};


#endif /* _3RDPARTY_STEINBERG_VST2_KEYTABLE_H_ */
