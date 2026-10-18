#include "meshcore.h"

#include "../../third_party/nlohmann/json.hpp"
extern "C" {
#include "../../third_party/meshcore/sha256.h"
#include "../../third_party/meshcore/monocypher/monocypher-ed25519.h"
#include "../../third_party/crypto-algorithms/aes.h"
}
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <set>

namespace sdrcore::meshcore {
namespace {
using nlohmann::json;

std::string to_hex(const uint8_t* p, size_t n) {
  static constexpr char digits[] = "0123456789ABCDEF";
  std::string s; s.reserve(n * 2);
  for (size_t i=0;i<n;++i) { s += digits[p[i] >> 4]; s += digits[p[i] & 15]; }
  return s;
}
int nibble(char c) {
  if (c>='0' && c<='9') return c-'0';
  if (c>='a' && c<='f') return c-'a'+10;
  if (c>='A' && c<='F') return c-'A'+10;
  return -1;
}
bool decode_hex(const std::string& s, uint8_t* out) {
  if (s.size()%2) return false;
  for (size_t i=0;i<s.size()/2;++i) {
    int hi=nibble(s[2*i]), lo=nibble(s[2*i+1]);
    if (hi<0 || lo<0) return false;
    out[i]=static_cast<uint8_t>((hi<<4)|lo);
  }
  return true;
}
uint32_t le32(const uint8_t* p) {
  return uint32_t(p[0]) | (uint32_t(p[1])<<8) | (uint32_t(p[2])<<16) | (uint32_t(p[3])<<24);
}
uint16_t le16(const uint8_t* p) { return uint16_t(p[0]) | (uint16_t(p[1])<<8); }
const char* type_name(int t) {
  static const char* names[]={"REQ","RESPONSE","TXT_MSG","ACK","ADVERT","GRP_TXT","GRP_DATA","ANON_REQ","PATH","TRACE","MULTIPART","CONTROL","RESERVED","RESERVED","RESERVED","RAW_CUSTOM"};
  return names[t & 15];
}
bool verify_advert(const uint8_t* pub, const uint8_t* signature, const uint8_t* stamp,
                   const uint8_t* app, size_t size) {
  std::array<uint8_t,68> message{};
  std::memcpy(message.data(),pub,32);
  std::memcpy(message.data()+32,stamp,4);
  if (size) std::memcpy(message.data()+36,app,size);
  return crypto_ed25519_check(signature,pub,message.data(),36+size)==0;
}
void sha(const uint8_t* data,size_t size,uint8_t out[32]) {
  SHA256_CTX ctx; sha256_init(&ctx); sha256_update(&ctx,data,size); sha256_final(&ctx,out);
}
void hmac(const std::array<uint8_t,32>& key,const uint8_t* data,size_t size,uint8_t out[32]) {
  uint8_t pad[64];
  for (size_t i=0;i<64;++i) pad[i]=static_cast<uint8_t>((i<32?key[i]:0)^0x36);
  uint8_t inner[32]; SHA256_CTX ctx;
  sha256_init(&ctx); sha256_update(&ctx,pad,64); sha256_update(&ctx,data,size); sha256_final(&ctx,inner);
  for (size_t i=0;i<64;++i) pad[i]=static_cast<uint8_t>((i<32?key[i]:0)^0x5c);
  sha256_init(&ctx); sha256_update(&ctx,pad,64); sha256_update(&ctx,inner,32); sha256_final(&ctx,out);
  std::memset(pad,0,sizeof(pad)); std::memset(inner,0,sizeof(inner));
}
bool decrypt_group(const std::array<uint8_t,32>& key, const uint8_t* mac,
                   const uint8_t* cipher, size_t size, std::vector<uint8_t>& plain) {
  if (!size || size%16) return false;
  uint8_t digest[32]; hmac(key,cipher,size,digest);
  uint8_t diff=(mac[0]^digest[0]) | (mac[1]^digest[1]);
  if (diff) return false;
  plain.resize(size+1,0);
  WORD schedule[44]; aes_key_setup(key.data(),schedule,128);
  for (size_t i=0;i<size;i+=16) aes_decrypt(cipher+i,plain.data()+i,schedule,128);
  std::memset(schedule,0,sizeof(schedule));
  return true;
}
bool hash_key(const uint8_t* key, size_t size, uint8_t& hash) {
  uint8_t digest[32]; sha(key,size,digest);
  hash=digest[0]; return true;
}
// Convert untrusted radio bytes to a JSON-safe string without inventing text.
std::string safe_text(const uint8_t* p, size_t n) {
  std::string s(reinterpret_cast<const char*>(p),n);
  try { json(s).dump(); return s; } catch (const json::type_error&) { return {}; }
}
}  // namespace

bool PacketParser::configure(std::string_view versioned_json) {
  // Failure leaves the previous key set untouched; never include supplied secrets in errors.
  if (versioned_json.size()>8192) return false;
  try {
    auto config=json::parse(versioned_json.begin(),versioned_json.end());
    if (!config.is_object() || !config.contains("version") || !config["version"].is_number_integer() ||
        config["version"]!=1 || !config.contains("settings") || !config["settings"].is_object()) return false;
    auto& settings=config["settings"];
    if (settings.contains("bandwidth") && (!settings["bandwidth"].is_string() ||
        (settings["bandwidth"]!="6" && settings["bandwidth"]!="7" &&
         settings["bandwidth"]!="8" && settings["bandwidth"]!="9"))) return false;
    if (settings.contains("channels") && (!settings["channels"].is_array() || settings["channels"].size()>8)) return false;
    std::vector<Channel> channels;
    const std::string public_key="8b3387e9c5cdea6ac9e5edbaa115cd72";
    Channel pub; pub.name="Public";
    decode_hex(public_key,pub.key.data());
    if (!hash_key(pub.key.data(),16,pub.hash)) return false;
    channels.push_back(pub);
    std::set<std::string> names={"Public"};
    if (settings.contains("channels")) for (const auto& entry:settings["channels"]) {
      if (!entry.is_object() || !entry.contains("name") || !entry["name"].is_string() ||
          !entry.contains("secret") || !entry["secret"].is_string()) return false;
      Channel ch; ch.name=entry["name"].get<std::string>();
      const auto secret=entry["secret"].get<std::string>();
      if (ch.name.empty() || ch.name.size()>32 || !names.insert(ch.name).second ||
          (secret.size()!=32 && secret.size()!=64) || !decode_hex(secret,ch.key.data()) ||
          !hash_key(ch.key.data(),secret.size()/2,ch.hash)) return false;
      channels.push_back(std::move(ch));
    }
    channels_=std::move(channels); return true;
  } catch (const json::exception&) { return false; }
}
// No packet history is retained. Resetting after retune must keep configured keys.
void PacketParser::reset() {}

std::optional<std::string> PacketParser::parse(const uint8_t* packet,size_t length,const PhyMeta& phy) {
  if (phy.crc!=1 || !packet || !length) return std::nullopt;
  json out={{"mode","MeshCore"},{"timestamp",phy.timestamp_ms},{"freq",phy.frequency_hz},
            {"raw",to_hex(packet,std::min(length,size_t{255}))}};
  json physical={{"crc",1}};
  if (phy.sf>0) physical["sf"]=phy.sf;
  if (std::isfinite(phy.bw_khz)) physical["bw"]=phy.bw_khz;
  if (phy.cr>0) physical["cr"]=phy.cr;
  if (std::isfinite(phy.level_db)) physical["level"]=phy.level_db;
  if (std::isfinite(phy.snr_db)) physical["snr"]=phy.snr_db;
  out["phy"]=std::move(physical);
  auto malformed=[&](const char* reason) -> std::optional<std::string> {
    out["error"]=reason; return out.dump();
  };
  if (length>255) return malformed("malformed_packet");
  const uint8_t h=packet[0];
  const int ver=h>>6, route=h&3, type=(h>>2)&15;
  if (ver!=0) return malformed("unsupported_version");
  if (length<2) return malformed("malformed_packet");
  size_t pos=1;
  json header={{"version",1},{"route",route},{"type",type},{"type_name",type_name(type)}};
  if (route==0 || route==3) {
    if (length-pos<4) return malformed("malformed_packet");
    header["transport_codes"]={le16(packet+pos),le16(packet+pos+2)}; pos+=4;
  }
  if (pos>=length) return malformed("malformed_packet");
  uint8_t encoded=packet[pos++];
  size_t hash_size=(encoded>>6)+1, count=encoded&63, bytes=hash_size*count;
  if (hash_size==4 || bytes>64 || bytes>=length-pos || length-pos-bytes>184)
    return malformed("malformed_packet");
  json path={{"hash_size",hash_size},{"hashes",json::array()}};
  for (size_t i=0;i<count;++i) path["hashes"].push_back(to_hex(packet+pos+i*hash_size,hash_size));
  pos+=bytes;
  out["header"]=std::move(header); out["path"]=std::move(path);
  const uint8_t* p=packet+pos; size_t n=length-pos;
  json payload=json::object();
  switch (type) {
    case 3: // ACK: first four bytes are a checksum, later bytes may be retransmission metadata.
      if (n<4) return malformed("malformed_packet");
      payload["checksum"]=le32(p); break;
    case 4: { // ADVERT: signature over pubkey || timestamp || up to 32 appdata bytes.
      if (n<100) return malformed("malformed_packet");
      payload["public_key"]=to_hex(p,32);
      payload["sender_timestamp"]=le32(p+32);
      // Mesh::onRecvPacket caps signed appdata at MAX_ADVERT_DATA_SIZE (32).
      const size_t app_size=std::min(n-100,size_t{32});
      const bool verified=verify_advert(p,p+36,p+32,p+100,app_size);
      payload["signature_valid"]=verified;
      if (verified && app_size) {
        const uint8_t* app=p+100; size_t offset=1;
        uint8_t flags=app[0]; json advert={{"flags",flags}};
        if (flags&0x10) {
          if (app_size<offset+8) break;
          advert["latitude"]=static_cast<int32_t>(le32(app+offset))/1000000.0; offset+=4;
          advert["longitude"]=static_cast<int32_t>(le32(app+offset))/1000000.0; offset+=4;
        }
        if (flags&0x20) { if (app_size<offset+2) break; advert["feature_1"]=le16(app+offset); offset+=2; }
        if (flags&0x40) { if (app_size<offset+2) break; advert["feature_2"]=le16(app+offset); offset+=2; }
        if (flags&0x80) {
          auto name=safe_text(app+offset,app_size-offset);
          if (!name.empty()) advert["name"]=name;
        }
        payload["advert"]=std::move(advert);
      }
      break;
    }
    case 5: case 6: {
      if (n<19 || (n-3)%16) return malformed("malformed_packet");
      payload["channel_hash"]=to_hex(p,1);
      payload["encrypted"]=true;
      for (const auto& channel:channels_) {
        if (channel.hash!=p[0]) continue;
        std::vector<uint8_t> plain;
        if (!decrypt_group(channel.key,p+1,p+3,n-3,plain)) continue;
        if (type==5 && plain.size()>=6 && (plain[4]>>2)==0) {
          const size_t end=std::find(plain.begin()+5,plain.end()-1,0)-plain.begin();
          std::string text=safe_text(plain.data()+5,end-5);
          if (text.empty() && end>5) continue;
          payload["sender_timestamp"]=le32(plain.data());
          payload["text_type"]=plain[4]>>2; payload["attempt"]=plain[4]&3;
          payload["text"]=text;
          payload["channel"]=channel.name; payload["encrypted"]=false;
        } else if (type==6 && plain.size()>=4 && plain[2]<=plain.size()-4) {
          payload["channel"]=channel.name; payload["encrypted"]=false;
          payload["data_type"]=le16(plain.data()); payload["data"]=to_hex(plain.data()+3,plain[2]);
        }
        if (payload["encrypted"]==false) break;
      }
      break;
    }
    case 0: case 1: case 2: case 8:
      if (n<20 || (n-4)%16) return malformed("malformed_packet");
      payload["destination_hash"]=to_hex(p,1); payload["source_hash"]=to_hex(p+1,1);
      payload["encrypted"]=true; break;
    case 7:
      if (n<51 || (n-35)%16) return malformed("malformed_packet");
      payload["destination_hash"]=to_hex(p,1); payload["source_public_key"]=to_hex(p+1,32);
      payload["encrypted"]=true; break;
    default: payload["raw"]=to_hex(p,n); break;
  }
  out["payload"]=std::move(payload);
  return out.dump();
}
}  // namespace sdrcore::meshcore
