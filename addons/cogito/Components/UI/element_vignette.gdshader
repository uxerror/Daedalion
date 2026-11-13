shader_type canvas_item;
// Screen-edge vignette for element states (CogitoElementStatusHud). The centre stays clear.

uniform vec4 tint : source_color = vec4(1.0, 0.5, 0.1, 1.0);
// Overall strength, faded in and out by the HUD.
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
// 0..1: fast random-ish flicker (fire).
uniform float flicker : hint_range(0.0, 1.0) = 0.0;
// 0..1: slow pulse (poison).
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
// Where the vignette starts and where it is fully opaque, as distance from the centre (0.5 = edge midpoints).
uniform float inner_radius = 0.42;
uniform float outer_radius = 0.85;

void fragment() {
	vec2 uv = UV - vec2(0.5);
	float dist = length(uv * vec2(1.0, 0.85));
	float edge = smoothstep(inner_radius, outer_radius, dist);
	float wobble = 1.0;
	wobble *= mix(1.0, 0.75 + 0.25 * sin(TIME * 17.0 + sin(TIME * 5.3) * 3.0), flicker);
	wobble *= mix(1.0, 0.6 + 0.4 * sin(TIME * 3.0), pulse);
	COLOR = vec4(tint.rgb, tint.a * edge * intensity * wobble);
}
