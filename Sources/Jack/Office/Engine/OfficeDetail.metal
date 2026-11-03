#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

/// El suelo y el ladrillo horneados, nítidos de cerca: el atlas horneado (la luz y el color tal como salen de Blender, en
/// `base_color`) por el detalle de la textura original a resolución completa (`custom`) entre su versión del atlas, que es el
/// color sin luz horneado igual (`emissive_color`). Donde el atlas ya tiene el detalle, el cociente vale 1 y no cambia nada.
///
/// La textura original se proyecta como en Blender: por la posición en el modelo, en los dos ejes del plano de la superficie
/// (`custom_parameter`: escala, eje u, eje v).
[[visible]]
void officeDetail(realitykit::surface_parameters params)
{
    constexpr sampler atlas(filter::linear, mip_filter::linear, address::clamp_to_edge);
    constexpr sampler tiled(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));

    // Las UV de USD tienen la v hacia arriba; las texturas de Metal, hacia abajo.
    float2 uv = params.geometry().uv0();
    uv.y = 1.0 - uv.y;
    half3 baked = params.textures().base_color().sample(atlas, uv).rgb;
    half3 flat = params.textures().emissive_color().sample(atlas, uv).rgb;

    float4 projection = params.uniforms().custom_parameter();
    float3 position = params.geometry().model_position();
    float2 coords = float2(position[int(projection.y)], position[int(projection.z)]) * projection.x;
    half3 detail = params.textures().custom().sample(tiled, float2(coords.x, -coords.y)).rgb;

    half3 ratio = clamp(detail / max(flat, half3(0.02h)), half3(0.35h), half3(2.5h));
    params.surface().set_base_color(baked * ratio);
}

