#import "@preview/typsy:0.2.4": tree-counter
#import "@preview/zebraw:0.6.3": zebraw, zebraw-init
#import "@preview/pleast:0.3.0": plist
#import "/utils/common.typ": cls
#import "/utils/counters.typ": reset-counters
#import "/site.typ": info

#let colors = (
  accent: "text-accent",
  muted: "text-muted",
)

#let inside-figure = state("_inside-figure", false)

#let bounded(eq) = text(top-edge: "bounds", bottom-edge: "bounds", eq)
#let equations-height-dict = state("eq_height_dict", (:))
#let is-inside-pin = state("inside_pin", false)

#let pin(label) = context {
  let height = here().position().y
  equations-height-dict.update(dict => {
    if label in dict.keys() or height < 0.000001pt {
      dict
    } else {
      dict.insert(label, height)
      dict
    }
  })
}

#let add-pin(eq) = {
  let label = repr(eq)
  is-inside-pin.update(true)
  $ inline(pin(label)#bounded(eq)) $
  is-inside-pin.update(false)
}

#let to-em(pt) = str(pt / text.size.pt()) + "em"

#let math-span(class: "", style: none, body) = {
  let attrs = (role: "math")
  if class != "" {
    attrs.insert("class", class)
  }
  if style != none {
    attrs.insert("style", style)
  }
  html.elem("span", body, attrs: attrs)
}

#let embedded-image-label = label("embedded-image-label")
#let image-id-counter = counter(embedded-image-label)

#let embedded-file-label = label("embedded-file-label")

// #let per-document-label = label("per-document-label")
#let per-document-tree-counter = tree-counter(() => {})

#let with-embedded-file(src, cb, at: none) = {
  let filepath = if at != none {
    at
  } else {
    let fname = str(src).split("/").last()
    "/resource/" + fname
  }

  [
    #metadata((
      path: filepath,
      source: path(src),
    )) #embedded-file-label
    #cb(filepath)
  ]
}

#let render-inline-math(eq, class: "") = context {
  if is-inside-pin.get() {
    return math-span(class: class)[#html.frame(bounded(eq))]
  }

  let label = repr(eq)
  let cache = equations-height-dict.final()
  if label in cache.keys() {
    let reference-height = cache.at(label, default: none)
    equations-height-dict.update(dict => {
      dict.insert(label, reference-height)
      dict
    })

    let measured-height = measure(bounded(eq)).height
    let shift = measured-height - reference-height
    let style = "vertical-align: -" + to-em(shift.pt()) + ";"
    math-span(class: class, style: style)[#html.frame(bounded(eq))]
  } else {
    math-span(class: class)[#box(html.frame(add-pin(eq)))]
  }
}

#let base-show(
  // CSS classes for customization
  figure-class: "",
  math-inline-class: "",
  math-block-class: "",
  // Math font (string or array for fallback)
  math-font: "New Computer Modern Math",
  body,
) = {
  show math.equation: set text(
    font: math-font,
    top-edge: "bounds",
    bottom-edge: "bounds",
  )

  // Math equations: use target()
  // - html.frame() internally renders to SVG using "paged" mode
  // - target() returns "paged" inside html.frame(), so the show rule skips
  show math.equation.where(block: false): it => context {
    if target() == "html" and not inside-figure.get() {
      render-inline-math(it, class: math-inline-class)
    } else { it }
  }

  show math.equation.where(block: true): it => context {
    if target() == "html" and not inside-figure.get() {
      html.div(class: math-block-class, role: "math")[#html.frame(it)]
    } else { it }
  }

  show image: it => {
    let ext = str(it.source).split(".").last()
    let filepath = "/images/" + image-id-counter.display() + "." + ext
    [
      #metadata((
        path: filepath,
        source: path(it.source),
      )) #embedded-image-label

      #html.img(src: filepath, loading: "lazy", alt: if it.alt != none { it.alt } else { "" })
    ]
  }

  body
}

#let video(src) = context {
  let ext = str(src).split(".").last()
  let filepath = "/videos/" + image-id-counter.display() + "." + ext

  [
    #metadata((
      path: filepath,
      source: path(src),
    )) #embedded-image-label
    #html.video(
      controls: true,
      src: filepath,
    )[Your browser does not support the video tag]
  ]
}

#let doc-head(head) = html.head[
  #html.meta(charset: "utf-8")
  #html.elem("meta", attrs: (
    name: "viewport",
    content: "width=device-width, initial-scale=1",
  ))

  #let fonts = (
    "fonts/lmmono-italic-webfont.eot",
    "fonts/lmmono-italic-webfont.woff",
    "fonts/lmmono-italic-webfont.ttf",
    "fonts/lmmono-regular-webfont.eot",
    "fonts/lmmono-regular-webfont.woff",
    "fonts/lmmono-regular-webfont.ttf",
  )

  #for font in fonts [
    #with-embedded-file(
      "../assets/" + font,
      p => {},
      at: font,
    )
  ]

  #with-embedded-file(
    "../assets/styles/latin-modern.css",
    p => html.elem("link", attrs: (rel: "stylesheet", href: p)),
  )
  #with-embedded-file("../generated/tailwind.css", p => html.elem(
    "link",
    attrs: (rel: "stylesheet", href: p),
  ))
  #with-embedded-file("../assets/scripts/script.js", p => html.elem(
    "script",
    attrs: (src: p, defer: "true"),
  ))
  #with-embedded-file("../assets/scripts/justif.js", p => html.elem(
    "script",
    attrs: (type: "module", blocking: "render", src: p),
  ))

  #with-embedded-file("../assets/scripts/medium-zoom.js", p => html.elem(
    "script",
    attrs: (src: p),
  ))
  #html.script("let FF_FOUC_FIX;")

  // this is needed because zebraw wants to only insert the head content once,
  // but the counter is uses is global across all documents in bundle export.
  #counter("zebraw-html-styles").update(0)
  #counter("zebraw-html-clipboard").update(0)
  #show: zebraw-init

  #head
]

#let base(head: [], body) = [
  #reset-counters
  #html.html(lang: info.language)[
    #doc-head(head)
    #html.body[
      #{
        show: base-show.with(
          figure-class: "my-6 mx-auto w-fit",
          math-inline-class: "inline-block align-baseline text-lg",
          math-block-class: "my-6 flex justify-center text-2xl",
        )

        show list: it => html.ul(class: "list-none ml-6 my-5 space-y-5")[
          #for item in it.children {
            html.li(
              class: "marker:content-['»_'] marker:text-accent hover:marker:content-['#_'] hover:marker:font-bold hover:marker:text-link",
            )[#item.body]
          }
        ]
        show enum: it => html.ol(class: "list-decimal ml-6 my-5 space-y-5")[
          #for item in it.children {
            html.li(
              class: "marker:text-accent hover:marker:font-bold hover:marker:text-link",
            )[#item.body]
          }
        ]

        show raw.where(block: false): it => html.code(
          class: "px-1 rounded-sm bg-surface text-muted",
        )[#it.text]

        let everforestDark = plist(read(
          "/themes/everforest-dark.tmTheme",
          encoding: none,
        ))

        show raw.where(block: true): it => {
          show raw: it => it
          html.div(class: "code-block-wrapper picture-like")[
            #html.div(class: "theme-light")[
              #zebraw(raw(it.text, lang: it.lang, block: true))
            ]
            #html.div(class: "theme-dark")[
              #let foreground = (
                everforestDark
                  .settings
                  .at(0)
                  .settings
                  .at("foreground", default: none)
              )
              #let background = (
                everforestDark
                  .settings
                  .at(0)
                  .settings
                  .at("background", default: none)
              )

              #set raw(theme: "/themes/everforest-dark.tmTheme")
              #show raw: set text(fill: rgb(foreground)) if foreground != none

              #zebraw(
                raw(it.text, lang: it.lang, block: true),
                background-color: rgb(background),
              )
            ]
          ]
        }

        show quote: it => html.blockquote(class: cls(
          "border-l-4 border-accent pl-4 my-4 italic",
          colors.muted,
        ))[#it.body]

        html.main()[
          #html.div(id: "col-wrapper")[
            #html.nav(
              id: "nav-bar",
              class: "gap-x-3 items-center col-span-1 col-start-2",
            )[
              #html.a("/home/", href: "/")
              #html.div({
                html.input(
                  id: "theme-toggle",
                  style: "display: none",
                  type: "checkbox",
                )
                html.label(id: "theme-toggle-label", ..(
                  "for": "theme-toggle",
                  class: "flex",
                ))[
                  #html.elem("svg", attrs: (class: "icons"))[
                    #with-embedded-file(
                      "../assets/images/icons.svg",
                      p => html.elem("use", attrs: (href: p + "#lightMode")),
                    )
                  ]
                ]
              })
            ]

            #html.article(
              class: "space-y-6 col-span-1 col-start-2 pb-10",
            )[#body]
            #html.div(
              id: "notes",
              class: "col-span-1 col-start-3 row-span-full row-start-1",
            )[]
          ]
        ]
      }
    ]
  ]
]
