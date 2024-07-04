#let posts = (
  read("../generated/posts")
    .trim("\n")
    .split("\n")
    .map(p => {
      import ("../" + p) as P
      (
        post: P,
        path: p.split("/").last().split(".").first(),
      )
    })
)
