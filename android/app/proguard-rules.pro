-keepattributes *Annotation*,InnerClasses,EnclosingMethod,Signature

# kotlinx.serialization relies on generated serializer classes and metadata.
-keep class kotlinx.serialization.** { *; }
-keep class **$$serializer { *; }
-keepclassmembers class ** {
    *** Companion;
}
-keepclasseswithmembers class ** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep @kotlinx.serialization.Serializable class com.rhymeai.app.** { *; }

# Gemini SDK request/response models are serialized reflectively inside the SDK.
-keep class com.google.ai.client.generativeai.** { *; }
-keep class com.google.ai.client.generativeai.type.** { *; }
-dontwarn com.google.ai.client.generativeai.**

# llama.cpp Kotlin bridges into native code and emits callback event types.
-keep class org.nehuatl.llamacpp.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}
-dontwarn org.nehuatl.llamacpp.**
