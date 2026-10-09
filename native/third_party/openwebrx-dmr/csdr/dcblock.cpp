/*
Copyright (c) 2019-2023 Jakob Ketterl <jakob.ketterl@gmx.de>

This file is part of libcsdr.

libcsdr is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

libcsdr is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with libcsdr.  If not, see <https://www.gnu.org/licenses/>.
*/

#include "dcblock.hpp"

#include <cmath>

using namespace Csdr;

#define R 0.998f
#define GAIN ((1 + R) / 2)

void DcBlock::process(float *input, float *output, size_t length) {
    for (size_t i = 0; i < length; i++) {
        // dc block filter implementation according to https://www.dsprelated.com/freebooks/filters/DC_Blocker.html
        float x = input[i];
        if (std::isnan(x)) x = 0.0f;
        float y = GAIN * (x - xm1) + R * ym1;
        xm1 = x;
        ym1 = y;
        output[i] = y;
    }
}
