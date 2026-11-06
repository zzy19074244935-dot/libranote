# Libranote R8 规则
#
# google_mlkit_text_recognition 插件的 initialize() 里无条件引用了
# 日/韩/梵文三个脚本识别类，但我们只用中文脚本（text-recognition-chinese
# 已在 build.gradle 里加入）。未加入的模型类在 R8 眼里是 missing class，
# 按 AGP 生成的 missing_rules.txt 加上 dontwarn 抑制。
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
