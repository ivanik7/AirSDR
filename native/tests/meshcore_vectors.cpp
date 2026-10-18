// SPDX-License-Identifier: GPL-3.0-or-later
// Host-only generator of MeshCore on-air packets for the same-IQ oracle.
// Built with OpenSSL, independent of the app's portable crypto, following
// firmware 81dbae5 Mesh::createAdvert / createGroupDatagram and
// Utils::encryptThenMAC. Prints one uppercase hex packet per line:
//   1. signed ADVERT (flood, lat/lon + name)
//   2. GRP_TXT on the firmware Public channel
//   3. ACK
#include <openssl/evp.h>
#include <openssl/hmac.h>

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {
std::vector<uint8_t> hex(const std::string& s) {
  std::vector<uint8_t> v;
  for (size_t i = 0; i < s.size(); i += 2)
    v.push_back(static_cast<uint8_t>(std::stoul(s.substr(i, 2), nullptr, 16)));
  return v;
}
void put32(std::vector<uint8_t>& v, uint32_t x) {
  for (int i = 0; i < 4; ++i) v.push_back(static_cast<uint8_t>(x >> (8 * i)));
}
void print(const std::vector<uint8_t>& v) {
  for (uint8_t b : v) std::printf("%02X", b);
  std::printf("\n");
}
}  // namespace

int main() {
  // ADVERT: RFC 8032 test seed, signature over pubkey || timestamp || appdata.
  const auto seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
  EVP_PKEY* key = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, nullptr, seed.data(), 32);
  if (!key) return 1;
  std::vector<uint8_t> pub(32);
  size_t pub_len = 32;
  if (EVP_PKEY_get_raw_public_key(key, pub.data(), &pub_len) != 1) return 1;
  std::vector<uint8_t> app = {0x91};  // ADV_TYPE_CHAT | ADV_LATLON | ADV_NAME
  put32(app, static_cast<uint32_t>(51169392));   // 51.169392
  put32(app, static_cast<uint32_t>(71449074));   // 71.449074
  for (char c : std::string("Astana")) app.push_back(static_cast<uint8_t>(c));
  std::vector<uint8_t> signed_msg = pub;
  put32(signed_msg, 1792300000u);
  signed_msg.insert(signed_msg.end(), app.begin(), app.end());
  std::vector<uint8_t> sig(64);
  size_t sig_len = 64;
  EVP_MD_CTX* md = EVP_MD_CTX_new();
  if (EVP_DigestSignInit(md, nullptr, nullptr, nullptr, key) != 1 ||
      EVP_DigestSign(md, sig.data(), &sig_len, signed_msg.data(), signed_msg.size()) != 1)
    return 1;
  EVP_MD_CTX_free(md);
  EVP_PKEY_free(key);
  std::vector<uint8_t> advert = {0x11, 0x00};
  advert.insert(advert.end(), signed_msg.begin(), signed_msg.begin() + 36);
  advert.insert(advert.end(), sig.begin(), sig.end());
  advert.insert(advert.end(), app.begin(), app.end());
  print(advert);

  // GRP_TXT on Public: AES-128-ECB(key16) zero padded, HMAC-SHA256(key32)[:2].
  auto channel = hex("8b3387e9c5cdea6ac9e5edbaa115cd72");
  uint8_t digest[32];
  unsigned int dlen = 0;
  EVP_Digest(channel.data(), 16, digest, &dlen, EVP_sha256(), nullptr);
  std::vector<uint8_t> plain;
  put32(plain, 1792300001u);
  plain.push_back(0x00);  // TXT_TYPE_PLAIN, attempt 0
  for (char c : std::string("Ivan: hello MeshCore")) plain.push_back(static_cast<uint8_t>(c));
  plain.resize((plain.size() + 15) / 16 * 16, 0);
  std::vector<uint8_t> cipher(plain.size());
  EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
  int produced = 0;
  if (EVP_EncryptInit_ex(ctx, EVP_aes_128_ecb(), nullptr, channel.data(), nullptr) != 1) return 1;
  EVP_CIPHER_CTX_set_padding(ctx, 0);
  if (EVP_EncryptUpdate(ctx, cipher.data(), &produced, plain.data(),
                        static_cast<int>(plain.size())) != 1) return 1;
  EVP_CIPHER_CTX_free(ctx);
  channel.resize(32, 0);
  uint8_t mac[32];
  HMAC(EVP_sha256(), channel.data(), 32, cipher.data(), cipher.size(), mac, &dlen);
  std::vector<uint8_t> group = {0x15, 0x00, digest[0], mac[0], mac[1]};
  group.insert(group.end(), cipher.begin(), cipher.end());
  print(group);

  print(hex("0D0001020304"));
  return 0;
}
