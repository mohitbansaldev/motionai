// CHROMA (Agent M): green / blue screen keyer.
// Same maths as ChromaMath in lib/core/engine/chroma.dart (keep in sync).
// Drawn as a full rect over an offscreen picture of exactly uSize pixels,
// so FlutterFragCoord() is the pixel position on Skia and Impeller.
#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;      // 0,1   image size (px)
uniform vec3 uKey;       // 2..4  key colour 0..1
uniform float uT0;       // 5     smoothstep start (tolerance)
uniform float uWidth;    // 6     smoothstep width (softness)
uniform float uSpill;    // 7     spill suppression 0..1
uniform float uChoke;    // 8     choke radius px (+ shrink, - grow)
uniform float uGain;     // 9     matte contrast gain (>= 1)
uniform float uView;     // 10    0 = keyed picture, 1 = matte
uniform sampler2D uImage;

out vec4 fragColor;

vec2 chroma(vec3 c) {
  return vec2(dot(c, vec3(-0.168736, -0.331264, 0.5)), dot(c, vec3(0.5, -0.418688, -0.081312)));
}

vec3 unpremul(vec4 p) {
  return p.a > 0.0001 ? p.rgb / p.a : vec3(0.0);
}

float keyAlpha(vec3 rgb, vec2 khat, float kl) {
  vec2 c = chroma(rgb);
  float u = dot(c, khat) / kl;
  float v = abs(c.x * khat.y - c.y * khat.x) / kl;
  float ang = u > 0.001 ? v / u : 1000.0;
  float d = max(ang, (1.0 - u) * 0.7);
  return smoothstep(uT0, uT0 + uWidth, d);
}

float alphaAt(vec2 uv, vec2 khat, float kl) {
  return keyAlpha(unpremul(texture(uImage, clamp(uv, vec2(0.0), vec2(1.0)))), khat, kl);
}

// One exit only: samplers + several `return`s in main() can crash the
// Windows (SkSL/ANGLE) compiler (flutter/flutter#190809).
void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec4 src = texture(uImage, uv);
  vec3 rgb = unpremul(src);
  vec2 k = chroma(uKey);
  float kl = length(k);
  vec4 outColor = src;
  if (kl < 0.0001) {
    // A grey key colour keys nothing.
    if (uView > 0.5) outColor = vec4(vec3(src.a), 1.0);
  } else {
    vec2 khat = k / kl;
    float a = keyAlpha(rgb, khat, kl);

    float r = abs(uChoke);
    if (r > 0.01) {
      vec2 px = vec2(r) / uSize;
      float m = a;
      for (int i = 0; i < 8; i++) {
        float t = float(i) * 0.7853982;
        float s = alphaAt(uv + vec2(cos(t), sin(t)) * px, khat, kl);
        m = uChoke > 0.0 ? min(m, s) : max(m, s);
      }
      for (int i = 0; i < 4; i++) {
        float t = float(i) * 1.5707964;
        float s = alphaAt(uv + vec2(cos(t), sin(t)) * px * 0.5, khat, kl);
        m = uChoke > 0.0 ? min(m, s) : max(m, s);
      }
      a = m;
    }
    if (uGain != 1.0) a = clamp((a - 0.5) * uGain + 0.5, 0.0, 1.0);
    float fa = a * src.a;

    if (uView > 0.5) {
      outColor = vec4(vec3(fa), 1.0);
    } else {
      if (uSpill > 0.0) {
        vec2 c = chroma(rgb);
        float along = dot(c, khat);
        if (along > 0.0) {
          float y = dot(rgb, vec3(0.299, 0.587, 0.114));
          c -= khat * along * uSpill;
          rgb = clamp(vec3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x), 0.0, 1.0);
        }
      }
      outColor = vec4(rgb * fa, fa);
    }
  }
  fragColor = outColor;
}
