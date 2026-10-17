# lorarx (dxlAPRS LoRa receiver) — provenance

- Upstream: OE5DXL author site http://oe5dxl.hamspirit.at:8025/aprs/c/
  (the source OpenWebRX+ packages as `dxlaprs-lora`; the GitHub mirror
  `oe5hpm/dxlAPRS` is an older, divergent version without `-H <n>`/`-j`).
- Fetched 2026-10-18 through headless Chrome (curl to port 8025 times out from
  this host). `lorarx.c` and `loraprotocols.c` match the sha256 values pinned
  in `docs/lora-upstream-feasibility.md`, so two separate fetches (2026-10-11
  and 2026-10-18) agree byte for byte.
- Licence: GPL-2.0-or-later (author `Licenses/README`: GPL v2 "or, at your
  option, any later version"; `Licenses/Exceptions`: no exclusions). This is
  compatible with the project's GPL-3.0.
- No build is wired yet. These files are vendored verbatim and unmodified.

## Layout

- Top level: the decoder translation units an embed needs (`lorarx.c`,
  `loraprotocols.c/.h`, `aprsstr.c/.h`, `X2C.h`) plus `loratx.c`, the
  upstream synthetic-IQ generator, kept for PHY fixtures.
- `upstream-os/`: the upstream OS/IO layer (`osi`, `osic`, `udp`, `tcp.h`,
  `mlib.h`). It is used only to build the unmodified reference (oracle)
  binary. An embedded build must replace it with an in-process shim.
- `Licenses/`: the author's licence README, Exceptions and GPL-2.0 text.

## sha256 (verbatim upstream bytes)

    e7c49ac8d0545b32d88f4ef66a0bfc35a0a74521feecbe37117f10d35f9d5eef  lorarx.c
    775b92dcaeb68c1a6c21f48b53244164c55ad4ebd050d9880b5c37aa76e515e0  loraprotocols.c
    a1736273089c5a5a0fc5ae27658f9b467b963e13be939c9caa418be6df8d5470  loraprotocols.h
    05ca117e8ab376311d8e4257440da4301dfeb35d3141c59acfcbb8b4fa5d7712  aprsstr.c
    62843c14548f7eee0df040cb7742f0b32ae5a678b3ae814632c082977ed1c445  aprsstr.h
    dd78d7f4fd0b4005d42a031221c48faa9827d0653b2e747d8d91002392e4909a  X2C.h
    31adca10e74022e6a8ceccd6bdb7c93e9913e6508f83fa9ef4108f894a37b041  loratx.c
    d5a234bf5a90e0908bb14111be5cfc2a69d327213486f5a1d1f92ad80003a47e  upstream-os/mlib.h
    0f172995196196063517329b0ad15f06501cb42c8c5a537d2e8485178d145d13  upstream-os/osi.c
    d4ca0b8a84875dd706591666b96ba34866d50d640a7d2fc3ed40dd5addd28bde  upstream-os/osi.h
    b10e148dfce148a2ed86e6116931d1343d334a9e8a7efeaca58f6db70a1309e4  upstream-os/osic.c
    7040b6d653c3c24152dfc83640f79816bd2414c461e7a4c9850a4409a6fd528e  upstream-os/osic.h
    b83da4df8137a79e39113e45dfd52c3a7c25e24c8ff44176028ff7ea670b4ba7  upstream-os/tcp.h
    cff7523bd4844bb9ac6bc9e4b6fdc5fc27553f7ed467f241bc4ae4de4df994db  upstream-os/udp.c
    9ce549cecce3d33bc22daeaafd1568e68b884327ef967010818d2739ec0c67d4  upstream-os/udp.h
    46018d0398927401d9fdc137b3da5f6de33615b1925b55927039381046b499a1  Licenses/README
    c89b5fbce0c893e8a4029e77a05ff5297c880282affa1453fe2916cc16f83c6f  Licenses/Exceptions
    8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643  Licenses/gpl-2.0.txt

## Reference (oracle) build, verified on the Linux host

    gcc -I. -Iupstream-os -O3 -w -c {lorarx,loraprotocols,aprsstr}.c upstream-os/{osi,osic,udp}.c
    gcc -o lorarx lorarx.o loraprotocols.o aprsstr.o osi.o osic.o udp.o -lm

The author-site Makefile also links `Select/tcp/aprspos/soundctl`, but those
are not needed for lorarx: the link above resolves without them.

For a LongFast-like loratx IQ file (`-b 8 -s 11 -c 5 -N 2B`, payload =
`native/tests/data/meshtastic_vectors.json` group 0 packet 0), this build with
the exact OpenWebRX+ command emits `crc:1 sf:11 cr:5 bw:250000.0` and the
input payload. The packaged PPA binary (1.0.20260515) emits the same values,
but its JSON lacks `eyemin`, `snrmin`, `firlen`, `notches` and `chirps`:
the author site has moved past the PPA build. Parity therefore targets these
vendored sources, not the PPA binary.
