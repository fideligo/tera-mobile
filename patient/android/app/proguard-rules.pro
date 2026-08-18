# ML Kit text recognition ships one plugin entry point that names every script variant it can
# construct — Latin, Chinese, Devanagari, Japanese, Korean — while the app depends on the Latin
# bundle alone. R8 sees the references, cannot find the classes, and fails the release build:
#
#   Missing class com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
#
# Silenced rather than fixed by adding the other bundles. Each one is several megabytes of model
# for a script no Tera user is reading a tensimeter in, and the code path that would reach them is
# unreachable: `CameraCuffOcrExtractor` constructs `TextRecognitionScript.latin` and nothing else.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
