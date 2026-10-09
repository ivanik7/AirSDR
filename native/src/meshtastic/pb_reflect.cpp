// SPDX-License-Identifier: GPL-3.0-or-later
#include "pb_reflect.h"

#include <meshtastic/mesh.pb.h>
#include <meshtastic/paxcount.pb.h>
#include <meshtastic/portnums.pb.h>
#include <meshtastic/remote_hardware.pb.h>
#include <meshtastic/storeforward.pb.h>
#include <meshtastic/telemetry.pb.h>

#include <cstring>

namespace sdrcore::meshtastic::pbjson {
namespace {

#define SDR_KIND_BOOL Kind::boolean
#define SDR_KIND_INT32 Kind::sint
#define SDR_KIND_SINT32 Kind::sint
#define SDR_KIND_SFIXED32 Kind::sint
#define SDR_KIND_UINT32 Kind::uint
#define SDR_KIND_FIXED32 Kind::uint
#define SDR_KIND_INT64 Kind::sint64
#define SDR_KIND_SINT64 Kind::sint64
#define SDR_KIND_SFIXED64 Kind::sint64
#define SDR_KIND_UINT64 Kind::uint64
#define SDR_KIND_FIXED64 Kind::uint64
#define SDR_KIND_FLOAT Kind::f32
#define SDR_KIND_DOUBLE Kind::f64
#define SDR_KIND_ENUM Kind::enumeration
#define SDR_KIND_UENUM Kind::enumeration
#define SDR_KIND_STRING Kind::string
#define SDR_KIND_BYTES Kind::bytes
#define SDR_KIND_FIXED_LENGTH_BYTES Kind::fixed_bytes
#define SDR_KIND_MESSAGE Kind::message
#define SDR_KIND_MSG_W_CB Kind::message

// Oneof members are spelled "(union,member,fullname)" in FIELDLIST; the
// member name is extracted in init_tables() below. Tables use a _jfields
// suffix because nanopb already defines <msg>_fields as a macro.
#define SDR_FIELD(a, atype, htype, ltype, fieldname, tag) \
  {tag, #fieldname, SDR_KIND_##ltype, nullptr},

#define SDR_ENUM_NAMER(fn, type)                                           \
  const char* fn(int64_t v) {                                              \
    if (v < static_cast<int64_t>(_##type##_MIN) ||                         \
        v > static_cast<int64_t>(_##type##_MAX))                           \
      return nullptr;                                                      \
    const char* n = type##_name(static_cast<type>(v));                     \
    return (n && std::strcmp(n, "unknown") != 0) ? n : nullptr;            \
  }

SDR_ENUM_NAMER(loc_source, meshtastic_Position_LocSource)
SDR_ENUM_NAMER(alt_source, meshtastic_Position_AltSource)
SDR_ENUM_NAMER(hw_model, meshtastic_HardwareModel)
SDR_ENUM_NAMER(role, meshtastic_Config_DeviceConfig_Role)
SDR_ENUM_NAMER(routing_error, meshtastic_Routing_Error)
SDR_ENUM_NAMER(portnum, meshtastic_PortNum)
SDR_ENUM_NAMER(sf_rr, meshtastic_StoreAndForward_RequestResponse)
SDR_ENUM_NAMER(hw_msg_type, meshtastic_HardwareMessage_Type)

#define SDR_TABLE(type) \
  FieldInfo type##_jfields[] = {type##_FIELDLIST(SDR_FIELD, type)};

SDR_TABLE(meshtastic_Position)
SDR_TABLE(meshtastic_User)
SDR_TABLE(meshtastic_RouteDiscovery)
SDR_TABLE(meshtastic_Routing)
SDR_TABLE(meshtastic_Data)
SDR_TABLE(meshtastic_Waypoint)
SDR_TABLE(meshtastic_BoundingBox)
SDR_TABLE(meshtastic_NeighborInfo)
SDR_TABLE(meshtastic_Neighbor)
SDR_TABLE(meshtastic_Telemetry)
SDR_TABLE(meshtastic_DeviceMetrics)
SDR_TABLE(meshtastic_EnvironmentMetrics)
SDR_TABLE(meshtastic_AirQualityMetrics)
SDR_TABLE(meshtastic_PowerMetrics)
SDR_TABLE(meshtastic_LocalStats)
SDR_TABLE(meshtastic_HealthMetrics)
SDR_TABLE(meshtastic_HostMetrics)
SDR_TABLE(meshtastic_TrafficManagementStats)
SDR_TABLE(meshtastic_SoilWaterMetrics)
SDR_TABLE(meshtastic_Paxcount)
SDR_TABLE(meshtastic_StoreAndForward)
SDR_TABLE(meshtastic_StoreAndForward_Statistics)
SDR_TABLE(meshtastic_StoreAndForward_History)
SDR_TABLE(meshtastic_StoreAndForward_Heartbeat)
SDR_TABLE(meshtastic_HardwareMessage)

#define SDR_INFO(type, full)                                              \
  {&type##_msg, full, type##_jfields,                                     \
   sizeof(type##_jfields) / sizeof(type##_jfields[0]), sizeof(type)},

MessageInfo g_messages[] = {
    SDR_INFO(meshtastic_Position, "meshtastic.Position")
    SDR_INFO(meshtastic_User, "meshtastic.User")
    SDR_INFO(meshtastic_RouteDiscovery, "meshtastic.RouteDiscovery")
    SDR_INFO(meshtastic_Routing, "meshtastic.Routing")
    SDR_INFO(meshtastic_Data, "meshtastic.Data")
    SDR_INFO(meshtastic_Waypoint, "meshtastic.Waypoint")
    SDR_INFO(meshtastic_BoundingBox, "meshtastic.BoundingBox")
    SDR_INFO(meshtastic_NeighborInfo, "meshtastic.NeighborInfo")
    SDR_INFO(meshtastic_Neighbor, "meshtastic.Neighbor")
    SDR_INFO(meshtastic_Telemetry, "meshtastic.Telemetry")
    SDR_INFO(meshtastic_DeviceMetrics, "meshtastic.DeviceMetrics")
    SDR_INFO(meshtastic_EnvironmentMetrics, "meshtastic.EnvironmentMetrics")
    SDR_INFO(meshtastic_AirQualityMetrics, "meshtastic.AirQualityMetrics")
    SDR_INFO(meshtastic_PowerMetrics, "meshtastic.PowerMetrics")
    SDR_INFO(meshtastic_LocalStats, "meshtastic.LocalStats")
    SDR_INFO(meshtastic_HealthMetrics, "meshtastic.HealthMetrics")
    SDR_INFO(meshtastic_HostMetrics, "meshtastic.HostMetrics")
    SDR_INFO(meshtastic_TrafficManagementStats, "meshtastic.TrafficManagementStats")
    SDR_INFO(meshtastic_SoilWaterMetrics, "meshtastic.SoilWaterMetrics")
    SDR_INFO(meshtastic_Paxcount, "meshtastic.Paxcount")
    SDR_INFO(meshtastic_StoreAndForward, "meshtastic.StoreAndForward")
    SDR_INFO(meshtastic_StoreAndForward_Statistics, "meshtastic.StoreAndForward.Statistics")
    SDR_INFO(meshtastic_StoreAndForward_History, "meshtastic.StoreAndForward.History")
    SDR_INFO(meshtastic_StoreAndForward_Heartbeat, "meshtastic.StoreAndForward.Heartbeat")
    SDR_INFO(meshtastic_HardwareMessage, "meshtastic.HardwareMessage")
};

struct EnumBinding {
  const pb_msgdesc_t* desc;
  const char* field;
  EnumName fn;
};

const EnumBinding kEnums[] = {
    {&meshtastic_Position_msg, "location_source", loc_source},
    {&meshtastic_Position_msg, "altitude_source", alt_source},
    {&meshtastic_User_msg, "hw_model", hw_model},
    {&meshtastic_User_msg, "role", role},
    {&meshtastic_Routing_msg, "error_reason", routing_error},
    {&meshtastic_Data_msg, "portnum", portnum},
    {&meshtastic_StoreAndForward_msg, "rr", sf_rr},
    {&meshtastic_HardwareMessage_msg, "type", hw_msg_type},
};

// Member-name storage for oneof spellings; sized for the longest name.
char g_oneof_names[64][48];

bool init_tables() {
  size_t used = 0;
  for (auto& m : g_messages) {
    for (size_t i = 0; i < m.field_count; ++i) {
      auto& f = const_cast<FieldInfo&>(m.fields[i]);
      if (f.name[0] == '(') {
        const char* first = std::strchr(f.name, ',');
        const char* second = first ? std::strchr(first + 1, ',') : nullptr;
        if (!second || used >= 64) continue;
        size_t len = static_cast<size_t>(second - first - 1);
        if (len >= sizeof(g_oneof_names[0])) continue;
        std::memcpy(g_oneof_names[used], first + 1, len);
        g_oneof_names[used][len] = '\0';
        f.name = g_oneof_names[used++];
      }
      if (f.kind == Kind::enumeration) {
        for (const auto& e : kEnums)
          if (e.desc == m.desc && std::strcmp(e.field, f.name) == 0)
            f.enum_name = e.fn;
      }
    }
  }
  return true;
}

void ensure_init() {
  static const bool done = init_tables();
  (void)done;
}

}  // namespace

const MessageInfo* find_message(const pb_msgdesc_t* desc) {
  ensure_init();
  for (const auto& m : g_messages)
    if (m.desc == desc) return &m;
  return nullptr;
}

const MessageInfo* all_messages(size_t* count) {
  ensure_init();
  if (count) *count = sizeof(g_messages) / sizeof(g_messages[0]);
  return g_messages;
}

}  // namespace sdrcore::meshtastic::pbjson
