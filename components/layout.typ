#import "/utils/common.typ": cls

#let hr = html.hr(class: "border-surface my-8")

#let flex-row(class: none, ..items) = html.div(
  class: cls(
    "gap-4 flex flex-row flex-wrap has-[>_:last-child:nth-child(-n_+_2)]:items-start has-[>_:last-child:nth-child(3)]:items-end justify-center [&>*]:flex-[0_0_49%]",
    class,
  ),
)[#for item in items.pos() { item }]

#let flex-col(class: none, ..items) = html.div(
  class: cls("flex flex-col", class),
)[#for item in items.pos() { item }]

#let grid(cols: 2, gap: 4, ..items) = html.div(
  class: cls("grid", "grid-cols-" + str(cols), "gap-" + str(gap)),
)[#for item in items.pos() { item }]
