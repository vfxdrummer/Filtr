import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal

/// Applies a `FilterRecipe` to a `CGImage`.
///
/// **This is deliberately not an actor.** `CIContext` is documented as thread-safe, and
/// an actor's job is mutual exclusion — wrapping this in one would quietly serialise
/// every render in the app down to one at a time and throw away the parallelism we are
/// trying to demonstrate. Actors protect *mutable state*; there is none here.
///
/// What we do want is a single shared context (it caches compiled kernels, texture
/// allocations and intermediate buffers — constructing one per render is a
/// well-known way to make an image app crawl) and a *bounded* number of simultaneous
/// callers. The bound belongs in `RenderCoordinator`, not here.
final class FilterEngine: Sendable {
    static let shared = FilterEngine()

    private let context: CIContext

    private init() {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            // Intermediates are the difference between a steady 200 MB and a jagged
            // 900 MB when a few dozen renders overlap.
            .cacheIntermediates: false,
            .name: "FiltrShared",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    struct Request: Sendable {
        var recipe: FilterRecipe
        var intensity: Double
        var adjustments: Adjustments
        var normalizedCrop: CGRect
        var targetMaxPixel: CGFloat
        var workMultiplier: Int
    }

    /// Synchronous by nature — this is the CPU/GPU work. Callers are responsible for
    /// getting it off the cooperative pool (see `RenderTaskExecutor`) and for bounding
    /// how many run at once.
    func render(_ source: ImageBox, request: Request) throws -> ImageBox {
        var image = CIImage(cgImage: source.cgImage)

        // 1. Crop to this photo's region, then normalise the origin so every later
        //    filter sees an extent starting at zero.
        let full = image.extent
        let crop = CGRect(
            x: full.minX + request.normalizedCrop.minX * full.width,
            y: full.minY + request.normalizedCrop.minY * full.height,
            width: request.normalizedCrop.width * full.width,
            height: request.normalizedCrop.height * full.height
        ).integral
        image = image.cropped(to: crop)
            .transformed(by: .init(translationX: -crop.minX, y: -crop.minY))

        // 2. Scale to the size we're actually going to draw, before the expensive
        //    per-pixel work. Filtering at display size instead of source size is most
        //    of the performance win in a grid.
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > request.targetMaxPixel, longEdge > 0 {
            let scale = request.targetMaxPixel / longEdge
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = image
            lanczos.scale = Float(scale)
            lanczos.aspectRatio = 1
            image = lanczos.outputImage ?? image.transformed(by: .init(scaleX: scale, y: scale))
        }

        let original = image
        image = applyRecipe(request.recipe, to: image, workMultiplier: request.workMultiplier)

        // 3. Intensity is a blend against the untouched image, which is what a slider
        //    in a photo editor actually means.
        let amount = min(max(request.intensity, 0), 1)
        if amount < 0.999, request.recipe.id != FilterRecipe.original.id {
            let mix = CIFilter.mix()
            mix.inputImage = image
            mix.backgroundImage = original
            mix.amount = Float(amount)
            image = mix.outputImage ?? image
        }

        // 4. Adjust runs *after* the preset, the way it does in VSCO: the preset is
        //    the look, the sliders are corrections on top of it.
        if !request.adjustments.isNeutral {
            image = applyAdjustments(request.adjustments, to: image, longEdge: request.targetMaxPixel)
        }

        let extent = image.extent.intersection(original.extent)
        guard !extent.isEmpty, let output = context.createCGImage(image, from: extent) else {
            throw RenderError.renderFailed
        }
        return ImageBox(output)
    }

    enum RenderError: Error { case renderFailed }

    private func applyRecipe(_ recipe: FilterRecipe, to input: CIImage, workMultiplier: Int) -> CIImage {
        guard recipe.id != FilterRecipe.original.id else { return input }
        var image = input

        if abs(recipe.temperature - 6500) > 1 || abs(recipe.tint) > 0.01 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: recipe.temperature, y: recipe.tint)
            image = f.outputImage ?? image
        }

        if abs(recipe.exposure) > 0.001 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(recipe.exposure)
            image = f.outputImage ?? image
        }

        do {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.saturation = Float(recipe.saturation)
            f.contrast = Float(recipe.contrast)
            f.brightness = Float(recipe.brightness)
            image = f.outputImage ?? image
        }

        if recipe.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(recipe.vibrance)
            image = f.outputImage ?? image
        }

        if recipe.shadowAmount != 0 || recipe.highlightAmount != 1 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.radius = 8
            f.shadowAmount = Float(recipe.shadowAmount)
            f.highlightAmount = Float(recipe.highlightAmount)
            image = f.outputImage ?? image
        }

        // Lifted, tinted blacks — the single move that reads most as "film".
        if recipe.shadowLift > 0.001 {
            let lift = recipe.shadowLift
            let f = CIFilter.colorMatrix()
            f.inputImage = image
            f.rVector = CIVector(x: CGFloat(1 - lift), y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: CGFloat(1 - lift), z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: CGFloat(1 - lift), w: 0)
            f.biasVector = CIVector(
                x: CGFloat(lift * recipe.splitTone.r),
                y: CGFloat(lift * recipe.splitTone.g),
                z: CGFloat(lift * recipe.splitTone.b),
                w: 0
            )
            // Bias vector ⇒ infinite extent; crop before anything downstream
            // (notably CIVignette, which derives its geometry from the extent).
            image = f.outputImage?.cropped(to: image.extent) ?? image
        }

        if recipe.grain > 0.001 {
            image = addGrain(to: image, amount: recipe.grain)
        }

        if recipe.vignette > 0.001 {
            let f = CIFilter.vignette()
            f.inputImage = image
            f.intensity = Float(recipe.vignette)
            f.radius = 1.6
            image = f.outputImage ?? image
        }

        // Optional extra passes so the concurrency story is visible on hardware fast
        // enough to hide it. Real work, not a sleep — a sleep would not contend for
        // the GPU the way a real filter chain does.
        if workMultiplier > 1 {
            for _ in 1..<workMultiplier {
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = image
                blur.radius = 1.2
                let blurred = (blur.outputImage ?? image).cropped(to: image.extent)
                let sharpen = CIFilter.unsharpMask()
                sharpen.inputImage = blurred
                sharpen.radius = 2.0
                sharpen.intensity = 0.6
                image = (sharpen.outputImage ?? blurred).cropped(to: image.extent)
            }
        }

        return image.cropped(to: input.extent)
    }

    /// Film grain from `CIRandomGenerator`.
    ///
    /// The subtlety that costs an afternoon: the generator's **RGB channels are
    /// premultiplied against a random alpha**, so they are skewed bright and clipped
    /// (measured mean 0.75, 5% of samples at pure white). Reading one of them as
    /// luminance and forcing alpha to 1 produces sparse blown-out pixels, not grain.
    /// The **alpha channel** is the clean uniform one — mean 0.502, sd 0.290 — so
    /// that's what we sample.
    /// The Adjust toolset.
    ///
    /// Every radius here is expressed for a 1000px long edge and then scaled to the
    /// image we're actually rendering. Without that, a thumbnail and its full-size
    /// export are not the same photograph — clarity and sharpen would be many times
    /// stronger on the 132pt tile than on the 2400px export, and the grid would be
    /// lying about what the user is going to get.
    private func applyAdjustments(_ adj: Adjustments, to input: CIImage, longEdge: CGFloat) -> CIImage {
        var image = input
        let extent = input.extent
        let unit = max(longEdge, 1) / 1000

        if adj.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(adj.exposure * 2)
            image = f.outputImage ?? image
        }

        if adj.temperature != 0 || adj.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 + adj.temperature * 2200, y: adj.tint * 40)
            image = f.outputImage ?? image
        }

        if adj.contrast != 0 || adj.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(1 + adj.contrast * 0.5)
            f.saturation = Float(1 + adj.saturation)
            f.brightness = 0
            image = f.outputImage ?? image
        }

        // Tone. A curve rather than CIHighlightShadowAdjust, because the curve is
        // genuinely bipolar — it can open shadows *or* crush them — and it costs a
        // fraction as much per pixel.
        if adj.highlights != 0 || adj.shadows != 0 {
            let f = CIFilter.toneCurve()
            f.inputImage = image
            f.point0 = CGPoint(x: 0, y: 0)
            f.point1 = CGPoint(x: 0.25, y: min(max(0.25 + adj.shadows * 0.16, 0), 1))
            f.point2 = CGPoint(x: 0.5, y: min(max(0.5 + (adj.shadows + adj.highlights) * 0.04, 0), 1))
            f.point3 = CGPoint(x: 0.75, y: min(max(0.75 + adj.highlights * 0.16, 0), 1))
            f.point4 = CGPoint(x: 1, y: 1)
            image = f.outputImage ?? image
        }

        // Clarity is local contrast: a wide-radius, low-intensity unsharp mask.
        if adj.clarity > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = image
            f.radius = Float(max(6, 24 * unit))
            f.intensity = Float(adj.clarity * 0.8)
            image = (f.outputImage ?? image).cropped(to: extent)
        }

        if adj.sharpen > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(adj.sharpen * 1.6)
            f.radius = Float(max(1, 1.6 * unit))
            image = (f.outputImage ?? image).cropped(to: extent)
        }

        if adj.fade > 0 {
            let lift = CGFloat(adj.fade * 0.17)
            let f = CIFilter.colorMatrix()
            f.inputImage = image
            f.rVector = CIVector(x: 1 - lift, y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: 1 - lift, z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: 1 - lift, w: 0)
            f.biasVector = CIVector(x: lift, y: lift, z: lift, w: 0)
            // Biased matrix ⇒ infinite extent. Crop before anything downstream.
            image = f.outputImage?.cropped(to: extent) ?? image
        }

        if adj.grain > 0 {
            image = addGrain(to: image, amount: adj.grain * 0.6)
        }

        if adj.vignette > 0 {
            let f = CIFilter.vignette()
            f.inputImage = image
            f.intensity = Float(adj.vignette * 1.4)
            f.radius = 1.6
            image = f.outputImage ?? image
        }

        return image.cropped(to: extent)
    }

    private func addGrain(to image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }

        let k = CGFloat(amount)
        let channel = CIVector(x: 0, y: 0, z: 0, w: k)   // alpha in, luminance out
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = noise.cropped(to: extent)
        matrix.rVector = channel
        matrix.gVector = channel
        matrix.bVector = channel
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        // Centre on 0.5 so soft-light is a no-op on average and only adds texture.
        matrix.biasVector = CIVector(x: 0.5 - k / 2, y: 0.5 - k / 2, z: 0.5 - k / 2, w: 1)

        // A bias vector gives the result infinite extent — it tints the whole plane.
        // Crop back, or every downstream filter works on an unbounded image.
        guard let grain = matrix.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = image
        return (blend.outputImage ?? image).cropped(to: extent)
    }
}
