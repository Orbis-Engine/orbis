package dev.orbis.filament

/**
 * A scene as it arrives over the `orbis_filament` channel's `setScene` call,
 * parsed once so a malformed message is a channel error with something to
 * read rather than an out-of-bounds read inside the renderer.
 *
 * Mirrors OrbisFilamentPlugin.swift's private `Scene` struct field for
 * field, in the same order, so a change made to one is easy to find in the
 * other -- see that file for the fuller commentary on why each field is
 * shaped the way it is. Narrower than Swift's in one respect, disclosed
 * rather than silent: this checks that the arrays a call reads are the
 * *shape* the renderer needs (present when required, parallel arrays the
 * same length, a packed field a whole multiple of its stride), which is
 * what stands between a short array and a read past its end in C++. It does
 * not re-check that every index a field carries *points* somewhere valid
 * (a mesh index less than the path count, a light kind in 0...3) the way
 * Swift's `allSatisfy` clauses do -- those guard a hand-malformed or
 * malicious message, and every field here is instead trusted to be what
 * Dart's own `OrbisScene.toMessage()` already builds correctly, the one
 * place these numbers come from.
 *
 * Standard codec types arrive already typed -- a Dart `Float32List` is a
 * Kotlin `FloatArray`, `Int32List` an `IntArray`, `Int64List` a
 * `LongArray`, `Uint8List` a `ByteArray` -- so, unlike the Swift side, there
 * is no manual byte reinterpretation to do here at all.
 */
internal class OrbisScene private constructor(private val args: Map<String, Any?>) {
    val count: Int = args.floats("transforms").size / 16
    val keys: LongArray = args.longs("objectKeys")
    val transforms: FloatArray = args.floats("transforms")
    val colours: FloatArray = args.floats("colours")
    val meshes: IntArray = args.ints("meshes")
    val flags: IntArray = args.ints("objectFlags")
    val paths: List<String> = args.strings("meshPaths")
    val objectMaterials: IntArray =
        args.intsOr("objectMaterials") { IntArray(count) { -1 } }
    val objectMorphCounts: IntArray = args.intsOr("objectMorphCounts") { IntArray(count) }
    val objectMorphWeights: FloatArray = args.floats("objectMorphWeights")

    val materialKeys: LongArray = args.longs("materialKeys")
    val materialFlags: IntArray = args.ints("materialFlags")
    val materialParams: FloatArray = args.floats("materialParams")
    val materialMaps: IntArray = args.ints("materialMaps")
    val texturePaths: List<String> = args.strings("texturePaths")
    val textureSrgb: IntArray = args.ints("textureSrgb")
    val materialVideos: IntArray =
        args.intsOr("materialVideos") { IntArray(materialKeys.size) { -1 } }

    val videoKeys: LongArray = args.longs("videoKeys")
    val videoFlags: IntArray = args.ints("videoFlags")
    val videoParams: FloatArray = args.floats("videoParams")
    val videoPaths: List<String> = args.strings("videoPaths")

    val lightKeys: LongArray = args.longs("lightKeys")
    val lightKinds: IntArray = args.ints("lightKinds")
    val lightFlags: IntArray = args.ints("lightFlags")
    val lightParams: FloatArray = args.floats("lightParams")

    val probeKeys: LongArray = args.longs("probeKeys")
    val probeParams: FloatArray = args.floats("probeParams")

    val fieldParams: FloatArray = args.floats("fieldParams")
    val fieldFrom: String = args.strings0("fieldFrom")

    val cameraPosition: FloatArray = args.floats("cameraPosition")
    val cameraTarget: FloatArray = args.floats("cameraTarget")
    val fieldOfView: Float = args.numOr("fieldOfView", 45.0).toFloat()
    val aperture: Float = args.numOr("aperture", 16.0).toFloat()
    val shutterSpeed: Float = args.numOr("shutterSpeed", 1.0 / 125.0).toFloat()
    val sensitivity: Float = args.numOr("sensitivity", 100.0).toFloat()
    val orthographic: Boolean = args["orthographic"] as? Boolean ?: false
    val viewHeight: Float = args.numOr("viewHeight", 1.0).toFloat()
    val at: Double = args.numOr("at", 0.0)

    val skyColour: FloatArray = args.floats("skyColour")
    val ambient: Float = args.numOr("ambient", 0.0).toFloat()
    val showBody: Boolean = args["showBody"] as? Boolean ?: false

    val fogEnabled: Boolean = args["fogEnabled"] as? Boolean ?: false
    val fogParams: FloatArray = args.floats("fogParams")
    val precipitationEnabled: Boolean = args["precipitationEnabled"] as? Boolean ?: false
    val precipitationParams: FloatArray = args.floats("precipitationParams")
    val skyEnabled: Boolean = args["skyEnabled"] as? Boolean ?: false
    val skyParams: FloatArray = args.floats("skyParams")
    val batching: Boolean = args["batching"] as? Boolean ?: false

    val postParams: FloatArray = args.floats("postParams")
    val pipelineParams: FloatArray = args.floats("pipelineParams")

    val environmentRadiance: String = args.strings0("environmentRadiance")
    val environmentSkybox: String = args.strings0("environmentSkybox")
    val environmentParams: FloatArray = args.floats("environmentParams")

    val graphPasses: FloatArray = args.floats("graphPasses")
    val graphTargets: FloatArray = args.floats("graphTargets")
    val graphTargetNames: List<String> = args.strings("graphTargetNames")

    val outlineKeys: LongArray = args.longs("outlineKeys")
    val outlineParams: FloatArray = args.floats("outlineParams")
    val godRayParams: FloatArray = args.floats("godRayParams")
    val distortionParams: FloatArray = args.floats("distortionParams")

    val populationKeys: IntArray = args.ints("populationKeys")
    val populationCounts: IntArray = args.ints("populationCounts")
    val populationMeshes: IntArray = args.ints("populationMeshes")
    val populationFlags: IntArray = args.ints("populationFlags")
    val populationRevisions: IntArray = args.ints("populationRevisions")
    val populationRanges: FloatArray = args.floats("populationRanges")
    val populationBounds: FloatArray = args.floats("populationBounds")
    val populationPaths: List<String> = args.strings("populationPaths")
    val populationChanged: IntArray = args.ints("populationChanged")
    val populationTransforms: FloatArray = args.floats("populationTransforms")
    val populationColours: FloatArray = args.floats("populationColours")

    val decalParams: FloatArray = args.floats("decalParams")
    val decalImages: IntArray = args.ints("decalImages")
    val decalPaths: List<String> = args.strings("decalPaths")

    // Splats: OrbisSplatMessage.swift's own field names, unchanged.
    val splatKeys: IntArray = args.ints("splatKeys")
    val splatFlags: IntArray = args.ints("splatFlags")
    val splatRevisions: IntArray = args.ints("splatRevisions")
    val splatParams: FloatArray = args.floats("splatParams")
    val splatPaths: List<String> = args.strings("splatPaths")
    val splatChanged: IntArray = args.ints("splatChanged")
    val splatChangedCounts: IntArray = args.ints("splatChangedCounts")
    val splatData: ByteArray = args.bytes("splatData")

    /** Applies every part of the scene, in the order Viewport.write(scene:) does. */
    fun applyTo(handle: Long) {
        OrbisNative.nativeSetEnvironment(handle, environmentRadiance, environmentSkybox, environmentParams)

        OrbisNative.nativeSetRenderGraph(handle, graphPasses, graphTargets, graphTargetNames.toTypedArray())

        OrbisNative.nativeSetBatching(handle, batching)
        OrbisNative.nativeSetGodRays(handle, godRayParams, distortionParams)

        OrbisNative.nativeApplyVideos(handle, videoKeys, videoFlags, videoParams, videoPaths.toTypedArray())

        OrbisNative.nativeApplyMaterials(
            handle,
            materialKeys,
            materialFlags,
            materialParams,
            materialMaps,
            texturePaths.toTypedArray(),
            textureSrgb,
            materialVideos,
        )

        OrbisNative.nativeApplyObjects(
            handle,
            keys,
            transforms,
            colours,
            meshes,
            flags,
            objectMaterials,
            objectMorphCounts,
            objectMorphWeights,
            paths.toTypedArray(),
        )

        if (populationKeys.isNotEmpty()) {
            OrbisNative.nativeApplyPopulations(
                handle,
                populationKeys,
                populationCounts,
                populationMeshes,
                populationFlags,
                populationRevisions,
                populationRanges,
                populationBounds,
                populationPaths.toTypedArray(),
                populationChanged,
                populationTransforms,
                populationColours,
            )
        }

        OrbisNative.nativeApplySplats(
            handle,
            splatKeys,
            splatFlags,
            splatRevisions,
            splatParams,
            splatPaths.toTypedArray(),
            splatChanged,
            splatChangedCounts,
            splatData,
        )

        OrbisNative.nativeApplyLights(handle, lightKeys, lightKinds, lightFlags, lightParams)

        OrbisNative.nativeApplyDecals(handle, decalParams, decalImages, decalPaths.toTypedArray())

        OrbisNative.nativeApplyProbes(handle, probeKeys, probeParams)

        if (fieldParams.isNotEmpty()) OrbisNative.nativeApplyField(handle, fieldParams, fieldFrom)

        OrbisNative.nativeSetSkyColour(handle, skyColour, ambient, showBody)
        OrbisNative.nativeSetFog(handle, fogEnabled, fogParams)
        if (postParams.isNotEmpty()) OrbisNative.nativeSetPostProcess(handle, postParams)
        if (pipelineParams.isNotEmpty()) OrbisNative.nativeSetPipeline(handle, pipelineParams)
        OrbisNative.nativeSetPrecipitation(handle, precipitationEnabled, precipitationParams)
        OrbisNative.nativeSetSky(handle, skyEnabled, skyParams)
        OrbisNative.nativeSetCamera(
            handle, cameraPosition, cameraTarget, fieldOfView, orthographic, viewHeight, at)
        OrbisNative.nativeSetExposure(handle, aperture, shutterSpeed, sensitivity)

        OrbisNative.nativeSetOutline(handle, outlineKeys, outlineParams)
    }

    companion object {
        /**
         * Null for a message missing what every scene must carry: the
         * object arrays and a camera. Everything else -- lights, materials,
         * populations, splats, an environment, a graph -- is optional the
         * same way Swift's Scene.init treats it: absent decodes to "this
         * part of the scene has nothing to say" rather than refusing the
         * message. Also null when the object arrays disagree on length,
         * which the ABI would otherwise read as a short array past its end.
         */
        fun from(args: Map<String, Any?>): OrbisScene? {
            if (args["objectKeys"] !is LongArray ||
                args["transforms"] !is FloatArray ||
                args["colours"] !is FloatArray ||
                args["meshes"] !is IntArray ||
                args["objectFlags"] !is IntArray ||
                args["cameraPosition"] !is FloatArray ||
                args["cameraTarget"] !is FloatArray
            ) {
                return null
            }
            val scene = OrbisScene(args)
            val count = scene.count
            if (scene.keys.size != count ||
                scene.meshes.size != count ||
                scene.flags.size != count ||
                scene.colours.size != count * 3 ||
                scene.cameraPosition.size != 3 ||
                scene.cameraTarget.size != 3
            ) {
                return null
            }
            return scene
        }
    }
}

// ---- Map<String, Any?> helpers -------------------------------------------
//
// The standard method codec already hands typed arrays across the channel
// (a Dart Float32List decodes straight to a Kotlin FloatArray, and so on),
// so these only supply the "absent means empty" default every optional
// field in OrbisFilamentPlugin.swift's Scene also has.

private fun Map<String, Any?>.floats(key: String): FloatArray = this[key] as? FloatArray ?: FloatArray(0)

private fun Map<String, Any?>.ints(key: String): IntArray = this[key] as? IntArray ?: IntArray(0)

private inline fun Map<String, Any?>.intsOr(key: String, default: () -> IntArray): IntArray =
    this[key] as? IntArray ?: default()

private fun Map<String, Any?>.longs(key: String): LongArray = this[key] as? LongArray ?: LongArray(0)

private fun Map<String, Any?>.bytes(key: String): ByteArray = this[key] as? ByteArray ?: ByteArray(0)

@Suppress("UNCHECKED_CAST")
private fun Map<String, Any?>.strings(key: String): List<String> =
    (this[key] as? List<Any?>)?.map { it as? String ?: "" } ?: emptyList()

private fun Map<String, Any?>.strings0(key: String): String = this[key] as? String ?: ""

private fun Map<String, Any?>.numOr(key: String, default: Double): Double =
    (this[key] as? Number)?.toDouble() ?: default
