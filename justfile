TAILWIND_LOCATION := "generated/tailwind.css"

ensure-generated-dir:
    @mkdir -p generated

gen-posts: ensure-generated-dir
    find content/ -type f -name "*.typ" > generated/posts

css: ensure-generated-dir
    tailwindcss -i assets/styles/tailwind.css -o {{TAILWIND_LOCATION}} --minify

build: gen-posts css
    typst compile main.typ public --root . --format bundle --features bundle,html

watch-typst: ensure-generated-dir
    typst watch main.typ public --root . --format bundle --features bundle,html

optimise: build
    magick mogrify -resize "2048x2048>" public/images/*
    oxipng -r public/images/

clean-build:
    rm -rf public
    just optimise

publish: build optimise
    rsync --chmod="Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r" -avzh public/ vps3:/var/www/blog/. --delete
