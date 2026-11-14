import Foundation

/// i18n 打底（2026-11-14）：所有面向用户的文案一律走本函数，
/// 资源文件在 Resources/<lang>.lproj/Localizable.strings，
/// 构建脚本会拷进 app bundle 的 Contents/Resources。
/// 约定：代码里只写语义化 key，不写死任何语言。
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
