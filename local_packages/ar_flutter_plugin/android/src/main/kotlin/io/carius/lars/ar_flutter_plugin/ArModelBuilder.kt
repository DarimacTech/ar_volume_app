package io.carius.lars.ar_flutter_plugin

import android.R
import android.app.Activity
import android.content.Context
import com.google.ar.sceneform.Node
import com.google.ar.sceneform.math.Vector3
import com.google.ar.sceneform.math.Quaternion
import com.google.ar.sceneform.assets.RenderableSource

import com.google.ar.sceneform.rendering.RenderableDefinition
import com.google.ar.sceneform.rendering.Vertex
import java.util.Arrays
import java.util.concurrent.CompletableFuture
import android.net.Uri
import android.view.Gravity
import android.widget.Toast
import com.google.ar.core.*
import com.google.ar.sceneform.ArSceneView
import com.google.ar.sceneform.FrameTime
import com.google.ar.sceneform.math.MathHelper
import com.google.ar.sceneform.rendering.*
import com.google.ar.sceneform.utilities.Preconditions
import com.google.ar.sceneform.ux.*

import io.carius.lars.ar_flutter_plugin.Serialization.*

import io.flutter.FlutterInjector
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.AccessController


// Responsible for creating Renderables and Nodes
class ArModelBuilder {

    // Creates a cyan sphere marker node (NO network required).
    // Returns CompletableFuture<Node> so caller waits until renderable is ready.
    fun makeSphereMarkerNode(context: Context, radius: Float = 0.025f): CompletableFuture<Node> {
        val future = CompletableFuture<Node>()
        val markerNode = Node()
        MaterialFactory.makeOpaqueWithColor(context, Color(android.graphics.Color.CYAN))
            .thenAccept { material ->
                val sphere = ShapeFactory.makeSphere(radius, Vector3(0f, 0f, 0f), material)
                sphere.isShadowCaster = false
                sphere.isShadowReceiver = false
                markerNode.renderable = sphere
                future.complete(markerNode) // only resolves AFTER renderable is set
            }
            .exceptionally { throwable ->
                future.completeExceptionally(throwable)
                null
            }
        return future
    }

    // Creates a cylinder to represent a line between two 3D points (NO network required)
    fun makeCylinderLineNode(
        context: Context,
        from: Vector3,
        to: Vector3,
        color: android.graphics.Color = android.graphics.Color.valueOf(1f, 1f, 0f), // Yellow
        radius: Float = 0.005f
    ): Node {
        val lineNode = Node()
        val diff = Vector3.subtract(to, from)
        val length = diff.length()

        // Guard: skip zero-length lines (from ≈ to) → avoids NaN crash
        if (length < 0.001f) return lineNode

        val midpoint = Vector3.add(from, to).scaled(0.5f)

        // Guard: if diff is parallel to Vector3.up(), use forward as up-hint
        // to avoid undefined lookRotation (cross product = zero)
        val diffNorm = diff.normalized()
        val dotWithUp = Math.abs(Vector3.dot(diffNorm, Vector3.up()).toDouble()).toFloat()
        val upHint = if (dotWithUp > 0.99f) Vector3.forward() else Vector3.up()
        val rotation = Quaternion.lookRotation(diffNorm, upHint)

        lineNode.worldPosition = midpoint
        lineNode.worldRotation = rotation

        MaterialFactory.makeOpaqueWithColor(
            context,
            Color(color.red(), color.green(), color.blue())
        ).thenAccept { material ->
            val cylinder = ShapeFactory.makeCylinder(radius, length, Vector3(0f, 0f, 0f), material)
            cylinder.isShadowCaster = false
            cylinder.isShadowReceiver = false
            lineNode.renderable = cylinder
        }
        return lineNode
    }

    // Creates feature point node
    fun makeFeaturePointNode(context: Context, xPos: Float, yPos: Float, zPos: Float): Node {
        val featurePoint = Node()                 
        var cubeRenderable: ModelRenderable? = null      
        MaterialFactory.makeOpaqueWithColor(context, Color(android.graphics.Color.YELLOW))
        .thenAccept { material ->
            val vector3 = Vector3(0.015f, 0.015f, 0.015f)
            cubeRenderable = ShapeFactory.makeCube(vector3, Vector3(xPos, yPos, zPos), material)
            cubeRenderable?.isShadowCaster = false
            cubeRenderable?.isShadowReceiver = false
        }
        featurePoint.renderable = cubeRenderable

        return featurePoint
    }

    // Creates a coordinate system model at the world origin (X-axis: red, Y-axis: green, Z-axis:blue)
    // The code for this function is adapted from Alexander's stackoverflow answer (https://stackoverflow.com/questions/48908358/arcore-how-to-display-world-origin-or-axes-in-debug-mode) 
    fun makeWorldOriginNode(context: Context): Node {
        val axisSize = 0.1f
        val axisRadius = 0.005f

        val rootNode = Node()
        val xNode = Node()
        val yNode = Node()
        val zNode = Node()

        rootNode.addChild(xNode)
        rootNode.addChild(yNode)
        rootNode.addChild(zNode)

        xNode.worldPosition = Vector3(axisSize / 2, 0f, 0f)
        xNode.worldRotation = Quaternion.axisAngle(Vector3(0f, 0f, 1f), 90f)

        yNode.worldPosition = Vector3(0f, axisSize / 2, 0f)

        zNode.worldPosition = Vector3(0f, 0f, axisSize / 2)
        zNode.worldRotation = Quaternion.axisAngle(Vector3(1f, 0f, 0f), 90f)

        MaterialFactory.makeOpaqueWithColor(context, Color(255f, 0f, 0f))
                .thenAccept { redMat ->
                    xNode.renderable = ShapeFactory.makeCylinder(axisRadius, axisSize, Vector3.zero(), redMat)
                }

        MaterialFactory.makeOpaqueWithColor(context, Color(0f, 255f, 0f))
                .thenAccept { greenMat ->
                    yNode.renderable = ShapeFactory.makeCylinder(axisRadius, axisSize, Vector3.zero(), greenMat)
                }

        MaterialFactory.makeOpaqueWithColor(context, Color(0f, 0f, 255f))
                .thenAccept { blueMat ->
                    zNode.renderable = ShapeFactory.makeCylinder(axisRadius, axisSize, Vector3.zero(), blueMat)
                }

        return rootNode
    }

    // Creates a node form a given gltf model path or URL. The gltf asset loading in Scenform is asynchronous, so the function returns a completable future of type Node
    fun makeNodeFromGltf(context: Context, transformationSystem: TransformationSystem, objectManagerChannel: MethodChannel, enablePans: Boolean, enableRotation: Boolean, name: String, modelPath: String, transformation: ArrayList<Double>): CompletableFuture<CustomTransformableNode> {
        val completableFutureNode: CompletableFuture<CustomTransformableNode> = CompletableFuture()

        val gltfNode = CustomTransformableNode(transformationSystem, objectManagerChannel, enablePans, enableRotation)

        ModelRenderable.builder()
                .setSource(context, RenderableSource.builder().setSource(
                        context,
                        Uri.parse(modelPath),
                        RenderableSource.SourceType.GLTF2)
                        .build())
                .setRegistryId(modelPath)
                .build()
                .thenAccept{ renderable ->
                    gltfNode.renderable = renderable
                    gltfNode.name = name
                    val transform = deserializeMatrix4(transformation)
                    gltfNode.worldScale = transform.first
                    gltfNode.worldPosition = transform.second
                    gltfNode.worldRotation = transform.third
                    completableFutureNode.complete(gltfNode)
                }
                .exceptionally { throwable ->
                    completableFutureNode.completeExceptionally(throwable)
                    null // return null because java expects void return (in java, void has no instance, whereas in Kotlin, this closure returns a Unit which has one instance)
                }

    return completableFutureNode
    }

    // Creates a node form a given glb model path or URL. The gltf asset loading in Sceneform is asynchronous, so the function returns a compleatable future of type Node
    fun makeNodeFromGlb(context: Context, transformationSystem: TransformationSystem, objectManagerChannel: MethodChannel, enablePans: Boolean, enableRotation: Boolean, name: String, modelPath: String, transformation: ArrayList<Double>): CompletableFuture<CustomTransformableNode> {
        val completableFutureNode: CompletableFuture<CustomTransformableNode> = CompletableFuture()

        val gltfNode = CustomTransformableNode(transformationSystem, objectManagerChannel, enablePans, enableRotation)
        //gltfNode.scaleController.isEnabled = false
        //gltfNode.translationController.isEnabled = false

        /*gltfNode.removeTransformationController(translationController)
        gltfNode.addTra
        val customTranslationController = DragController(
            gltfNode,
            transformationSystem.dragRecognizer,
            objectManagerChannel,
            transformationSystem
        )*/

        ModelRenderable.builder()
                .setSource(context, RenderableSource.builder().setSource(
                        context,
                        Uri.parse(modelPath),
                        RenderableSource.SourceType.GLB)
                        .build())
                .setRegistryId(modelPath)
                .build()
                .thenAccept{ renderable ->
                    gltfNode.renderable = renderable
                    gltfNode.name = name
                    val transform = deserializeMatrix4(transformation)
                    gltfNode.worldScale = transform.first
                    gltfNode.worldPosition = transform.second
                    gltfNode.worldRotation = transform.third
                    completableFutureNode.complete(gltfNode)
                }
                .exceptionally{throwable ->
                    completableFutureNode.completeExceptionally(throwable)
                    null // return null because java expects void return (in java, void has no instance, whereas in Kotlin, this closure returns a Unit which has one instance)
                }

        return completableFutureNode
    }
    // Creates a semi-transparent 3D box (mesh) from 8 corners
    fun makeComplexBoxNode(context: Context, points: List<Vector3>): CompletableFuture<Node> {
        val future = CompletableFuture<Node>()
        val boxNode = Node()

        // Material: Semi-transparent Cyan (Glass effect)
        MaterialFactory.makeTransparentWithColor(context, Color(0f, 1f, 1f, 0.3f))
            .thenAccept { material ->
                material.setFloat("roughness", 0.2f)
                material.setFloat("reflectance", 0.8f)

                // Define 8 vertices based on the points
                val vertices = points.map { Vertex.builder().setPosition(it).build() }

                // Define 12 triangles (2 per face) for 6 faces
                // Assuming points: 0-3 base (CCW), 4-7 top (CCW)
                val indices = mutableListOf<Int>()
                
                // Base face
                indices.addAll(listOf(0, 1, 2, 0, 2, 3))
                // Top face
                indices.addAll(listOf(4, 5, 6, 4, 6, 7))
                // Side faces
                indices.addAll(listOf(0, 1, 5, 0, 5, 4)) // Front
                indices.addAll(listOf(1, 2, 6, 1, 6, 5)) // Right
                indices.addAll(listOf(2, 3, 7, 2, 7, 6)) // Back
                indices.addAll(listOf(3, 0, 4, 3, 4, 7)) // Left

                val submesh = RenderableDefinition.Submesh.builder()
                    .setTriangleIndices(indices)
                    .setMaterial(material)
                    .build()

                val definition = RenderableDefinition.builder()
                    .setVertices(vertices)
                    .setSubmeshes(listOf(submesh))
                    .build()

                ModelRenderable.builder()
                    .setSource(definition)
                    .build()
                    .thenAccept { renderable ->
                        renderable.isShadowCaster = false
                        renderable.isShadowReceiver = false
                        boxNode.renderable = renderable
                        future.complete(boxNode)
                    }
            }
        return future
    }
}


class CustomTransformableNode(transformationSystem: TransformationSystem, objectManagerChannel: MethodChannel, enablePans: Boolean, enableRotation: Boolean) :
    TransformableNode(transformationSystem) { //

    private lateinit var customTranslationController: CustomTranslationController

    private lateinit var customRotationController: CustomRotationController

    init {
        // Remove standard controllers
        translationController.isEnabled = false
        rotationController.isEnabled = false
        scaleController.isEnabled = false
        removeTransformationController(translationController)
        removeTransformationController(rotationController)
        removeTransformationController(scaleController)


        // Add custom controllers if needed
        if (enablePans) {
            customTranslationController = CustomTranslationController(
                this,
                transformationSystem.dragRecognizer,
                objectManagerChannel
            )
            addTransformationController(customTranslationController)
        }
        if (enableRotation) {
            customRotationController = CustomRotationController(
                this,
                transformationSystem.twistRecognizer,
                objectManagerChannel
            )
            addTransformationController(customRotationController)
        }
    }
}

class CustomTranslationController(transformableNode: BaseTransformableNode, gestureRecognizer: DragGestureRecognizer, objectManagerChannel: MethodChannel) :
    TranslationController(transformableNode, gestureRecognizer) {

    val platformChannel: MethodChannel = objectManagerChannel

    override fun canStartTransformation(gesture: DragGesture): Boolean {
        platformChannel.invokeMethod("onPanStart", transformableNode.name)
        super.canStartTransformation(gesture)
        return transformableNode.isSelected
    }

    override fun onContinueTransformation(gesture: DragGesture) {
        platformChannel.invokeMethod("onPanChange", transformableNode.name)
        super.onContinueTransformation(gesture)
        }

    override fun onEndTransformation(gesture: DragGesture) {
        val serializedLocalTransformation = serializeLocalTransformation(transformableNode)
        platformChannel.invokeMethod("onPanEnd", serializedLocalTransformation)
        super.onEndTransformation(gesture)
     }
}


class CustomRotationController(transformableNode: BaseTransformableNode, gestureRecognizer: TwistGestureRecognizer, objectManagerChannel: MethodChannel) :
    RotationController(transformableNode, gestureRecognizer) {

    val platformChannel: MethodChannel = objectManagerChannel

    override fun canStartTransformation(gesture: TwistGesture): Boolean {
        platformChannel.invokeMethod("onRotationStart", transformableNode.name)
        super.canStartTransformation(gesture)
        return transformableNode.isSelected
    }

    override fun onContinueTransformation(gesture: TwistGesture) {
        platformChannel.invokeMethod("onRotationChange", transformableNode.name)
        super.onContinueTransformation(gesture)
    }

    override fun onEndTransformation(gesture: TwistGesture) {
        val serializedLocalTransformation = serializeLocalTransformation(transformableNode)
        platformChannel.invokeMethod("onRotationEnd", serializedLocalTransformation)
        super.onEndTransformation(gesture)
     }
}
