#let project(body) = {
  // set page(
  //   paper: "a4",
  //   margin: (
  //     top: 2.5cm,
  //     bottom: 2.5cm,
  //     left: 2.5cm,
  //     right: 2.5cm,
  //   ),
  // )
  
  // set text(
  //   font: ("Times New Roman", "Source Han Serif SC"),
  //   size: 11pt,
  //   lang: "en",
  // )
  
  // set par(
  //   first-line-indent: 0pt,
  //   leading: 0.65em,
  //   justify: true,
  // )

  set page(
    paper: "a4",
    margin: 2.5cm,
    fill: rgb("#F6F1E3"),
  )
  
  set text(
    font: ("Times New Roman", "Source Han Serif SC"),
    size: 11pt,
    fill: rgb("#2B2B2B"),
  )
  
  set par(
    leading: 0.65em,
    justify: true,
  )
  
  body
}

// 在 common 样式中定义
#let noindent(content) = {
  set par(first-line-indent: 0pt)
  content
}
