#version 460
// One 16x16 px cell of a 32x32 grid per draw. The cell comes from
// gl_VertexIndex (vertexOffset = 4 * cell); the colour checks that
// gl_DrawID and gl_InstanceIndex (firstInstance = cell) match it.
layout(location = 0) out vec4 color;
layout(push_constant) uniform Params { int base; } params;  // gl_DrawID of the first cell
void main()
{
    int cell = gl_VertexIndex / 4, corner = gl_VertexIndex % 4;
    vec2 pos = vec2(cell % 32, cell / 32) + vec2(corner & 1, corner >> 1) * 0.75 + 0.125;
    gl_Position = vec4(pos / 16.0 - 1.0, 0.0, 1.0);
    bool ok = gl_DrawID + params.base == cell && gl_InstanceIndex == cell;
    color = ok ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0);
}
