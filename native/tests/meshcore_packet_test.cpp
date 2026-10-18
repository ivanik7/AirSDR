#include "../src/meshcore/meshcore.h"
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>
#include "../third_party/nlohmann/json.hpp"
using nlohmann::json;
using sdrcore::meshcore::PacketParser;
using sdrcore::meshcore::PhyMeta;

static std::vector<uint8_t> hex(std::string s) {
  std::vector<uint8_t> v;
  for (size_t i=0;i<s.size();i+=2) v.push_back(static_cast<uint8_t>(std::stoul(s.substr(i,2),nullptr,16)));
  return v;
}
static json parse(PacketParser& p, const std::vector<uint8_t>& v) {
  PhyMeta m{}; m.timestamp_ms=12345; m.frequency_hz=915000000; m.crc=1; m.sf=7; m.bw_khz=62.5; m.cr=5;
  auto result=p.parse(v.data(),v.size(),m); assert(result); return json::parse(*result);
}
int main() {
  PacketParser p;
  assert(p.configure(R"({"version":1,"settings":{"bandwidth":"6","channels":[]}})"));
  auto ack=parse(p,hex("0D00AABBCCDD"));
  assert(ack["header"]["type_name"]=="ACK" && ack["payload"]["checksum"]==0xDDCCBBAAu);
  assert(ack["phy"]["sf"]==7 && ack["raw"]=="0D00AABBCCDD");
  assert(!p.parse(nullptr,0,PhyMeta{}));
  assert(!p.parse(hex("0D00AABBCCDD").data(),6,PhyMeta{}));
  assert(parse(p,hex("0DFF"))["error"]=="malformed_packet");
  assert(parse(p,hex("0D80"))["error"]=="malformed_packet");
  assert(parse(p,hex("0D410102AABBCCDD"))["path"]["hashes"][0]=="0102");
  std::vector<uint8_t> oversized_path={0x0d,0x9f};
  assert(parse(p,oversized_path)["error"]=="malformed_packet");
  std::vector<uint8_t> oversized_payload(187,0); oversized_payload[0]=0x3d;
  assert(parse(p,oversized_payload)["error"]=="malformed_packet");
  assert(parse(p,hex("4D00AA"))["error"]=="unsupported_version");
  assert(parse(p,hex("0C0102030400A1B2C3D4"))["header"]["transport_codes"][0]==0x0201);
  assert(!p.configure(R"({"version":1,"settings":{"channels":[{"name":"x","secret":"bad"}]}})"));
  // Firmware GroupChannel: SHA256(raw key)[0]; AES-128-ECB zero-pad; HMAC-SHA256(32-byte padded key, ciphertext)[:2].
  assert(p.configure(R"({"version":1,"settings":{"channels":[{"name":"Ops","secret":"000102030405060708090A0B0C0D0E0F"}]}})"));
  auto key=hex("000102030405060708090A0B0C0D0E0F");
  uint8_t digest[32]; unsigned int hlen=0;
  EVP_Digest(key.data(),key.size(),digest,&hlen,EVP_sha256(),nullptr);
  std::vector<uint8_t> plain=hex("0102030400"); plain.insert(plain.end(),{'A',':',' ','h','i'}); plain.resize(16);
  std::vector<uint8_t> cipher(16);
  EVP_CIPHER_CTX* ctx=EVP_CIPHER_CTX_new(); assert(ctx);
  assert(EVP_EncryptInit_ex(ctx,EVP_aes_128_ecb(),nullptr,key.data(),nullptr)==1);
  EVP_CIPHER_CTX_set_padding(ctx,0); int produced=0;
  assert(EVP_EncryptUpdate(ctx,cipher.data(),&produced,plain.data(),16)==1 && produced==16);
  EVP_CIPHER_CTX_free(ctx);
  key.resize(32); uint8_t mac[32];
  HMAC(EVP_sha256(),key.data(),32,cipher.data(),16,mac,&hlen);
  std::vector<uint8_t> group={0x15,0,digest[0],mac[0],mac[1]}; group.insert(group.end(),cipher.begin(),cipher.end());
  auto good=parse(p,group);
  assert(good["payload"]["channel"]=="Ops" && good["payload"]["text"]=="A: hi");
  assert(good["payload"]["sender_timestamp"]==0x04030201);
  assert(good.dump().find("000102030405060708090A0B0C0D0E0F")==std::string::npos);
  assert(p.configure(R"({"version":1,"settings":{"channels":[{"name":"Ops32","secret":"000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"}]}})"));
  auto key32=hex("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F");
  EVP_Digest(key32.data(),key32.size(),digest,&hlen,EVP_sha256(),nullptr);
  group[2]=digest[0];
  HMAC(EVP_sha256(),key32.data(),32,cipher.data(),16,mac,&hlen);
  group[3]=mac[0]; group[4]=mac[1];
  assert(parse(p,group)["payload"]["channel"]=="Ops32");
  group[3]^=1; auto bad=parse(p,group);
  assert(bad["payload"]["encrypted"]==true && !bad["payload"].contains("text"));
  auto truncated=group; truncated.pop_back();
  assert(parse(p,truncated)["error"]=="malformed_packet");
  // Even an empty custom-channel list retains the firmware's published Public channel.
  assert(p.configure(R"({"version":1,"settings":{"channels":[]}})"));
  auto public_key=hex("8b3387e9c5cdea6ac9e5edbaa115cd72");
  EVP_Digest(public_key.data(),16,digest,&hlen,EVP_sha256(),nullptr);
  public_key.resize(32);
  ctx=EVP_CIPHER_CTX_new();
  assert(EVP_EncryptInit_ex(ctx,EVP_aes_128_ecb(),nullptr,public_key.data(),nullptr)==1);
  EVP_CIPHER_CTX_set_padding(ctx,0);
  assert(EVP_EncryptUpdate(ctx,cipher.data(),&produced,plain.data(),16)==1 && produced==16);
  EVP_CIPHER_CTX_free(ctx);
  HMAC(EVP_sha256(),public_key.data(),32,cipher.data(),16,mac,&hlen);
  std::vector<uint8_t> public_frame={0x15,0,digest[0],mac[0],mac[1]};
  public_frame.insert(public_frame.end(),cipher.begin(),cipher.end());
  assert(parse(p,public_frame)["payload"]["channel"]=="Public");
  // RFC8032 seed supplies deterministic Ed25519 key, signed firmware ADVERT envelope.
  auto seed=hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
  EVP_PKEY* private_key=EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519,nullptr,seed.data(),32); assert(private_key);
  std::vector<uint8_t> msg(36); size_t pub_len=32;
  assert(EVP_PKEY_get_raw_public_key(private_key,msg.data(),&pub_len)==1);
  msg[32]=1; msg[33]=2; msg[34]=3; msg[35]=4;
  msg.insert(msg.end(),{0x81,'N','o','d','e'});
  EVP_MD_CTX* sign=EVP_MD_CTX_new(); assert(EVP_DigestSignInit(sign,nullptr,nullptr,nullptr,private_key)==1);
  std::vector<uint8_t> sig(64); size_t sig_len=64;
  assert(EVP_DigestSign(sign,sig.data(),&sig_len,msg.data(),msg.size())==1);
  EVP_MD_CTX_free(sign); EVP_PKEY_free(private_key);
  std::vector<uint8_t> advert={0x11,0}; advert.insert(advert.end(),msg.begin(),msg.begin()+36);
  advert.insert(advert.end(),sig.begin(),sig.end()); advert.insert(advert.end(),msg.begin()+36,msg.end());
  auto trusted=parse(p,advert);
  assert(trusted["payload"]["signature_valid"]==true && trusted["payload"]["advert"]["name"]=="Node");
  advert[40]^=1; auto forged=parse(p,advert);
  assert(forged["payload"]["signature_valid"]==false && !forged["payload"].contains("advert"));
  for (size_t i=0;i<advert.size();++i) {
    std::vector<uint8_t> prefix(advert.begin(),advert.begin()+i);
    if (!prefix.empty()) (void)parse(p,prefix);
  }
  uint32_t state=0x98765432;
  for (int frame=0;frame<2000;++frame) {
    state=state*1664525+1013904223;
    std::vector<uint8_t> random(1+(state%256));
    for (auto& byte:random) { state=state*1664525+1013904223; byte=state>>24; }
    (void)parse(p,random);
  }
  p.reset(); assert(parse(p,public_frame)["payload"]["channel"]=="Public");
  std::cout << "meshcore packet vectors OK\n";
}
