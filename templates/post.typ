#import "/templates/base.typ": base, colors, with-embedded-file
#import "/components/layout.typ" as layout
#import "/utils/common.typ": cls, og-tags, parse-date, to-string
#import "/site.typ": info

#let post(
  title: none,
  date: none,
  slug: none,
  tags: (),
  summary: none,
  body,
) = {
  let date = parse-date(date)

  let page-title = if title != none { title + " | " + info.title } else {
    info.title
  }

  set document(date: date, description: summary, keywords: tags)

  show: base.with(head: [
    #html.title(page-title)
    #og-tags(
      title: title,
      description: summary,
      type: "article",
      site-name: info.title,
      published: date,
      tags: tags,
    )
  ])

  let heading-id(text) = lower(to-string(text).replace("/", "-"))

  let header-view = html.div(class: "space-y-0")[
    #html.div({
      html.a(href: "..")[..]
      "/"
      html.span(class: "text-accent")[#slug]
    })

    #html.time(datetime: date)[
      Published on #html.span(class: "text-accent")[#date.display("[year]-[month]-[day]")]
    ]

    #html.address[
      By #html.span(class: "text-accent")[#info.author]
    ]
  ]

  let anchor-class = "text-current no-underline px-0 rounded-none hover:bg-transparent hover:text-current hover:underline underline-offset-4"

  show heading.where(level: 1): it => {
    let id = heading-id(it.body)
    html.h2(class: cls("text-2xl font-bold mt-8 mb-4", colors.accent), id: id)[
      #html.a(class: anchor-class, href: "#" + id)[#it.body]
    ]
  }
  show heading.where(level: 2): it => {
    let id = heading-id(it.body)
    html.h3(class: "text-xl font-semibold mt-6 mb-3", id: id)[
      #html.a(class: anchor-class, href: "#" + id)[#it.body]
    ]
  }

  let title-view = if title != none {
    html.h1(class: "text-2xl sm:text-2xl font-bold my-6")[#title]
  }

  let subtitle-view = if date != none or info.author != none {
    let parts = ()
    if date != none { parts.push(date.display("[year]-[month]-[day]")) }
    if info.author != none { parts.push("by " + info.author) }
    html.div(class: cls("", colors.muted))[#parts.join(" · ")]
  }

  let summary-view = if summary != none {
    html.div(class: cls(" italic my-4", colors.muted))[#summary]
  }

  let tags-view = if tags.len() > 0 {
    html.div(class: "flex flex-wrap justify-center gap-2 my-4")[
      #for tag in tags {
        html.span(
          class: "px-2 py-1 text-sm bg-surface rounded text-accent",
        )[#tag]
      }
    ]
  }

  [
    #header-view
    #title-view

    #summary-view

    #html.div(id: "sidenote-anchor-top")[]

    #body
  ]
}
