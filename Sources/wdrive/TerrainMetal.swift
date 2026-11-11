import AppKit
import MetalKit

/// Draws the terrain on the GPU.
///
/// A compute pass samples the height field (and the yellow tint) into a texture, plus a coarse
/// copy that goes back to the CPU for labels, dashes and the pointer. Then the scene: a hazy
/// background, the lines, and the labels. Solid lines come straight from the field: one tilted
/// quad per contour level, lifted by its height, lights up where the field crosses that level.
/// Dashes and dots are drawn as round-capped strokes placed by the CPU. Last, an optional filter.
final class TerrainRenderer {
    static let shared = TerrainRenderer()

    /// What one frame shows.
    struct Scene {
        var frame: TerrainField.Frame
        var tuning: TerrainTuning
        var labels: [TerrainField.Label]
        var markers: [TerrainField.Marker]
        var strokes: [TerrainField.Stroke]
        var time: Double
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fieldPipeline: MTLComputePipelineState
    private let coarsePipeline: MTLComputePipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let strokePipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    private let filterPipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            // Compiled from source at first use: SwiftPM doesn't build .metal files.
            let library = try device.makeLibrary(source: Self.shaders, options: nil)
            func pipeline(_ vertex: String, _ fragment: String, blends: Bool) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                let color = descriptor.colorAttachments[0]!
                color.pixelFormat = .bgra8Unorm
                if blends {
                    // Premultiplied "over".
                    color.isBlendingEnabled = true
                    color.sourceRGBBlendFactor = .one
                    color.sourceAlphaBlendFactor = .one
                    color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            fieldPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "terrainField")!)
            coarsePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "terrainCoarse")!)
            backgroundPipeline = try pipeline("terrainFullscreen", "terrainBackground", blends: false)
            linePipeline = try pipeline("terrainLineVertex", "terrainLineFragment", blends: true)
            strokePipeline = try pipeline("terrainStrokeVertex", "terrainStrokeFragment", blends: true)
            labelPipeline = try pipeline("terrainFullscreen", "terrainLabels", blends: true)
            filterPipeline = try pipeline("terrainFullscreen", "terrainFilter", blends: false)
        } catch {
            NSLog("wdrive: terrain shaders failed: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    func draw(_ scene: Scene, in view: MTKView, canvas: TerrainCanvas) {
        view.clearColor = Self.clearColor
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let target = pass.colorAttachments[0].texture, let commands = queue.makeCommandBuffer() else { return }
        encode(scene, size: view.bounds.size, scale: Double(target.width) / max(view.bounds.width, 1),
               target: pass, canvas: canvas, into: commands)
        commands.present(drawable)
        commands.commit()
    }

    /// For `--snapshot`, which can't read a Metal layer back.
    func image(_ scene: Scene, size: CGSize, scale: Double, canvas: TerrainCanvas) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .managed
        guard let target = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.clearColor
        encode(scene, size: size, scale: scale, target: pass, canvas: canvas, into: commands)
        let blit = commands.makeBlitCommandEncoder()
        blit?.synchronize(resource: target)
        blit?.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: TerrainCanvas.bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static var clearColor: MTLClearColor {
        let c = TerrainPalette.paper
        return MTLClearColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: 1)
    }

    // MARK: Encoding

    private func encode(_ scene: Scene, size: CGSize, scale: Double, target: MTLRenderPassDescriptor,
                        canvas: TerrainCanvas, into commands: MTLCommandBuffer) {
        let frame = scene.frame, tuning = scene.tuning, grid = frame.grid
        guard let targetTexture = target.colorAttachments[0].texture,
              let field = canvas.texture(\.fieldTexture, grid.nx, grid.ny, .rg32Float, [.shaderRead, .shaderWrite], device) else { return }
        var uniforms = sceneUniforms(scene, size: size, scale: scale)
        encodeField(frame, tuning: tuning, field: field, canvas: canvas, into: commands)

        // With a filter the scene goes to a texture first, and the filter draws it to the target.
        let filter = tuning.filterKind
        let scenePass: MTLRenderPassDescriptor
        if filter != .none, let texture = canvas.texture(\.sceneTexture, targetTexture.width, targetTexture.height, .bgra8Unorm,
                                                        [.renderTarget, .shaderRead], device) {
            scenePass = MTLRenderPassDescriptor()
            scenePass.colorAttachments[0].texture = texture
            scenePass.colorAttachments[0].loadAction = .dontCare
            scenePass.colorAttachments[0].storeAction = .store
        } else {
            scenePass = target
        }

        guard let render = commands.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        render.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        render.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        render.setRenderPipelineState(backgroundPipeline)
        render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if tuning.style == .solid {
            if frame.levelCount > 0 {
                render.setRenderPipelineState(linePipeline)
                render.setFragmentTexture(field, index: 0)
                render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: frame.levelCount)
            }
        } else if !scene.strokes.isEmpty {
            let strokes = scene.strokes.map {
                StrokeUniform(a: SIMD2(Float($0.a.x), Float($0.a.y)), b: SIMD2(Float($0.b.x), Float($0.b.y)),
                              tint: Float($0.tint), nearness: Float($0.nearness))
            }
            if let buffer = device.makeBuffer(bytes: strokes, length: MemoryLayout<StrokeUniform>.stride * strokes.count,
                                              options: .storageModeShared) {
                render.setRenderPipelineState(strokePipeline)
                render.setVertexBuffer(buffer, offset: 0, index: 1)
                render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: strokes.count)
            }
        }

        if let labels = canvas.labelTexture(scene, size: size, width: targetTexture.width, height: targetTexture.height, device: device) {
            render.setRenderPipelineState(labelPipeline)
            render.setFragmentTexture(labels, index: 0)
            render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        render.endEncoding()

        guard scenePass !== target, let sceneTexture = scenePass.colorAttachments[0].texture,
              let post = commands.makeRenderCommandEncoder(descriptor: target) else { return }
        post.setRenderPipelineState(filterPipeline)
        post.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        post.setFragmentTexture(sceneTexture, index: 0)
        post.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        post.endEncoding()
    }

    private func encodeField(_ frame: TerrainField.Frame, tuning: TerrainTuning, field: MTLTexture, canvas: TerrainCanvas,
                             into commands: MTLCommandBuffer) {
        let grid = frame.grid
        var uniforms = FieldUniforms(origin: SIMD2(Float(grid.originX), Float(grid.originY)),
                                     noiseOffset: SIMD2(Float(frame.noiseOffsetX), Float(frame.noiseOffsetY)),
                                     cell: Float(grid.cell), noiseScale: Float(1 / tuning.groundScale),
                                     relief: Float(tuning.groundRelief), wobble: Float(tuning.wobble),
                                     nx: UInt32(grid.nx), ny: UInt32(grid.ny),
                                     bumpCount: UInt32(min(frame.bumps.count, 64)), tintCount: UInt32(min(frame.tints.count, 64)))
        // setBytes needs at least one element.
        var bumps = frame.bumps.prefix(64).map {
            BumpUniform(center: SIMD2(Float($0.x), Float($0.y)), inverseRadius2: Float($0.inverseRadius2), height: Float($0.height))
        }
        if bumps.isEmpty { bumps.append(BumpUniform()) }
        var tints = frame.tints.prefix(64).map {
            TintUniform(center: SIMD2(Float($0.x), Float($0.y)), inverseReach2: Float($0.inverseReach2),
                        strength: Float($0.strength), solid: $0.solid ? 1 : 0)
        }
        if tints.isEmpty { tints.append(TintUniform()) }

        guard let compute = commands.makeComputeCommandEncoder() else { return }
        compute.setComputePipelineState(fieldPipeline)
        compute.setTexture(field, index: 0)
        compute.setBytes(&uniforms, length: MemoryLayout<FieldUniforms>.stride, index: 0)
        compute.setBytes(&bumps, length: MemoryLayout<BumpUniform>.stride * bumps.count, index: 1)
        compute.setBytes(&tints, length: MemoryLayout<TintUniform>.stride * tints.count, index: 2)
        compute.dispatchThreads(MTLSize(width: grid.nx, height: grid.ny, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        let coarse = frame.coarse
        if let buffer = canvas.claim(coarse, device: device, commands: commands) {
            uniforms.origin = SIMD2(Float(coarse.originX), Float(coarse.originY))
            uniforms.cell = Float(coarse.cell)
            uniforms.nx = UInt32(coarse.nx)
            uniforms.ny = UInt32(coarse.ny)
            compute.setComputePipelineState(coarsePipeline)
            compute.setBuffer(buffer, offset: 0, index: 3)
            compute.setBytes(&uniforms, length: MemoryLayout<FieldUniforms>.stride, index: 0)
            compute.dispatchThreads(MTLSize(width: coarse.nx, height: coarse.ny, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        compute.endEncoding()
    }

    private func sceneUniforms(_ scene: Scene, size: CGSize, scale: Double) -> SceneUniforms {
        let tuning = scene.tuning, p = scene.frame.projection, grid = scene.frame.grid
        let halfWidth = tuning.style == .dots ? tuning.dotSize / 2 : tuning.lineWidth / 2
        return SceneUniforms(ink: Self.components(TerrainPalette.ink(opacity: tuning.lineOpacity)),
                             accent: Self.components(TerrainPalette.accent),
                             paper: Self.components(TerrainPalette.paper),
                             haze: Self.components(TerrainPalette.haze(tuning.haze)),
                             viewSize: SIMD2(Float(size.width), Float(size.height)),
                             center: SIMD2(Float(p.cx), Float(p.cy)),
                             turn: SIMD2(Float(p.cosTurn), Float(p.sinTurn)),
                             tilt: SIMD2(Float(p.cosTilt), Float(p.sinTilt)),
                             origin: SIMD2(Float(grid.originX), Float(grid.originY)),
                             cell: Float(grid.cell), lineWidth: Float(tuning.lineWidth * scale),
                             firstLevel: Float(scene.frame.firstLevel), lift: Float(p.elevation),
                             rise: Float(p.rise), scale: Float(scale), fogNear: Float(p.fogNear), fogRange: Float(p.fogRange),
                             fogStart: Float(tuning.fogStart), fogDensity: Float(tuning.fogDensity * 6),
                             fogFront: Float(tuning.fogFront * 3), fogFrontReach: Float(tuning.fogFrontReach),
                             nx: UInt32(grid.nx), ny: UInt32(grid.ny),
                             halfWidth: Float(halfWidth), time: Float(scene.time.truncatingRemainder(dividingBy: 3600)),
                             filter: UInt32(tuning.filterKind.rawValue), filterStrength: Float(tuning.filterStrength))
    }

    private static func components(_ color: NSColor) -> SIMD4<Float> {
        let c = color.usingColorSpace(.sRGB) ?? color
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
    }

    // Laid out to match the structs in `shaders`.
    private struct FieldUniforms {
        var origin: SIMD2<Float>
        var noiseOffset: SIMD2<Float>
        var cell: Float
        var noiseScale: Float
        var relief: Float
        var wobble: Float
        var nx: UInt32
        var ny: UInt32
        var bumpCount: UInt32
        var tintCount: UInt32
    }

    private struct BumpUniform {
        var center = SIMD2<Float>()
        var inverseRadius2: Float = 0
        var height: Float = 0
    }

    private struct TintUniform {
        var center = SIMD2<Float>()
        var inverseReach2: Float = 0
        var strength: Float = 0
        var solid: Float = 0
        var padding: Float = 0
    }

    private struct StrokeUniform {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var tint: Float
        var nearness: Float
    }

    private struct SceneUniforms {
        var ink, accent, paper, haze: SIMD4<Float>
        var viewSize, center, turn, tilt, origin: SIMD2<Float>
        var cell, lineWidth, firstLevel, lift: Float
        var rise, scale, fogNear, fogRange: Float
        var fogStart, fogDensity: Float
        var fogFront, fogFrontReach: Float
        var nx, ny: UInt32
        var halfWidth, time: Float
        var filter: UInt32
        var filterStrength: Float
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct FieldUniforms {
        float2 origin; float2 noiseOffset;
        float cell; float noiseScale; float relief; float wobble;
        uint nx; uint ny; uint bumpCount; uint tintCount;
    };
    struct Bump { float2 center; float inverseRadius2; float height; };
    struct Tint { float2 center; float inverseReach2; float strength; float solid; float padding; };
    struct Stroke { float2 a; float2 b; float tint; float nearness; };
    struct Scene {
        float4 ink; float4 accent; float4 paper; float4 haze;
        float2 viewSize; float2 center; float2 turn; float2 tilt; float2 origin;
        float cell; float lineWidth; float firstLevel; float lift;
        float rise; float scale; float fogNear; float fogRange;
        float fogStart; float fogDensity;
        float fogFront; float fogFrontReach;
        uint nx; uint ny;
        float halfWidth; float time;
        uint filter; float filterStrength;
    };

    // MARK: Field

    static float hash2(int x, int y) {
        uint h = uint(x) * 374761393u + uint(y) * 668265263u;
        h = (h ^ (h >> 13)) * 1274126177u;
        h ^= h >> 16;
        return float(h & 0xFFFFFFu) / float(0xFFFFFF);
    }

    static float valueNoise(float2 p) {
        float2 f = floor(p);
        int ix = int(f.x), iy = int(f.y);
        float2 t = p - f;
        float2 s = t * t * (3 - 2 * t);
        float a = hash2(ix, iy), b = hash2(ix + 1, iy), c = hash2(ix, iy + 1), d = hash2(ix + 1, iy + 1);
        return a + (b - a) * s.x + (c - a) * s.y + (a - b - c + d) * s.x * s.y;
    }

    // Domain-warped, three octaves: rolling ground rather than blobs.
    static float groundNoise(float2 p) {
        float2 w = float2(p.x + 0.9 * valueNoise(p + float2(3.1, 7.7)), p.y + 0.9 * valueNoise(p + float2(-5.3, 1.9)));
        return 0.6 * valueNoise(w) + 0.28 * valueNoise(w * 2.03) + 0.12 * valueNoise(w * 4.1);
    }

    // The ground alone, and with the hills and hover on it.
    static float2 height(float2 g, constant FieldUniforms& u, constant Bump* bumps) {
        float2 n = (g + u.noiseOffset) * u.noiseScale;
        float ground = u.relief * groundNoise(n);
        // The same noise bends every outline, so circles read as terrain.
        float w = u.wobble > 0 ? 1 + u.wobble * (valueNoise(n * 3.1 + float2(11.3, -4.1)) * 2 - 1) : 1;
        float w2 = w * w;
        float h = ground;
        for (uint i = 0; i < u.bumpCount; i++) {
            float2 d = g - bumps[i].center;
            float d2 = dot(d, d) * bumps[i].inverseRadius2 * w2;
            if (d2 < 4) h += bumps[i].height * exp(-3 * d2);
        }
        return float2(ground, h);
    }

    kernel void terrainCoarse(device float2* out [[buffer(3)]],
                              constant FieldUniforms& u [[buffer(0)]],
                              constant Bump* bumps [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.nx || gid.y >= u.ny) return;
        out[gid.y * u.nx + gid.x] = height(u.origin + float2(gid) * u.cell, u, bumps);
    }

    kernel void terrainField(texture2d<float, access::write> out [[texture(0)]],
                             constant FieldUniforms& u [[buffer(0)]],
                             constant Bump* bumps [[buffer(1)]],
                             constant Tint* tints [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.nx || gid.y >= u.ny) return;
        float2 g = u.origin + float2(gid) * u.cell;
        float h = height(g, u, bumps).y;
        float tint = 0;
        for (uint i = 0; i < u.tintCount; i++) {
            float2 d = g - tints[i].center;
            float s2 = dot(d, d) * tints[i].inverseReach2;
            if (s2 >= 2.56) continue;
            float e = exp(-3 * s2);
            float s = sqrt(s2);
            if (s > 1.2) { float v = (s - 1.2) / 0.4; e *= 1 - v * v * (3 - 2 * v); }
            tint = max(tint, tints[i].strength * (tints[i].solid > 0.5 ? min(1.0, e / 0.15) : e));
        }
        out.write(float4(h, tint, 0, 0), gid);
    }

    // MARK: Scene

    // Fog in front of a point this near the eye. Matches TerrainProjection.fog.
    static float fogAmount(float nearness, constant Scene& u) {
        // 0 at the bottom edge, 1 at the top, on the ground plane.
        float t = (u.fogNear - nearness) / u.fogRange;
        float back = u.fogDensity * max(t - u.fogStart, 0.0);
        float front = u.fogFront * max(u.fogFrontReach - t, 0.0) / u.fogFrontReach;
        return 1 - exp(-(back + front));
    }

    static float4 toClip(float2 p, constant Scene& u) {
        return float4(p.x / u.viewSize.x * 2 - 1, 1 - p.y / u.viewSize.y * 2, 0, 1);
    }

    struct FullVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex FullVertex terrainFullscreen(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        FullVertex out;
        out.position = float4(p * 2 - 1, 0, 1);
        out.uv = float2(p.x, 1 - p.y);
        return out;
    }

    // The ground plane's haze: thicker toward the back and the front.
    fragment float4 terrainBackground(FullVertex in [[stage_in]], constant Scene& u [[buffer(0)]]) {
        float depth = (in.uv.y * u.viewSize.y - u.center.y) / u.tilt.x;
        return float4(mix(u.paper.rgb, u.haze.rgb, fogAmount(depth * u.tilt.y, u)), 1);
    }

    struct LineVertex {
        float4 position [[position]];
        float2 grid;
        float nearness;
        float level [[flat]];
    };

    vertex LineVertex terrainLineVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        constant Scene& u [[buffer(0)]]) {
        float2 corner = float2(vid & 1, vid >> 1);
        float2 grid = corner * float2(u.nx - 1, u.ny - 1);
        float2 g = u.origin + grid * u.cell;
        float level = u.firstLevel + float(iid);
        float depth = u.turn.y * g.x + u.turn.x * g.y;
        float2 s = float2(u.center.x + u.turn.x * g.x - u.turn.y * g.y, u.center.y + depth * u.tilt.x - level * u.lift);
        LineVertex out;
        out.position = toClip(s, u);
        out.grid = grid;
        out.nearness = depth * u.tilt.y + level * u.rise * u.tilt.x;
        out.level = level;
        return out;
    }

    fragment float4 terrainLineFragment(LineVertex in [[stage_in]],
                                        texture2d<float, access::read> field [[texture(0)]],
                                        constant Scene& u [[buffer(0)]]) {
        float2 p = clamp(in.grid, float2(0), float2(u.nx - 1, u.ny - 1) - 0.001);
        uint2 i = uint2(p);
        float2 f = p - float2(i);
        float2 a = field.read(i).xy, b = field.read(i + uint2(1, 0)).xy;
        float2 c = field.read(i + uint2(0, 1)).xy, d = field.read(i + uint2(1, 1)).xy;
        float2 v = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        // Distance to the level in pixels, from how fast the height changes across the screen.
        float distance = abs(v.x - in.level) / max(fwidth(v.x), 1e-4);
        float alpha = saturate(u.lineWidth * 0.5 + 0.5 - distance);
        if (alpha <= 0) discard_fragment();
        float3 color = mix(mix(u.ink.rgb, u.accent.rgb, v.y), u.haze.rgb, fogAmount(in.nearness, u));
        return float4(color * alpha, alpha);
    }

    struct StrokeVertex {
        float4 position [[position]];
        float2 point;
        float2 a [[flat]];
        float2 b [[flat]];
        float tint [[flat]];
        float nearness [[flat]];
    };

    // A quad around each dash, a pixel wider than its round caps.
    vertex StrokeVertex terrainStrokeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                            constant Scene& u [[buffer(0)]],
                                            const device Stroke* strokes [[buffer(1)]]) {
        Stroke s = strokes[iid];
        float2 axis = s.b - s.a;
        float len = length(axis);
        float2 along = len > 1e-4 ? axis / len : float2(1, 0);
        float2 across = float2(-along.y, along.x);
        float r = u.halfWidth + 1.0 / u.scale;
        float2 corner = float2(vid & 1, vid >> 1);
        float2 p = mix(s.a - along * r, s.b + along * r, corner.x) + across * r * (corner.y * 2 - 1);
        StrokeVertex out;
        out.position = toClip(p, u);
        out.point = p;
        out.a = s.a;
        out.b = s.b;
        out.tint = s.tint;
        out.nearness = s.nearness;
        return out;
    }

    fragment float4 terrainStrokeFragment(StrokeVertex in [[stage_in]], constant Scene& u [[buffer(0)]]) {
        float2 pa = in.point - in.a, ba = in.b - in.a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
        float distance = length(pa - ba * h);
        float alpha = saturate((u.halfWidth - distance) * u.scale + 0.5);
        if (alpha <= 0) discard_fragment();
        float3 color = mix(mix(u.ink.rgb, u.accent.rgb, in.tint), u.haze.rgb, fogAmount(in.nearness, u));
        return float4(color * alpha, alpha);
    }

    fragment float4 terrainLabels(FullVertex in [[stage_in]], texture2d<float> labels [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        return labels.sample(s, in.uv);
    }

    // MARK: Filters

    static float random(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    constant float bayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

    fragment float4 terrainFilter(FullVertex in [[stage_in]], texture2d<float> scene [[texture(0)]],
                                  constant Scene& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        float2 size = float2(scene.get_width(), scene.get_height());
        float2 pixel = uv * size;
        float k = u.filterStrength, t = u.time;
        float3 c;
        switch (u.filter) {
        case 1: { // Grain: fresh noise every frame, a little stronger in the shadows.
            c = scene.sample(s, uv).rgb;
            float n = random(floor(pixel) + fract(t * 7.13) * 113.7) - 0.5;
            c += n * k * (0.28 - 0.12 * dot(c, float3(0.333)));
            break;
        }
        case 2: { // Glitch: bursts of torn bands, split colours and blocks.
            float tick = floor(t * 14);
            float burst = step(1 - 0.35 * k, random(float2(tick, 3.7)));
            float band = floor(uv.y * 18 + random(float2(tick, 1.1)) * 4);
            float tear = random(float2(band, tick));
            float shift = (tear - 0.5) * 0.12 * k * step(0.55, tear) * burst;
            float2 g = float2(uv.x + shift, uv.y);
            float split = (0.002 + 0.01 * burst) * k;
            c = float3(scene.sample(s, g + float2(split, 0)).r, scene.sample(s, g).g, scene.sample(s, g - float2(split, 0)).b);
            float2 block = floor(pixel / float2(32, 10));
            if (burst > 0 && random(block + tick * 0.37) > 1 - 0.05 * k) {
                c = mix(c, float3(random(block + tick), random(block - tick), random(block * 1.7 + tick)) * 0.8, 0.7);
            }
            break;
        }
        case 3: { // 80s TV: curved glass, bleeding colour, scanlines, a phosphor mask, a rolling bar.
            float2 q = uv * 2 - 1;
            q *= 1 + 0.07 * k * dot(q, q);
            float2 d = q * 0.5 + 0.5;
            if (any(d < 0) || any(d > 1)) return float4(0, 0, 0, 1);
            float bleed = 0.003 * k;
            c = float3(scene.sample(s, d + float2(bleed, 0)).r, scene.sample(s, d).g, scene.sample(s, d - float2(bleed, 0)).b);
            float2 texel = 1.5 / size;
            float3 glow = (scene.sample(s, d + float2(texel.x, 0)).rgb + scene.sample(s, d - float2(texel.x, 0)).rgb
                         + scene.sample(s, d + float2(0, texel.y)).rgb + scene.sample(s, d - float2(0, texel.y)).rgb) * 0.25;
            c += glow * 0.35 * k;
            float scan = 0.5 + 0.5 * sin(d.y * size.y * 3.14159 / 1.5);
            c *= mix(1.0, 0.6 + 0.4 * scan, k);
            int m = int(pixel.x) % 3;
            float3 mask = m == 0 ? float3(1, 0.75, 0.75) : (m == 1 ? float3(0.75, 1, 0.75) : float3(0.75, 0.75, 1));
            c *= mix(float3(1), mask, 0.6 * k);
            c *= mix(1.0, 1 - 0.45 * dot(q * 0.7, q * 0.7), k);
            float bar = fract(d.y * 0.6 - t * 0.12);
            c += 0.035 * k * exp(-pow((bar - 0.5) * 9, 2.0));
            c *= 1 + 0.025 * k * sin(t * 50);
            break;
        }
        case 4: { // Dither: a few levels per channel, ordered, in two-pixel cells.
            float2 cell = floor(pixel / 2);
            float2 sampled = (cell * 2 + 1) / size;
            c = scene.sample(s, sampled).rgb;
            int index = (int(cell.y) % 4) * 4 + int(cell.x) % 4;
            float levels = round(mix(8.0, 2.0, k));
            // Measured up from the paper, so bare ground stays clean.
            float3 lift = saturate((c - u.paper.rgb) / (1 - u.paper.rgb));
            lift = floor(lift * (levels - 1) + (bayer[index] + 0.5) / 16) / (levels - 1);
            c = u.paper.rgb + lift * (1 - u.paper.rgb);
            break;
        }
        default:
            c = scene.sample(s, uv).rgb;
        }
        return float4(saturate(c), 1);
    }
    """
}

/// One view's GPU state: its field and scene textures, its labels, and the coarse field coming
/// back to the CPU, in two buffers so the CPU reads one while the GPU fills the other.
final class TerrainCanvas {
    private struct Slot {
        var buffer: MTLBuffer
        var grid: TerrainField.Grid
        var commands: MTLCommandBuffer
        var serial: Int
        var isDone: Bool { commands.status == .completed || commands.status == .error }
    }

    private struct LabelKey: Equatable {
        var labels: [TerrainField.Label]
        var markers: [TerrainField.Marker]
        var width, height: Int
        var labelSize, lineOpacity, haze: Double
        var isDay: Bool
    }

    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    fileprivate var fieldTexture: MTLTexture?
    fileprivate var sceneTexture: MTLTexture?
    private var labelTextures: [MTLTexture?] = [nil, nil]
    private var labelIndex = 0
    private var labelKey: LabelKey?
    private var slots: [Slot?] = [nil, nil]
    private var serial = 0
    private var delivered = -1

    fileprivate func texture(_ keyPath: ReferenceWritableKeyPath<TerrainCanvas, MTLTexture?>, _ width: Int, _ height: Int,
                             _ format: MTLPixelFormat, _ usage: MTLTextureUsage, _ device: MTLDevice) -> MTLTexture? {
        if let texture = self[keyPath: keyPath], texture.width == width, texture.height == height { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        self[keyPath: keyPath] = device.makeTexture(descriptor: descriptor)
        return self[keyPath: keyPath]
    }

    // MARK: Labels

    /// The labels drawn into a texture, so filters reach them too. Redrawn only when they
    /// change, into the other of two textures so the GPU never reads one being written.
    fileprivate func labelTexture(_ scene: TerrainRenderer.Scene, size: CGSize, width: Int, height: Int,
                                  device: MTLDevice) -> MTLTexture? {
        guard !scene.labels.isEmpty || !scene.markers.isEmpty else { return nil }
        let key = LabelKey(labels: scene.labels, markers: scene.markers, width: width, height: height, labelSize: scene.tuning.labelSize,
                           lineOpacity: scene.tuning.lineOpacity, haze: scene.tuning.haze, isDay: TerrainPalette.isDay)
        if key == labelKey, let texture = labelTextures[labelIndex] { return texture }
        labelIndex = 1 - labelIndex
        if labelTextures[labelIndex]?.width != width || labelTextures[labelIndex]?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .managed
            labelTextures[labelIndex] = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = labelTextures[labelIndex],
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Self.bitmapInfo.rawValue) else { return nil }
        // Points, top-left origin, like the view.
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        Self.draw(scene.labels, tuning: scene.tuning, in: context)
        Self.draw(scene.markers, size: size, in: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        labelKey = key
        return texture
    }

    /// Each label turned along its line, with a halo of the ground behind it that cuts it into the line.
    private static func draw(_ labels: [TerrainField.Label], tuning: TerrainTuning, in context: CGContext) {
        let font = NSFont.systemFont(ofSize: tuning.labelSize, weight: .medium)
        let ink = TerrainPalette.ink(opacity: tuning.lineOpacity)
        let haze = TerrainPalette.haze(tuning.haze)
        for label in labels {
            context.saveGState()
            context.translateBy(x: label.position.x, y: label.position.y)
            context.rotate(by: label.angle)
            let ground = TerrainPalette.paper.blended(withFraction: label.groundFog, of: haze) ?? TerrainPalette.paper
            let halo = NSAttributedString(string: label.text, attributes: [
                .font: font, .strokeColor: ground, .strokeWidth: 3 / tuning.labelSize * 100,
            ])
            let lit = ink.blended(withFraction: label.tint, of: TerrainPalette.accent) ?? ink
            let color = lit.blended(withFraction: label.fog, of: haze) ?? lit
            let text = NSAttributedString(string: label.text, attributes: [.font: font, .foregroundColor: color])
            let size = text.size()
            let origin = CGPoint(x: -size.width / 2, y: -size.height / 2)
            halo.draw(at: origin)
            text.draw(at: origin)
            context.restoreGState()
        }
    }

    /// A yellow line from a pressed hill's foot up through its peak to a chip with its height,
    /// like the reference's.
    private static func draw(_ markers: [TerrainField.Marker], size: CGSize, in context: CGContext) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let accent = TerrainPalette.accent, paper = TerrainPalette.paper
        for marker in markers {
            context.saveGState()
            context.setAlpha(marker.opacity)
            let text = NSAttributedString(string: marker.text, attributes: [.font: font, .foregroundColor: paper])
            let textSize = text.size()
            let chip = CGSize(width: max(textSize.width + 10, 22), height: textSize.height + 4)
            // Kept on screen when the peak climbs past the top.
            let chipY = min(max(marker.peak.y - 18 - chip.height / 2, chip.height / 2 + 2), size.height - chip.height / 2 - 2)
            let rect = CGRect(x: marker.peak.x - chip.width / 2, y: chipY - chip.height / 2, width: chip.width, height: chip.height)

            context.setLineCap(.round)
            context.setStrokeColor(paper.cgColor)
            context.setLineWidth(4)
            context.move(to: marker.base)
            context.addLine(to: CGPoint(x: marker.peak.x, y: rect.maxY))
            context.strokePath()
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1.5)
            context.move(to: marker.base)
            context.addLine(to: CGPoint(x: marker.peak.x, y: rect.maxY))
            context.strokePath()

            let dot = CGRect(x: marker.peak.x - 3, y: marker.peak.y - 3, width: 6, height: 6)
            context.setFillColor(accent.cgColor)
            context.setStrokeColor(paper.cgColor)
            context.setLineWidth(2)
            context.addEllipse(in: dot)
            context.drawPath(using: .fillStroke)

            let pill = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.addPath(pill)
            context.setLineWidth(3)
            context.drawPath(using: .fillStroke)
            text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            context.restoreGState()
        }
    }

    // MARK: Readback

    /// A buffer to fill this frame, or nil while both are busy.
    fileprivate func claim(_ grid: TerrainField.Grid, device: MTLDevice, commands: MTLCommandBuffer) -> MTLBuffer? {
        // Free once the GPU is done, except the newest copy until it has been read.
        let newest = slots.indices.filter { slots[$0] != nil }.max { slots[$0]!.serial < slots[$1]!.serial }
        guard let index = slots.indices.first(where: { i in
            guard let slot = slots[i] else { return true }
            return slot.isDone && (i != newest || slot.serial <= delivered)
        }) else { return nil }
        let length = max(grid.nx * grid.ny, 1) * MemoryLayout<SIMD2<Float>>.stride
        let buffer = slots[index].flatMap { $0.buffer.length >= length ? $0.buffer : nil }
            ?? device.makeBuffer(length: length, options: .storageModeShared)
        guard let buffer else { return nil }
        serial += 1
        slots[index] = Slot(buffer: buffer, grid: grid, commands: commands, serial: serial)
        return buffer
    }

    /// The newest copy the GPU has finished, once.
    func latest() -> (grid: TerrainField.Grid, ground: [Float], full: [Float])? {
        guard let slot = slots.compactMap({ $0 }).filter({ $0.commands.status == .completed }).max(by: { $0.serial < $1.serial }),
              slot.serial > delivered else { return nil }
        delivered = slot.serial
        let count = slot.grid.nx * slot.grid.ny
        let values = slot.buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: count)
        var ground = [Float](repeating: 0, count: count), full = ground
        for i in 0..<count {
            ground[i] = values[i].x
            full[i] = values[i].y
        }
        return (slot.grid, ground, full)
    }
}

/// The Metal layer for the terrain or the dots, drawn on demand by its view's display link.
final class TerrainMetalView: MTKView {
    init(device: MTLDevice) {
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = TerrainRenderer.clearColor
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        layer?.isOpaque = true
    }

    required init(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
