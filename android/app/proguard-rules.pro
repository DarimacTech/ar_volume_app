# ARCore and Sceneform rules
-keep class com.google.ar.core.** { *; }
-keep class com.google.ar.sceneform.** { *; }
-keep class com.google.android.filament.** { *; }

# Suppress warnings for missing classes that are not used at runtime or are optional
-dontwarn com.google.ar.sceneform.animation.AnimationEngine
-dontwarn com.google.ar.sceneform.animation.AnimationLibraryLoader
-dontwarn com.google.ar.sceneform.assets.Loader
-dontwarn com.google.ar.sceneform.assets.ModelData
-dontwarn com.google.devtools.build.android.desugar.runtime.ThrowableExtension

# General Flutter Proguard rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Suppress warnings for optional Play Core dependencies (Deferred Components)
-dontwarn com.google.android.play.core.**
