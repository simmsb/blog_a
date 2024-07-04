#import "/templates/base.typ": base, colors
#import "/utils/common.typ": cls
#import "/site.typ": info

#let page(title: none, body) = {
  let page-title = if title != none { title + " | " + info.title } else {
    info.title
  }

  show: base.with(head: html.title(page-title))

  show heading.where(level: 1): it => html.h2(class: cls(
    "text-2xl font-bold mt-8 mb-4",
    colors.accent,
  ))[#it.body]
  show heading.where(level: 2): it => html.h3(
    class: "text-xl font-semibold mt-6 mb-3",
  )[#it.body]

  body
}
