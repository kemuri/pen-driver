import AppKit
import MetalKit

/// Draws the dots on the GPU: one small quad per dot, which the vertex shader places on the
/// height field (moved aside by the pointer, lifted by hills, seen through the camera) and
/// colours (brighter on top and on slopes facing the light, yellow near the pointer, fogged far off).
/// The dots turning into the pen's dot, or back, are drawn again on top.
final class DotRenderer {
    static let shared = DotRenderer()

    /// What one frame shows.
    struct Scene {
        var frame: DotField.Frame
        var tuning: DotTuning
        var cursor: DotCursor?
    }

    /// The pen's dot, across, as the old separate dot was; smaller while pressed.
    private static let cursorRadius = 4.5
    private static let maxCursorDots = 8

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            // Compiled from source at first use: SwiftPM doesn't build .metal files.
            let library = try device.makeLibrary(source: Self.shaders, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "dotVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "dotFragment")
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            // Premultiplied "over".
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("wdrive: dot shaders failed: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    func draw(_ scene: Scene, in view: MTKView) {
        view.clearColor = TerrainRenderer.clearColor
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let target = pass.colorAttachments[0].texture, let commands = queue.makeCommandBuffer() else { return }
        encode(scene, size: view.bounds.size, scale: Double(target.width) / max(view.bounds.width, 1), target: pass, into: commands)
        commands.present(drawable)
        commands.commit()
    }

    /// For `--snapshot`, which can't read a Metal layer back.
    func image(_ scene: Scene, size: CGSize, scale: Double) -> CGImage? {
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
        pass.colorAttachments[0].clearColor = TerrainRenderer.clearColor
        encode(scene, size: size, scale: scale, target: pass, into: commands)
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

    private func encode(_ scene: Scene, size: CGSize, scale: Double, target: MTLRenderPassDescriptor,
                        into commands: MTLCommandBuffer) {
        let frame = scene.frame
        var uniforms = Self.uniforms(scene, size: size, scale: scale)
        // setBytes needs at least one element.
        var bumps = frame.bumps.prefix(DotField.maxHills).map {
            BumpUniform(center: SIMD2(Float($0.tip.x), Float($0.tip.y)), tailCenter: SIMD2(Float($0.tail.x), Float($0.tail.y)),
                        a: Float($0.tip.a), b: Float($0.tip.b), c: Float($0.tip.c),
                        tailA: Float($0.tail.a), tailB: Float($0.tail.b), tailC: Float($0.tail.c),
                        amount: Float($0.tip.amount), tailAmount: Float($0.tail.amount),
                        stroke: UInt32(truncatingIfNeeded: $0.stroke),
                        reach2: Float(pow(hypot($0.tip.x - $0.tail.x, $0.tip.y - $0.tail.y) / 2 + max($0.tip.reach, $0.tail.reach), 2)))
        }
        if bumps.isEmpty { bumps.append(BumpUniform()) }
        // Too many for setVertexBytes, which stops at 4 KB.
        guard let bumpBuffer = device.makeBuffer(bytes: &bumps, length: MemoryLayout<BumpUniform>.stride * bumps.count) else { return }
        var cursorDots = (scene.cursor == nil ? [] : frame.cursorDots).prefix(Self.maxCursorDots).map {
            CursorDotUniform(index: SIMD2(Int32($0.x), Int32($0.y)), amount: Float($0.amount))
        }
        if cursorDots.isEmpty { cursorDots.append(CursorDotUniform()) }

        guard let render = commands.makeRenderCommandEncoder(descriptor: target) else { return }
        render.setRenderPipelineState(pipeline)
        render.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        render.setVertexBuffer(bumpBuffer, offset: 0, index: 1)
        render.setVertexBytes(&cursorDots, length: MemoryLayout<CursorDotUniform>.stride * cursorDots.count, index: 2)
        render.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                              instanceCount: Int(uniforms.dotCount + uniforms.cursorDotCount))
        render.endEncoding()
    }

    private static func uniforms(_ scene: Scene, size: CGSize, scale: Double) -> Uniforms {
        let t = scene.tuning, f = scene.frame, p = f.projection
        let count = UInt32(min(f.bumps.count, DotField.maxHills))
        let highlightReach = t.hoverRadius * 1.24
        let cursorDotCount = scene.cursor == nil ? 0 : UInt32(min(f.cursorDots.count, maxCursorDots))
        let cursorRadius = cursorRadius * (1 - 0.4 * (scene.cursor?.press ?? 0))
        // The ground under the bottom and top edges, for the fog.
        func depth(atScreenY y: Double) -> Double {
            let sy = y - p.cy
            return sy / max(p.cosTilt + sy * p.sinTilt * p.inverseDistance, 0.05)
        }
        let near = depth(atScreenY: size.height), far = depth(atScreenY: 0)
        // Looking straight down there's no back to fog; it comes in with the tilt.
        let fog = t.fog * 6 * min(p.sinTilt / 0.5, 1)
        // Growing on top shows the dots coming nearer: without perspective nothing comes nearer,
        // so it comes in with the perspective.
        let heightGrows = t.heightGrows * min(t.perspective / 0.25, 1)
        func components(_ color: NSColor) -> SIMD4<Float> {
            let c = color.usingColorSpace(.sRGB) ?? color
            return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
        }
        return Uniforms(ink: components(TerrainPalette.ink), accent: components(TerrainPalette.accent),
                        paper: components(TerrainPalette.paper),
                        viewSize: SIMD2(Float(size.width), Float(size.height)), center: SIMD2(Float(p.cx), Float(p.cy)),
                        turn: SIMD2(Float(p.cosTurn), Float(p.sinTurn)), tilt: SIMD2(Float(p.cosTilt), Float(p.sinTilt)),
                        noiseOffset: SIMD2(Float(f.noiseOffsetX), Float(f.noiseOffsetY)),
                        pointer: SIMD2(Float(f.pointerX), Float(f.pointerY)), sweep: SIMD2(Float(f.sweepX), Float(f.sweepY)),
                        first: SIMD2(Int32(f.firstX), Int32(f.firstY)),
                        nx: UInt32(f.nx), bumpCount: count, highlight: Float(f.highlight), majorPattern: UInt32(t.pattern.rawValue),
                        spacing: Float(t.spacing), noiseScale: Float(1 / t.groundScale), relief: Float(t.groundRelief),
                        inverseDistance: Float(p.inverseDistance),
                        pointerInverseRadius2: Float(1 / (t.hoverRadius * t.hoverRadius)), push: Float(f.push),
                        majorEvery: Float(t.majorEvery.rounded()), dotRadius: Float(t.dotSize / 2),
                        majorRadius: Float(t.majorSize / 2), brightness: Float(t.brightness),
                        majorBrightness: Float(t.majorBrightness), hillHeight: Float(t.hillHeight),
                        heightGrows: Float(heightGrows), heightBrightens: Float(t.heightBrightens),
                        shading: Float(t.shading), fog: Float(fog),
                        fogNear: Float(near), fogRange: Float(max(near - far, 1)), scale: Float(scale),
                        cursorRadius: Float(cursorRadius), dotCount: UInt32(f.nx * f.ny), cursorDotCount: cursorDotCount,
                        pointerHeight: Float(f.pointerHeight),
                        highlightInverseReach2: Float(1 / (highlightReach * highlightReach)))
    }

    // Laid out to match the structs in `shaders`.
    private struct Uniforms {
        var ink, accent, paper: SIMD4<Float>
        var viewSize, center, turn, tilt: SIMD2<Float>
        var noiseOffset, pointer, sweep: SIMD2<Float>
        var first: SIMD2<Int32>
        var nx, bumpCount: UInt32
        var highlight: Float
        var majorPattern: UInt32
        var spacing, noiseScale, relief, inverseDistance: Float
        var pointerInverseRadius2, push, majorEvery, dotRadius: Float
        var majorRadius, brightness, majorBrightness, hillHeight: Float
        var heightGrows, heightBrightens, shading, fog: Float
        var fogNear, fogRange, scale, cursorRadius: Float
        var dotCount, cursorDotCount: UInt32
        var pointerHeight, highlightInverseReach2: Float
    }

    private struct CursorDotUniform {
        var index = SIMD2<Int32>()
        var amount: Float = 0
        var padding: Float = 0
    }

    private struct BumpUniform {
        var center = SIMD2<Float>(), tailCenter = SIMD2<Float>()
        var a: Float = 0, b: Float = 0, c: Float = 0
        var tailA: Float = 0, tailB: Float = 0, tailC: Float = 0
        var amount: Float = 0, tailAmount: Float = 0
        var stroke: UInt32 = 0
        var reach2: Float = 0
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 ink; float4 accent; float4 paper;
        float2 viewSize; float2 center; float2 turn; float2 tilt;
        float2 noiseOffset; float2 pointer; float2 sweep;
        int2 first;
        uint nx; uint bumpCount; float highlight; uint majorPattern;
        float spacing; float noiseScale; float relief; float inverseDistance;
        float pointerInverseRadius2; float push; float majorEvery; float dotRadius;
        float majorRadius; float brightness; float majorBrightness; float hillHeight;
        float heightGrows; float heightBrightens; float shading; float fog;
        float fogNear; float fogRange; float scale; float cursorRadius;
        uint dotCount; uint cursorDotCount; float pointerHeight; float highlightInverseReach2;
    };
    struct CursorDot { int2 index; float amount; float padding; };
    struct Bump {
        float2 center; float2 tailCenter;
        float a; float b; float c;
        float tailA; float tailB; float tailC;
        float amount; float tailAmount;
        uint stroke;
        float reach2;
    };

    // The terrain's noise, so the ground rolls the same way.
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

    static float groundNoise(float2 p) {
        float2 w = float2(p.x + 0.9 * valueNoise(p + float2(3.1, 7.7)), p.y + 0.9 * valueNoise(p + float2(-5.3, 1.9)));
        return 0.6 * valueNoise(w) + 0.28 * valueNoise(w * 2.03) + 0.12 * valueNoise(w * 4.1);
    }

    static float ground(float2 g, constant Uniforms& u) {
        return u.relief * groundNoise((g + u.noiseOffset) * u.noiseScale);
    }

    // How far a bump lifts a point: a bell around the nearest place on its way from tail to tip,
    // with the height and shape there, so the bumps of a stroke meet without a seam.
    static float ridge(float2 g, constant Bump& bump) {
        // Most are nowhere near; there can be a lot of them, and of dots.
        if (distance_squared(g, (bump.center + bump.tailCenter) / 2) > bump.reach2) return 0;
        float2 way = bump.center - bump.tailCenter;
        float2 from = g - bump.tailCenter;
        float a = (bump.a + bump.tailA) / 2, b = (bump.b + bump.tailB) / 2, c = (bump.c + bump.tailC) / 2;
        float2 shaped = float2(a * way.x + b * way.y, b * way.x + c * way.y);
        float length2 = dot(way, shaped);
        float t = length2 > 1e-6 ? saturate(dot(from, shaped) / length2) : 1.0;
        float2 d = from - way * t;
        a = mix(bump.tailA, bump.a, t);
        b = mix(bump.tailB, bump.b, t);
        c = mix(bump.tailC, bump.c, t);
        float d2 = a * d.x * d.x + 2 * b * d.x * d.y + c * d.y * d.y;
        return d2 < 4 ? mix(bump.tailAmount, bump.amount, t) * exp(-3 * d2) : 0.0;
    }

    // A stroke's hills join: as far as the furthest of them there, so going over it adds nothing.
    // Each stroke then builds on the ones before, raising what's already raised, by less the
    // nearer it is to the full height, which it never passes. The pointer's bump goes on top.
    static float raised(float2 g, constant Uniforms& u, constant Bump* bumps) {
        float built = 0, joined = 0;
        uint stroke = bumps[0].stroke;
        for (uint i = 0; i < u.bumpCount; i++) {
            if (bumps[i].stroke != stroke) {
                built += joined * (1 - built);
                joined = 0;
                stroke = bumps[i].stroke;
            }
            joined = max(joined, ridge(g, bumps[i]));
        }
        built += joined * (1 - built);
        float2 p = g - u.pointer;
        float s2 = dot(p, p) * u.pointerInverseRadius2;
        return u.hillHeight * built + (s2 < 4 ? u.pointerHeight * exp(-3 * s2) : 0.0);
    }

    // Where a dot lands: on the ground, moved aside by the pointer, and on screen.
    struct Placed {
        int2 index;
        float2 g;
        float up;
        float h;
        float2 r;
        float k;
        float2 screen;
    };

    static Placed place(int2 index, constant Uniforms& u, constant Bump* bumps, constant CursorDot* cursorDots) {
        Placed p;
        p.index = index;
        float2 g = float2(p.index) * u.spacing;

        // The pen's dot stays on the top of its bump; the rest are parted from the moving pointer
        // and swept along its way, more the closer they are.
        float hold = 0;
        for (uint i = 0; i < u.cursorDotCount; i++) {
            if (all(cursorDots[i].index == index)) hold = cursorDots[i].amount;
        }
        float2 d = g - u.pointer;
        float s2 = dot(d, d) * u.pointerInverseRadius2;
        if (s2 < 4 && hold < 1) {
            float len = length(d);
            g += ((len > 1e-3 ? d / len : float2(0)) * u.push + u.sweep) * exp(-3 * s2) * (1 - hold);
        }
        p.g = g;
        p.up = raised(g, u, bumps);
        p.h = ground(g, u) + p.up;

        // Turned, tilted away, lifted, and seen through the camera: nearer is bigger.
        p.r = float2(u.turn.x * g.x - u.turn.y * g.y, u.turn.y * g.x + u.turn.x * g.y);
        float depth = p.r.y * u.tilt.y + p.h * u.tilt.x;
        p.k = 1 / max(1 - depth * u.inverseDistance, 0.1);
        p.screen = u.center + float2(p.r.x, p.r.y * u.tilt.x - p.h * u.tilt.y) * p.k;
        return p;
    }

    struct DotVertex {
        float4 position [[position]];
        /// From the dot's centre, in points.
        float2 offset;
        float radius [[flat]];
        /// Paper around the dot, in points, setting the pen's dot apart from yellow dots near it.
        float ring [[flat]];
        float3 color [[flat]];
    };

    vertex DotVertex dotVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               constant Uniforms& u [[buffer(0)]],
                               constant Bump* bumps [[buffer(1)]],
                               constant CursorDot* cursorDots [[buffer(2)]]) {
        // The quads past the grid's draw the dots turning into the pen's again, on top.
        bool isCursor = iid >= u.dotCount;
        float cursorAmount = isCursor ? cursorDots[iid - u.dotCount].amount : 0;
        int2 gridIndex = isCursor ? cursorDots[iid - u.dotCount].index : u.first + int2(iid % u.nx, iid / u.nx);
        Placed placed = place(gridIndex, u, bumps, cursorDots);
        int2 index = placed.index;
        float2 g = placed.g;
        bool major = false;
        if (u.majorEvery > 0.5) {
            int m = int(u.majorEvery);
            bool onX = (index.x % m + m) % m == 0, onY = (index.y % m + m) % m == 0;
            major = u.majorPattern == 0 ? (onX || onY) : (onX && onY);
        }

        float up = placed.up, h = placed.h;
        float2 slope = float2(ground(g + float2(1, 0), u) + raised(g + float2(1, 0), u, bumps),
                              ground(g + float2(0, 1), u) + raised(g + float2(0, 1), u, bumps)) - h;

        // Yellow around the pointer, and only there.
        float tint = 0;
        float2 fromPointer = g - u.pointer;
        float t2 = dot(fromPointer, fromPointer) * u.highlightInverseReach2;
        if (t2 < 2.56) {
            float e = exp(-3 * t2);
            float s = sqrt(t2);
            if (s > 1.2) { float v = (s - 1.2) / 0.4; e *= 1 - v * v * (3 - 2 * v); }
            tint = u.highlight * e;
        }

        float2 r = placed.r, screen = placed.screen;
        float k = placed.k;

        float lift = clamp(up / max(abs(u.hillHeight), 1.0), -0.5, 1.5);
        float radius = (major ? u.majorRadius : u.dotRadius) * k * max(1 + u.heightGrows * lift, 0.2);
        // Lit from the top left of the view: brighter where the ground faces it.
        float2 facing = float2(u.turn.x * slope.x - u.turn.y * slope.y, u.turn.y * slope.x + u.turn.x * slope.y);
        float light = 1 + u.shading * clamp(dot(facing, float2(0.7071)) * 1.5, -1.0, 1.0);
        float brightness = (major ? u.majorBrightness : u.brightness) * (1 + u.heightBrightens * max(lift, 0.0)) * light;
        float3 color = mix(u.paper.rgb, u.ink.rgb, saturate(brightness));
        color = mix(color, u.accent.rgb, saturate(tint));
        float t = (u.fogNear - r.y) / u.fogRange;
        color = mix(color, u.paper.rgb, 1 - exp(-u.fog * max(t - 0.25, 0.0)));
        float ring = 0;
        if (isCursor) {
            radius = mix(radius, u.cursorRadius, cursorAmount);
            color = mix(color, u.accent.rgb, cursorAmount);
            ring = 1.5 * cursorAmount;
        }

        // A pixel past the edge for antialiasing.
        float reach = radius + ring + 1 / u.scale;
        float2 corner = float2(vid & 1, vid >> 1) * 2 - 1;
        float2 p = screen + corner * reach;
        DotVertex out;
        bool outside = any(screen + reach < 0) || any(screen - reach > u.viewSize);
        out.position = outside ? float4(2, 2, 0, 1) : float4(p.x / u.viewSize.x * 2 - 1, 1 - p.y / u.viewSize.y * 2, 0, 1);
        out.offset = corner * reach;
        out.radius = radius;
        out.ring = ring;
        out.color = color;
        return out;
    }

    fragment float4 dotFragment(DotVertex in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float d = length(in.offset);
        float alpha = saturate((in.radius + in.ring - d) * u.scale + 0.5);
        if (alpha <= 0) discard_fragment();
        float inside = in.ring > 0 ? saturate((in.radius - d) * u.scale + 0.5) : 1.0;
        return float4(mix(u.paper.rgb, in.color, inside) * alpha, alpha);
    }
    """
}
