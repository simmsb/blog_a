#import "/templates/page.typ": page
#import "/utils/posts.typ": posts
#import "/utils/common.typ": parse-date
#import "/templates/base.typ": embedded-file-label, embedded-image-label

// dumb thing just to trim off an /index.html from links
#show html.elem.where(tag: "a"): it => {
  let attrs = it.attrs
  if "href" in attrs and attrs.href.contains("/index.html") {
    attrs.href = attrs.href.replace("/index.html", "")
    html.elem(it.tag, attrs: attrs, it.body)
  } else {
    it
  }
}

#document("index.html", title: [Index])[
  #show: page.with(title: "Home")

  There's some stuff here for you to read:

  #for post in posts.sorted(key: it => parse-date(it.post.args.date)).rev() {
    [- #link(label(post.path))[#post.post.args.title]]
  }
] <index>


#for post in posts [
  #document(post.path + "/index.html")[#post.post] #label(post.path)
]

#context {
  for im in query(embedded-image-label) [
    #asset(im.value.path, read(im.value.source, encoding: none))
  ]
  for f in query(embedded-file-label).dedup(key: f => f.value.path) [
    #asset(f.value.path, read(f.value.source, encoding: none))
  ]
}
