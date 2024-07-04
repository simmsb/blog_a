#import "/utils/common.typ": cls
#import "/utils/counters.typ": sidenote-counter
#import "/templates/base.typ" as base
#import "@preview/oxifmt:1.0.0": strfmt

#let nav-link(href, label) = html.a(
  class: "text-muted hover:text-accent transition-colors",
  href: href,
)[#label]

#let tag(name) = html.span(
  class: "px-2 py-1 text-xs bg-surface rounded text-accent",
)[#name]

#let sidenote-mark(lbl) = {
  html.elem("span", attrs: (
    id: strfmt("{}-ref", str(lbl)),
    style: strfmt("--is: --{}-ref", str(lbl)),
    data-hover-target: str(lbl),
    class: "sidenote-ref text-sm align-sub",
  ))[#link(lbl)[
    #let idx = context {
      query(label(str(lbl) + "-idx")).first().value.note-idx
    }
    ^#idx
  ]]
}

#let sidenote(lbl, body) = context [
  #sidenote-counter.step()
  #let idx = sidenote-counter.get().first()

  #html.elem("aside", attrs: (
    id: str(lbl),
    style: strfmt("--for: --{}-ref", str(lbl)),
    data-hover-target: strfmt("{}-ref", str(lbl)),
    class: cls(
      "px-2 py-2",
      "sidenote-note",
      "rounded-sm transition-colors [&.active-hover]:bg-link [&.active-hover]:text-bg",
    ),
  ))[
    #metadata((note-idx: idx)) #label(str(lbl) + "-idx")
    #html.div(class: "flex flex-row")[
      #html.small(
        class: "transition-colors text-link in-[.active-hover]:text-bg",
      )[#idx.]
      #html.small[
        #body #lbl
      ]
    ]
  ]
]
