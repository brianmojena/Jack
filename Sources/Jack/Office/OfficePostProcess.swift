import Metal
import RealityKit
import simd

/// El acabado de la oficina tras el render de RealityKit, para acercarla a un render con trazado de rayos:
/// oclusión ambiental en pantalla (los rincones, el contacto de los muebles con el suelo y los pliegues se oscurecen
/// como con luz rebotada), un poco de contraste y color, y un viñeteado suave.
@available(macOS 26.0, *)
struct OfficePostProcess: PostProcessEffect {
    /// Las tuberías se compilan una vez por dispositivo; la textura de oclusión se rehace si cambia el tamaño.
    private final class State: @unchecked Sendable {
        var occlusion: [Bool: MTLComputePipelineState] = [:]
        var compose: MTLComputePipelineState?
        var occlusionTexture: MTLTexture?
    }

    private let state = State()

    /// Radio de la oclusión en unidades de la escena (un personaje mide unas 6).
    var radius: Float = 2.4
    var strength: Float = 1.5

    mutating func prepare(for device: MTLDevice) {
        guard state.compose == nil, let library = try? device.makeLibrary(source: Self.source, options: nil) else { return }
        for multisampled in [false, true] {
            if let function = library.makeFunction(name: multisampled ? "occlusionMS" : "occlusion") {
                state.occlusion[multisampled] = try? device.makeComputePipelineState(function: function)
            }
        }
        if let function = library.makeFunction(name: "compose") {
            state.compose = try? device.makeComputePipelineState(function: function)
        }
    }

    mutating func postProcess(context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
        let color = context.sourceColorTexture
        let depth = context.sourceDepthTexture
        let multisampled = depth.textureType == .type2DMultisample
        guard let compose = state.compose, let occlusion = state.occlusion[multisampled],
              let encoder = context.commandBuffer.makeComputeCommandEncoder() else {
            Self.copy(context)
            return
        }
        if state.occlusionTexture?.width != depth.width || state.occlusionTexture?.height != depth.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: depth.width, height: depth.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            state.occlusionTexture = context.device.makeTexture(descriptor: descriptor)
        }
        guard let occlusionTexture = state.occlusionTexture else {
            encoder.endEncoding()
            Self.copy(context)
            return
        }
        var parameters = Parameters(inverseProjection: context.projection.inverse, projection: context.projection,
                                    radius: radius, strength: strength)
        let group = MTLSize(width: 8, height: 8, depth: 1)

        encoder.setComputePipelineState(occlusion)
        encoder.setTexture(depth, index: 0)
        encoder.setTexture(occlusionTexture, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: depth.width, height: depth.height, depth: 1), threadsPerThreadgroup: group)

        encoder.setComputePipelineState(compose)
        encoder.setTexture(color, index: 0)
        encoder.setTexture(occlusionTexture, index: 1)
        encoder.setTexture(context.targetColorTexture, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: context.targetColorTexture.width, height: context.targetColorTexture.height, depth: 1),
                                threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    /// Sin tuberías (por ejemplo, si el shader no compila) la imagen pasa tal cual.
    private static func copy(_ context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
        guard let blit = context.commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
        blit.endEncoding()
    }

    private struct Parameters {
        var inverseProjection: simd_float4x4
        var projection: simd_float4x4
        var radius: Float
        var strength: Float
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters {
        float4x4 inverseProjection;
        float4x4 projection;
        float radius;
        float strength;
    };

    // Posición en el espacio de la cámara de un píxel, a partir de su profundidad.
    static float3 viewPosition(float2 uv, float depth, constant Parameters &p) {
        float4 clip = float4(uv.x * 2 - 1, 1 - uv.y * 2, depth, 1);
        float4 view = p.inverseProjection * clip;
        return view.xyz / view.w;
    }

    static bool isSky(float3 position) {
        return !isfinite(position.z) || -position.z > 300 || -position.z <= 0;
    }

    static float readDepth(depth2d<float, access::read> depth, int2 pixel) {
        uint2 clamped = uint2(clamp(pixel, int2(0), int2(depth.get_width() - 1, depth.get_height() - 1)));
        return depth.read(clamped);
    }

    static float readDepth(depth2d_ms<float, access::read> depth, int2 pixel) {
        uint2 clamped = uint2(clamp(pixel, int2(0), int2(depth.get_width() - 1, depth.get_height() - 1)));
        return depth.read(clamped, 0);
    }

    template <typename Depth>
    static float computeOcclusion(Depth depth, uint2 gid, constant Parameters &p) {
        float2 size = float2(depth.get_width(), depth.get_height());
        int2 pixel = int2(gid);
        float3 center = viewPosition((float2(gid) + 0.5) / size, readDepth(depth, pixel), p);
        if (isSky(center)) return 1;

        // La normal sale de los vecinos más parecidos, para no inventarla en los bordes.
        float3 right = viewPosition((float2(gid) + float2(1.5, 0.5)) / size, readDepth(depth, pixel + int2(1, 0)), p) - center;
        float3 left = center - viewPosition((float2(gid) + float2(-0.5, 0.5)) / size, readDepth(depth, pixel - int2(1, 0)), p);
        float3 down = viewPosition((float2(gid) + float2(0.5, 1.5)) / size, readDepth(depth, pixel + int2(0, 1)), p) - center;
        float3 up = center - viewPosition((float2(gid) + float2(0.5, -0.5)) / size, readDepth(depth, pixel - int2(0, 1)), p);
        float3 dx = abs(right.z) < abs(left.z) ? right : left;
        float3 dy = abs(down.z) < abs(up.z) ? down : up;
        float3 normal = normalize(cross(dy, dx));
        if (dot(normal, -center) < 0) normal = -normal;

        // Cuántos píxeles ocupa el radio a esta distancia.
        float pixels = clamp(p.radius * p.projection[1][1] * size.y * 0.5 / -center.z, 3.0, 90.0);
        float noise = fract(52.9829189 * fract(dot(float2(gid), float2(0.06711056, 0.00583715))));
        const int count = 14;
        float occluded = 0;
        float radius2 = p.radius * p.radius;
        for (int i = 0; i < count; i++) {
            float t = (float(i) + noise) / float(count);
            float angle = (float(i) * 2.39996 + noise * 6.2831853);
            float2 offset = float2(cos(angle), sin(angle)) * pixels * sqrt(t);
            int2 sample = pixel + int2(round(offset));
            float3 position = viewPosition((float2(sample) + 0.5) / size, readDepth(depth, sample), p);
            if (isSky(position)) continue;
            float3 v = position - center;
            float distance2 = dot(v, v);
            float facing = dot(v, normal) * rsqrt(max(distance2, 1e-4));
            float falloff = saturate(1 - distance2 / radius2);
            occluded += saturate(facing - 0.08) * falloff;
        }
        return saturate(1 - p.strength * occluded / float(count) * 1.6);
    }

    kernel void occlusion(depth2d<float, access::read> depth [[texture(0)]],
                          texture2d<float, access::write> result [[texture(1)]],
                          constant Parameters &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= result.get_width() || gid.y >= result.get_height()) return;
        result.write(float4(computeOcclusion(depth, gid, p)), gid);
    }

    kernel void occlusionMS(depth2d_ms<float, access::read> depth [[texture(0)]],
                            texture2d<float, access::write> result [[texture(1)]],
                            constant Parameters &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= result.get_width() || gid.y >= result.get_height()) return;
        result.write(float4(computeOcclusion(depth, gid, p)), gid);
    }

    kernel void compose(texture2d<float, access::read> source [[texture(0)]],
                        texture2d<float, access::read> occlusion [[texture(1)]],
                        texture2d<float, access::write> target [[texture(2)]],
                        constant Parameters &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        uint2 size = uint2(target.get_width(), target.get_height());
        if (gid.x >= size.x || gid.y >= size.y) return;
        float4 color = source.read(gid);

        // La oclusión, suavizada en un 5×5 para quitar el ruido del muestreo.
        uint2 aoSize = uint2(occlusion.get_width(), occlusion.get_height());
        int2 aoPixel = int2(float2(gid) * float2(aoSize) / float2(size));
        float sum = 0;
        float weight = 0;
        float centerAO = occlusion.read(uint2(clamp(aoPixel, int2(0), int2(aoSize) - 1))).r;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                uint2 at = uint2(clamp(aoPixel + int2(x, y) * 2, int2(0), int2(aoSize) - 1));
                float value = occlusion.read(at).r;
                float w = exp(-abs(value - centerAO) * 4.0);
                sum += value * w;
                weight += w;
            }
        }
        float ao = sum / max(weight, 1e-4);
        float3 rgb = color.rgb * mix(1.0, ao, 0.9);

        // Rango más parejo: las luces altas se comprimen con suavidad y las sombras se levantan un poco, como la
        // exposición de una cámara real; encima, apenas un punto más de color.
        float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        if (luma > 0.6) {
            float over = luma - 0.6;
            rgb *= (0.6 + over / (1.0 + over * 3.0)) / luma;
        }
        rgb = mix(rgb, sqrt(max(rgb, 0.0)), 0.1);
        luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luma), rgb, 1.05);
        // Un leve tono cálido rojizo en toda la imagen.
        rgb *= float3(1.035, 0.985, 0.965);

        // Viñeteado muy suave.
        float2 uv = (float2(gid) + 0.5) / float2(size);
        float2 centered = (uv - 0.5) * float2(1.0, float(size.y) / float(size.x)) * 1.6;
        rgb *= 1.0 - 0.1 * smoothstep(0.45, 1.1, length(centered));

        target.write(float4(max(rgb, 0.0), color.a), gid);
    }
    """
}
