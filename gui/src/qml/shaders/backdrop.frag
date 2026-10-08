#version 440
// P5M background: the navy gradient and two soft glows of Backdrop.qml,
// computed in float and dithered. Drawn into an 8-bit window, a dark
// gradient this long shows bands; a +-1 step of noise hides them.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 viewSize;
    vec4 colorTop;
    vec4 colorBottom;
    vec4 glowA;
    vec4 glowB;
    // Opacity of each glow apart: how a color's alpha reaches the shader
    // (straight or premultiplied) is not something to depend on.
    float alphaA;
    float alphaB;
};

float hash(vec2 p)
{
    p = fract(p * vec2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
}

vec3 glow(vec3 base, vec2 pos, vec2 center, vec4 c, float alpha, float radius)
{
    float a = alpha * (1.0 - clamp(distance(pos, center) / radius, 0.0, 1.0));
    return mix(base, c.rgb, a);
}

void main()
{
    vec2 pos = qt_TexCoord0 * viewSize;
    vec3 col = mix(colorTop.rgb, colorBottom.rgb, qt_TexCoord0.y);
    float radius = max(viewSize.x, viewSize.y) * 0.7;
    col = glow(col, pos, viewSize * vec2(0.15, 0.05), glowA, alphaA, radius);
    col = glow(col, pos, viewSize * vec2(0.9, 0.95), glowB, alphaB, radius);
    // Triangular noise of about one 8-bit step.
    vec2 cell = floor(gl_FragCoord.xy);
    float n = hash(cell) + hash(cell + 71.3) - 1.0;
    col += n / 255.0;
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
