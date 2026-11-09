// OWNER: ui-code-docs — the preview page's script: HephaestusDoc.render and scrollToFragment, link
// clicks, Copy buttons, broken images and the markers drawn by markdown.js
// (docs/documentation-viewer.md › Preview web view).
"use strict";

(function () {
  function post(message) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hephaestus) {
      window.webkit.messageHandlers.hephaestus.postMessage(message);
    }
  }

  function article() {
    return document.getElementById("doc");
  }

  function decodeFragment(fragment) {
    try {
      return decodeURIComponent(fragment);
    } catch (error) {
      return fragment;
    }
  }

  // Scrolls the element whose id equals the fragment to the top, else the element whose id
  // equals the fragment lowercased, else nothing.
  function scrollToFragment(fragment) {
    if (typeof fragment !== "string") {
      return;
    }
    var target = document.getElementById(fragment) || document.getElementById(fragment.toLowerCase());
    if (target) {
      target.scrollIntoView({ block: "start" });
    }
  }

  // Replaces the content of #doc with html; keepScroll restores the previous scroll offset
  // (clamped); a non-null fragment scrolls to it.
  function render(options) {
    var root = article();
    if (!root || !options) {
      return;
    }
    var scrollY = window.scrollY;
    root.innerHTML = typeof options.html === "string" ? options.html : "";
    // The markers: icons, swatches and fonts (markdown.js).
    if (window.HephaestusMarkdown) {
      window.HephaestusMarkdown.decorate(root);
    }
    if (options.keepScroll) {
      var maximum = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      window.scrollTo(0, Math.min(scrollY, maximum));
    } else {
      window.scrollTo(0, 0);
    }
    if (options.fragment !== null && options.fragment !== undefined) {
      scrollToFragment(options.fragment);
    }
  }

  // An img that fails to load becomes <span class="md-image-broken"> titled with its src, whose
  // text is "Image not found: " and the alt text, or the last path component of the src,
  // percent-decoded (docs/documentation-viewer.md › Preview web view).
  function replaceBrokenImage(image) {
    var source = image.getAttribute("src") || "";
    var alt = image.getAttribute("alt") || "";
    if (!alt) {
      var path = source.split("#")[0].split("?")[0];
      var parts = path.split("/");
      alt = decodeFragment(parts[parts.length - 1] || "");
    }
    var span = document.createElement("span");
    span.className = "md-image-broken";
    span.title = source;
    span.textContent = "Image not found: " + alt;
    if (image.parentNode) {
      image.parentNode.replaceChild(span, image);
    }
  }

  document.addEventListener("error", function (event) {
    var target = event.target;
    if (target && target.tagName === "IMG") {
      replaceBrokenImage(target);
    }
  }, true);

  function handleLink(event) {
    var element = event.target;
    while (element && element !== document) {
      if (element.tagName === "A" && element.hasAttribute("href")) {
        break;
      }
      element = element.parentNode;
    }
    if (!element || element === document) {
      return;
    }
    event.preventDefault();
    if (event.type !== "click") {
      return;
    }
    var href = element.getAttribute("href");
    if (href.charAt(0) === "#") {
      scrollToFragment(decodeFragment(href.substring(1)));
    } else {
      post({ action: "openLink", url: href, commandKey: !!event.metaKey });
    }
  }

  document.addEventListener("click", function (event) {
    // The play button of a sound marker sends playSound, the replay button of an animation marker
    // plays its lane (markdown.js).
    if (window.HephaestusMarkdown && window.HephaestusMarkdown.handleClick(event.target)) {
      event.preventDefault();
      return;
    }
    var button = event.target && event.target.closest ? event.target.closest("button.md-copy") : null;
    if (button) {
      event.preventDefault();
      var block = button.closest(".md-codeblock");
      var code = block ? block.querySelector("pre code") : null;
      post({ action: "copy", text: code ? code.textContent : "" });
      button.textContent = "Copied";
      setTimeout(function () {
        button.textContent = "Copy";
      }, 1500);
      return;
    }
    handleLink(event);
  });

  document.addEventListener("auxclick", handleLink);

  window.HephaestusDoc = {
    render: render,
    scrollToFragment: scrollToFragment
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      post({ action: "ready" });
    });
  } else {
    post({ action: "ready" });
  }
})();
