// SPDX-License-Identifier: GPL-3.0-or-later
// COMPILE SHIM, oracle only: replaces codecserver-softmbe's softmbedevice.hpp
// (which pulls codecserver's device.hpp/protobuf); softmbesession.cpp does
// not use the Device class.
#pragma once
#include "session.hpp"
