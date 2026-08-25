#!/usr/bin/env python3
"""Regenerate shaders_spv.h from shaders/*.spv.

    cd Sources/CPebbleVulkan/shaders
    for s in chunk entity ui sky stars celestial cloud; do
      for st in vert frag; do
        glslangValidator -V --target-env vulkan1.0 -o $s.$st.spv $s.$st
      done
    done
    python3 embed.py

The .spv files are checked in, so a build never needs glslangValidator.
"""
import pathlib
import struct
import sys

# emission order — new passes append, so existing blocks keep their offsets
STAGES = [
    "chunk.vert", "chunk.frag",
    "entity.vert", "entity.frag",
    "ui.vert", "ui.frag",
    "sky.vert", "sky.frag",
    "stars.vert", "stars.frag",
    "celestial.vert", "celestial.frag",
    "cloud.vert", "cloud.frag",
    "line.vert", "line.frag",
    "particle.vert", "particle.frag",
    "sprite.vert", "sprite.frag",
    "fs.vert", "bloom_extract.frag", "blur.frag", "composite.frag",
    "shadow.vert",
    "ultra.frag", "ultra_blur.frag",
]

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent / "shaders_spv.h"

parts = [
    "// generated from shaders/*.vert|frag — rebuild with glslangValidator -V",
    "// --target-env vulkan1.0 (see shaders/), then re-run the embed script.",
    "// Do not edit by hand.",
    "#include <stdint.h>",
    "#include <stddef.h>",
    "",
]

for i, stage in enumerate(STAGES):
    blob = (HERE / (stage + ".spv")).read_bytes()
    if len(blob) % 4:
        sys.exit("%s.spv is not a whole number of words" % stage)
    words = struct.unpack("<%dI" % (len(blob) // 4), blob)
    if words[0] != 0x07230203:
        sys.exit("%s.spv has no SPIR-V magic (wrong endianness?)" % stage)
    name = "g_" + stage.replace(".", "_") + "_spv"
    if i:
        parts.append("")
    parts.append("static const uint32_t %s[] = {" % name)
    for row in range(0, len(words), 8):
        parts.append("    " + " ".join("0x%08x," % w for w in words[row:row + 8]))
    parts.append("};")
    parts.append("static const size_t %s_size = sizeof(%s);" % (name, name))

OUT.write_text("\n".join(parts) + "\n")
print("wrote %s (%d stages)" % (OUT, len(STAGES)))
