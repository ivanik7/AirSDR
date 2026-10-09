// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reflection tables for the nanopb-generated Meshtastic messages that the
// packet layer turns into JSON. nanopb keeps no field names or proto scalar
// types at run time, so they are recovered at compile time from the
// generated <msg>_FIELDLIST X-macros. JSON output follows protobuf's Python
// json_format.MessageToDict(preserving_proto_field_name=True), which is what
// OpenWebRX+ owrx/meshtastic.py emits.
#pragma once

#include <cstddef>
#include <cstdint>

#include <pb.h>

namespace sdrcore::meshtastic::pbjson {

enum class Kind : uint8_t {
  boolean, sint, uint, sint64, uint64, f32, f64, enumeration, string, bytes,
  fixed_bytes, message, unsupported
};

using EnumName = const char* (*)(int64_t);

struct FieldInfo {
  uint32_t tag;
  const char* name;
  Kind kind;
  EnumName enum_name;  // only for Kind::enumeration
};

struct MessageInfo {
  const pb_msgdesc_t* desc;
  const char* full_name;
  const FieldInfo* fields;
  size_t field_count;
  size_t struct_size;  // sizeof the generated C struct
};

// All messages reachable from the decoded application payloads.
const MessageInfo* find_message(const pb_msgdesc_t* desc);
const MessageInfo* all_messages(size_t* count);

}  // namespace sdrcore::meshtastic::pbjson
