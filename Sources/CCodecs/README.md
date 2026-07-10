# CCodecs — vendored image & archive codecs

| Library | Version | License | Source |
|---|---|---|---|
| lodepng | 20260119 | zlib (see header) | https://github.com/lvandeve/lodepng (`lodepng.cpp` renamed `.c`) |
| miniz | 11.0.2 (release 3.0.2) | MIT (`LICENSE-miniz`) | https://github.com/richgel999/miniz/releases/tag/3.0.2 |

Pebble decodes/encodes PNG and reads resource-pack ZIPs with the same code
on every platform (PORTING module 11) — Apple's ImageIO/Compression stay
app-side only. Swift wrappers with size caps live in
`Sources/PebbleCoreBase/Render/PebCodecs.swift`.
