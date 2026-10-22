#include <flutter/runtime_effect.glsl>

// ImageFilter.shader supplies these first two floats and the first sampler.
uniform vec2 u_size;
uniform float u_roundness;
uniform float u_strength;
uniform float u_phase;
uniform vec2 u_light;
uniform sampler2D u_backdrop;

out vec4 frag_color;

float roundedDistance(vec2 p, vec2 halfSize, float radius) {
  vec2 q = abs(p) - halfSize + radius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

vec2 safeUv(vec2 point) {
  vec2 uv = clamp(point / u_size, 0.5 / u_size, 1.0 - 0.5 / u_size);
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

void main() {
  vec2 point = FlutterFragCoord().xy;
  vec2 halfSize = u_size * 0.5;
  float shortSide = max(min(u_size.x, u_size.y), 1.0);
  float radius = clamp(u_roundness * shortSide, 0.0, shortSide * 0.5);
  vec2 centered = point - halfSize;
  float distance = roundedDistance(centered, halfSize, radius);
  // The edge acts as a shallow lens; the centre stays clear for readability.
  vec2 normal = vec2(
    roundedDistance(centered + vec2(1.0, 0.0), halfSize, radius) -
      roundedDistance(centered - vec2(1.0, 0.0), halfSize, radius),
    roundedDistance(centered + vec2(0.0, 1.0), halfSize, radius) -
      roundedDistance(centered - vec2(0.0, 1.0), halfSize, radius)
  );
  normal /= max(length(normal), 0.001);
  float edge = 1.0 - smoothstep(0.0, shortSide * 0.16, max(-distance, 0.0));
  float amplitude = min(shortSide * 0.045, 9.0) * u_strength;
  vec2 lens = -normal * edge * edge * amplitude;
  vec2 uv = point / u_size;
  float pulse = sin(u_phase * 3.14159265);
  vec2 wave = vec2(
    sin(uv.y * 6.2831853 + u_phase * 2.0),
    cos(uv.x * 6.2831853 - u_phase * 2.0)
  ) * amplitude * (0.08 + 0.16 * pulse);
  vec2 lightPull = (u_light - uv) * amplitude * pulse * 0.12;
  vec2 source = point + lens + wave + lightPull;
  // Clamp every sample to the backdrop instead of sampling transparent black.
  vec4 centre = texture(u_backdrop, safeUv(source));
  float red = texture(u_backdrop, safeUv(source + lens * 0.035)).r;
  float blue = texture(u_backdrop, safeUv(source - lens * 0.035)).b;
  frag_color = vec4(min(vec3(red, centre.g, blue), vec3(centre.a)), centre.a);
}
