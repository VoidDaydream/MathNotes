#let project(body) = {
  // 2. 设置字体和页面
set text(
  font: ("Times New Roman", "Source Han Serif SC"), // 优先英文，后接中文
  size: 11pt,
  lang: "en",
)
  set page(width: 10cm, height: auto)
  set par(first-line-indent: 1em)
  body
}

// 在 common 样式中定义
#let noindent(content) = {
  set par(first-line-indent: 0pt)
  content
}
