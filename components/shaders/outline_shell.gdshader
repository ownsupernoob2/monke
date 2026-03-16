shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, depth_test_disabled;

uniform vec4 outline_color : source_color = vec4(1.0, 0.2, 0.2, 1.0);
uniform float rim_power = 3.5;
uniform float rim_strength = 1.2;

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	float ndv = clamp(dot(n, v), 0.0, 1.0);
	float rim = pow(1.0 - ndv, rim_power) * rim_strength;
	rim = clamp(rim, 0.0, 1.0);
	ALBEDO = outline_color.rgb;
	EMISSION = outline_color.rgb * rim * 1.2;
	ALPHA = outline_color.a * rim;
	if (ALPHA < 0.03) {
		discard;
	}
}
