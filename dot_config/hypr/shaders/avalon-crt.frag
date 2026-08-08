#version 300 es
precision highp float;

in vec2 v_texcoord;
uniform sampler2D tex;

layout(location = 0) out vec4 fragColor;

// Minimal barrel distortion for a subtle CRT curvature.
// Larger `curvature` = flatter (less bend).
vec2 curveUV(vec2 uv, float curvature) {
    uv = uv * 2.0 - 1.0;
    vec2 offset = abs(uv.yx) / curvature;
    uv = uv + uv * offset * offset;
    uv = uv * 0.5 + 0.5;
    return uv;
}

void main() {
    vec2 uv = curveUV(v_texcoord, 8.0);

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    vec4 texColor = texture(tex, uv);
    vec3 color = texColor.rgb;

    // Subtle scanlines: gently darken every other physical line.
    float scan = mod(gl_FragCoord.y, 2.0) < 1.0 ? 0.96 : 1.0;
    color *= scan;

    // Gentle vignette toward the edges.
    vec2 vigUV = uv * (1.0 - uv.yx);
    float vig = vigUV.x * vigUV.y * 15.0;
    vig = pow(clamp(vig, 0.0, 1.0), 0.25);
    color *= mix(1.0, vig, 0.35);

    fragColor = vec4(color, texColor.a);
}
