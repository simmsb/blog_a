#let sidenote-counter = counter("sidenotes")

#let reset-counters = [
  #counter(figure.where(kind: image)).update(0)
  #counter(figure.where(kind: raw)).update(0)
  #counter(figure.where(kind: table)).update(0)
  #sidenote-counter.update(0)
]
