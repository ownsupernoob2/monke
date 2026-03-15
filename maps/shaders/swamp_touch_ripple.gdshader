shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec4 base_color : source_color = vec4(0.08, 0.35, 0.42, 0.68);
uniform vec2 ripple_center_world = vec2(0.0, 0.0);
uniform float ripple_time = 999.0;
uniform float ripple_lifetime = 2.2;
uniform float ripple_speed = 6.0;
uniform float ripple_frequency = 8.0;
uniform float ripple_falloff = 0.45;
uniform float ripple_height = 0.10;

void vertex() {
	float active = 1.0 - smoothstep(ripple_lifetime, ripple_lifetime + 0.2, ripple_time);
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float dist = distance(world_pos.xz, ripple_center_world);
	float wave = sin(dist * ripple_frequency - ripple_time * ripple_speed);
	float attenuation = exp(-dist * ripple_falloff);
	VERTEX.y += wave * attenuation * ripple_height * active;
}

void fragment() {
	ALBEDO = base_color.rgb;
	ALPHA = base_color.a;
	EMISSION = ALBEDO * 0.08;
}
