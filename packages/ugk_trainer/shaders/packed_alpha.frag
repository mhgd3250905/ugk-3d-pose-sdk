// The engine supplies the complete packed input: first vec2 and sampler.
// See pinned Flutter ImageFilter.shader and packed_alpha_sources.md.
#include <flutter/runtime_effect.glsl>

uniform vec2 u_input_size;
uniform sampler2D u_packed;
out vec4 frag_color;

void main() {
  vec2 uv = FlutterFragCoord().xy / u_input_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec2 half_texel = vec2(0.5) / u_input_size;
  float x = clamp(uv.x, half_texel.x, 1.0 - half_texel.x);
  float y = clamp(uv.y * 0.5, half_texel.y, 0.5 - half_texel.y);
  vec3 rgb = texture(u_packed, vec2(x, y)).rgb;
  float alpha = clamp(texture(u_packed, vec2(x, y + 0.5)).r, 0.0, 1.0);
  // Flutter's output is premultiplied. The outer matrix filter halves the
  // composed result's height, AFTER both full-resolution source halves.
  frag_color = vec4(rgb * alpha, alpha);
}
