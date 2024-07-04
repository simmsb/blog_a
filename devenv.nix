{ pkgs, lib, config, inputs, ... }:

{
  packages = with pkgs; [
    just
    typst
    tailwindcss_4
    typstyle
    imagemagick
    oxipng
  ];

  processes = {
    typst = {
      exec = "just watch-typst";
    };

    posts = {
      exec = "just gen-posts";
      watch = {
        paths = [ ./content ];
        extensions = [ "typ" ];
      };
    };

    css = {
      exec = "just css";
      watch = {
        paths = [ ./assets ./components ./content ./templates ./themes ./utils ];
        extensions = [ "typ" "css" ];
      };
    };
  };
}
