// OWNER: ui-chats — the transcript page's script: HephaestusChat.reset, prepend, upsert, stream and
// clearStreams, and the messages to Swift (docs/chats.md › Web view and bridge).
"use strict";
(function () {
  // MARK: Messages to Swift

  function post(message) {
    try {
      window.webkit.messageHandlers.hephaestus.postMessage(message);
    } catch (e) {
      // Outside the app there is no message handler.
    }
  }

  // MARK: Icons: inline SVG drawings (docs/chats.md › Tool cards)

  function circle(cx, cy, r) {
    return "M" + (cx - r) + " " + cy + "a" + r + " " + r + " 0 1 0 " + 2 * r + " 0a" + r + " " + r + " 0 1 0 " + -2 * r + " 0";
  }

  var ICONS = {
    terminal: ["M3.5 5h17v14h-17z", "M7 9.5l3 2.5-3 2.5", "M12 15h5"],
    document: ["M6 3h8l4 4v14H6z", "M14 3v4h4", "M9 12h6", "M9 16h6"],
    file: ["M6 3h8l4 4v14H6z", "M14 3v4h4"],
    magnifier: [circle(10.5, 10.5, 6), "M15 15l5.5 5.5"],
    globe: [circle(12, 12, 9), "M3 12h18", "M12 3c3.5 3.5 3.5 14.5 0 18", "M12 3c-3.5 3.5-3.5 14.5 0 18"],
    people: [circle(9, 8, 3), "M3 19c0-3.3 2.7-5 6-5s6 1.7 6 5", circle(17, 9, 2.5), "M16 14.2c2.8 0 5 1.6 5 4.8"],
    checklist: ["M4 6.5l1.5 1.5 2.5-3", "M11 6.5h9", "M4 12.5l1.5 1.5 2.5-3", "M11 12.5h9", "M4 18.5l1.5 1.5 2.5-3", "M11 18.5h9"],
    plug: ["M9 3v5", "M15 3v5", "M6.5 8h11v3a5.5 5.5 0 0 1-11 0z", "M12 16.5V21"],
    wrench: ["M14.5 3.5a5 5 0 0 0-4.6 6.9L3.5 16.8l3.7 3.7 6.4-6.4a5 5 0 0 0 6.9-4.6l-3 3-3.6-1-1-3.6 3-3a5 5 0 0 0-1.4-.4z"]
  };

  var SVG_NS = "http://www.w3.org/2000/svg";

  function iconElement(name) {
    var paths = ICONS[name] || ICONS.wrench;
    var svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    for (var i = 0; i < paths.length; i++) {
      var path = document.createElementNS(SVG_NS, "path");
      path.setAttribute("d", paths[i]);
      svg.appendChild(path);
    }
    return svg;
  }

  function decorate(element) {
    var icons = element.querySelectorAll("[data-icon]");
    for (var i = 0; i < icons.length; i++) {
      if (!icons[i].firstChild) {
        icons[i].appendChild(iconElement(icons[i].getAttribute("data-icon")));
      }
    }
    // SF Symbol markers: the icon is the text color through a mask that holds the symbol's image
    // (docs/chats.md › Links, images and files).
    var symbols = element.querySelectorAll(".md-symbol-icon[data-symbol]");
    for (var j = 0; j < symbols.length; j++) {
      var mask = 'url("hephaestus-symbol://symbol/' + encodeURIComponent(symbols[j].getAttribute("data-symbol")) + '")';
      symbols[j].style.webkitMaskImage = mask;
      symbols[j].style.maskImage = mask;
    }
    // Color markers: the swatch takes the light or dark value of its marker through two CSS
    // variables (docs/chats.md › Links, images and files).
    var swatches = element.querySelectorAll(".md-color-swatch[data-light][data-dark]");
    for (var k = 0; k < swatches.length; k++) {
      swatches[k].style.setProperty("--md-color-light", swatches[k].getAttribute("data-light"));
      swatches[k].style.setProperty("--md-color-dark", swatches[k].getAttribute("data-dark"));
    }
    // Font markers: the label in the family and weight of the marker, or in the face loaded from
    // its `data-font-face` URL (docs/chats.md › Links, images and files).
    var fonts = element.querySelectorAll(".md-font[data-font-family]");
    for (var m = 0; m < fonts.length; m++) {
      var family = fonts[m].getAttribute("data-font-family");
      var source = fonts[m].getAttribute("data-font-face");
      fonts[m].style.fontFamily = source ? '"' + fontFaceName(source) + '", ' + family : family;
      fonts[m].style.fontWeight = fonts[m].getAttribute("data-font-weight") || "400";
    }
  }

  /// The page's font names of the faces loaded so far, by URL.
  var fontFaces = new Map();

  /// The name of the face of a `hephaestus-font` URL, added to the page's fonts the first time.
  function fontFaceName(source) {
    var name = fontFaces.get(source);
    if (!name) {
      name = "hephaestus-face-" + (fontFaces.size + 1);
      fontFaces.set(source, name);
      var face = new FontFace(name, 'url("' + source + '")');
      document.fonts.add(face);
      face.load().catch(function () {});
    }
    return name;
  }

  // MARK: Animation markers (docs/chats.md › Links, images and files)

  /// Plays the lane of an animation marker: the circle starts again from the left end and moves
  /// to the right end with the marker's duration and easing, then stays there.
  function playAnimation(marker) {
    var lane = marker.querySelector(".md-animation-lane");
    var dot = marker.querySelector(".md-animation-dot");
    if (!lane || !dot || !dot.animate) return;
    dot.getAnimations().forEach(function (animation) {
      animation.cancel();
    });
    var travel = Math.max(0, lane.clientWidth - dot.offsetWidth);
    var duration = Math.max(0, parseFloat(marker.getAttribute("data-duration")) || 0) * 1000;
    var frames = [{ transform: "translateX(0px)" }, { transform: "translateX(" + travel + "px)" }];
    try {
      dot.animate(frames, { duration: duration, easing: marker.getAttribute("data-easing") || "linear", fill: "forwards" });
    } catch (e) {
      dot.animate(frames, { duration: duration, easing: "linear", fill: "forwards" });
    }
  }

  // MARK: Page structure

  var transcript, streamsBox, placeholder, earlier, earlierButton, jump;
  /// Fragment elements by item id.
  var fragments = new Map();
  /// Tool card fragment elements by toolUseID.
  var cards = new Map();
  /// Streaming bubbles by item id.
  var streams = new Map();
  /// True while the view is kept at the bottom when content grows.
  var stick = true;

  function atBottom() {
    var page = document.scrollingElement || document.documentElement;
    return page.scrollHeight - page.scrollTop - window.innerHeight <= 40;
  }

  function scrollToBottom(smooth) {
    var page = document.scrollingElement || document.documentElement;
    window.scrollTo({ top: page.scrollHeight, behavior: smooth ? "smooth" : "auto" });
  }

  function updateJump() {
    jump.hidden = atBottom();
  }

  function contentChanged() {
    if (stick) {
      scrollToBottom(false);
    }
    updateJump();
  }

  function setPlaceholder(text) {
    placeholder.textContent = text || "";
    placeholder.hidden = !text || fragments.size > 0 || streams.size > 0;
  }

  function hidePlaceholder() {
    placeholder.hidden = true;
  }

  function setEarlier(hasEarlier) {
    earlier.hidden = !hasEarlier;
    earlierButton.disabled = false;
  }

  // MARK: Fragments

  function createElement(fragment) {
    var element = document.createElement("div");
    element.className = "frag frag-" + fragment.type;
    element.setAttribute("data-id", fragment.id);
    if (fragment.parentToolUseID) {
      element.setAttribute("data-parent", fragment.parentToolUseID);
    }
    if (fragment.toolUseID) {
      element.setAttribute("data-tool-use-id", fragment.toolUseID);
    }
    element.innerHTML = fragment.html;
    decorate(element);
    return element;
  }

  function slotOf(card, selector) {
    return card.querySelector(":scope > .tool-card > .tool-body > " + selector);
  }

  function resultSlot(card) {
    return slotOf(card, ".tool-result-slot");
  }

  function stepsBox(card) {
    return card.querySelector(":scope > .tool-card > .tool-body > .tool-steps-section > .tool-steps");
  }

  /// A standalone card titled `Tool result` around a result whose call has no card.
  function standalone(element) {
    var wrapper = document.createElement("div");
    wrapper.className = "frag frag-standalone";
    var card = document.createElement("div");
    card.className = "tool-card standalone-result";
    var header = document.createElement("div");
    header.className = "tool-header";
    var name = document.createElement("span");
    name.className = "tool-name";
    name.textContent = "Tool result";
    header.appendChild(name);
    var trailing = document.createElement("span");
    trailing.className = "tool-trailing";
    if (element.querySelector(".tool-result.is-error")) {
      var tag = document.createElement("span");
      tag.className = "tag-error";
      tag.textContent = "Error";
      trailing.appendChild(tag);
    }
    header.appendChild(trailing);
    var body = document.createElement("div");
    body.className = "tool-body";
    body.appendChild(element);
    card.appendChild(header);
    card.appendChild(body);
    wrapper.appendChild(card);
    return wrapper;
  }

  /// Places a new fragment element: a result in its card, a step in its parent's card, anything
  /// else at the end of `container` (or before `before`).
  function place(element, fragment, container, before) {
    if (fragment.type === "toolResult") {
      var owner = cards.get(fragment.toolUseID);
      if (owner) {
        resultSlot(owner).replaceChildren(element);
        return;
      }
      container.insertBefore(standalone(element), before || null);
      return;
    }
    if (fragment.parentToolUseID) {
      var parent = cards.get(fragment.parentToolUseID);
      if (parent) {
        stepsBox(parent).appendChild(element);
        return;
      }
    }
    container.insertBefore(element, before || null);
  }

  /// Moves the steps and the result that were placed before their card existed into it.
  function rehome(card) {
    var toolUseID = card.getAttribute("data-tool-use-id");
    var steps = stepsBox(card);
    var orphans = Array.prototype.slice.call(transcript.children);
    for (var i = 0; i < orphans.length; i++) {
      var orphan = orphans[i];
      if (orphan === card || orphan.contains(card)) {
        continue;
      }
      if (orphan.getAttribute("data-parent") === toolUseID) {
        steps.appendChild(orphan);
      } else if (orphan.classList.contains("frag-standalone")) {
        var result = orphan.querySelector(".frag-toolResult");
        if (result && result.getAttribute("data-tool-use-id") === toolUseID) {
          resultSlot(card).replaceChildren(result);
          orphan.remove();
        }
      }
    }
  }

  /// Carries the view state of a replaced fragment over to its new element: an expanded card
  /// with its result and steps, an open thinking block, a result shown in full.
  function transfer(oldElement, newElement) {
    var oldCard = oldElement.querySelector(":scope > .tool-card");
    var newCard = newElement.querySelector(":scope > .tool-card");
    if (oldCard && newCard) {
      if (oldCard.classList.contains("expanded")) {
        newCard.classList.add("expanded");
      }
      var oldSlot = resultSlot(oldElement), newSlot = resultSlot(newElement);
      if (oldSlot && newSlot) {
        while (oldSlot.firstChild) newSlot.appendChild(oldSlot.firstChild);
      }
      var oldSteps = stepsBox(oldElement), newSteps = stepsBox(newElement);
      if (oldSteps && newSteps) {
        while (oldSteps.firstChild) newSteps.appendChild(oldSteps.firstChild);
      }
    }
    var oldDetails = oldElement.querySelector(":scope > details");
    var newDetails = newElement.querySelector(":scope > details");
    if (oldDetails && newDetails && oldDetails.open) {
      newDetails.open = true;
    }
    var oldRest = oldElement.querySelector(".result-rest");
    var newRest = newElement.querySelector(".result-rest");
    if (oldRest && newRest && !oldRest.hidden) {
      showAll(newElement.querySelector(".show-all"));
    }
  }

  function register(element, fragment) {
    fragments.set(fragment.id, element);
    if (fragment.type === "toolUse" && fragment.toolUseID) {
      cards.set(fragment.toolUseID, element);
    }
  }

  function removeStream(id) {
    var bubble = streams.get(id);
    if (bubble) {
      bubble.remove();
      streams.delete(id);
    }
  }

  /// Builds a batch of fragments in transcript order inside `container`; returns the new cards.
  function build(items, container) {
    var newCards = [];
    for (var i = 0; i < items.length; i++) {
      var fragment = items[i];
      var existing = fragments.get(fragment.id);
      if (existing) {
        replace(existing, fragment);
        continue;
      }
      var element = createElement(fragment);
      register(element, fragment);
      place(element, fragment, container, null);
      if (fragment.type === "toolUse") {
        newCards.push(element);
      }
    }
    return newCards;
  }

  function replace(existing, fragment) {
    var element = createElement(fragment);
    transfer(existing, element);
    existing.replaceWith(element);
    register(element, fragment);
  }

  // MARK: Bridge (calls from Swift)

  window.HephaestusChat = {
    reset: function (options) {
      fragments.clear();
      cards.clear();
      streams.clear();
      transcript.replaceChildren();
      streamsBox.replaceChildren();
      var newCards = build(options.items || [], transcript);
      for (var i = 0; i < newCards.length; i++) rehome(newCards[i]);
      setEarlier(!!options.hasEarlier);
      setPlaceholder(options.placeholder);
      stick = true;
      contentChanged();
    },

    prepend: function (options) {
      var page = document.scrollingElement || document.documentElement;
      var oldHeight = page.scrollHeight;
      var oldTop = page.scrollTop;
      var batch = document.createDocumentFragment();
      var holder = document.createElement("div");
      var newCards = build(options.items || [], holder);
      while (holder.firstChild) batch.appendChild(holder.firstChild);
      transcript.insertBefore(batch, transcript.firstChild);
      for (var i = 0; i < newCards.length; i++) rehome(newCards[i]);
      setEarlier(!!options.hasEarlier);
      if (fragments.size > 0) hidePlaceholder();
      window.scrollTo(0, oldTop + (page.scrollHeight - oldHeight));
      stick = atBottom();
      updateJump();
    },

    upsert: function (fragment) {
      removeStream(fragment.id);
      var existing = fragments.get(fragment.id);
      if (existing) {
        replace(existing, fragment);
      } else {
        var element = createElement(fragment);
        register(element, fragment);
        place(element, fragment, transcript, null);
        if (fragment.type === "toolUse") rehome(element);
      }
      hidePlaceholder();
      contentChanged();
    },

    stream: function (options) {
      if (fragments.has(options.itemID)) return;
      var bubble = streams.get(options.itemID);
      if (!bubble) {
        bubble = document.createElement("div");
        bubble.className = "frag stream stream-" + options.kind;
        bubble.setAttribute("data-id", options.itemID);
        streams.set(options.itemID, bubble);
        streamsBox.appendChild(bubble);
      }
      bubble.innerHTML = options.html;
      decorate(bubble);
      hidePlaceholder();
      contentChanged();
    },

    clearStreams: function () {
      streams.clear();
      streamsBox.replaceChildren();
      contentChanged();
    }
  };

  // MARK: User actions

  function showAll(button) {
    if (!button) return;
    var result = button.closest(".tool-result");
    var rest = result && result.querySelector(".result-rest");
    if (rest) rest.hidden = false;
    button.remove();
  }

  function copied(button) {
    var title = button.textContent;
    button.textContent = "Copied";
    setTimeout(function () {
      button.textContent = title;
    }, 1500);
  }

  function selectionInside(element) {
    var selection = window.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return false;
    return element.contains(selection.getRangeAt(0).commonAncestorContainer);
  }

  function handleClick(event) {
    var target = event.target;
    if (!(target instanceof Element)) return;

    var link = target.closest("a[href]");
    if (link) {
      event.preventDefault();
      var href = link.getAttribute("href");
      // A `#fragment` link does nothing (docs/chats.md › Links, images and files).
      if (href && href.charAt(0) !== "#") {
        post({ action: "openLink", url: href, commandKey: !!event.metaKey });
      }
      return;
    }

    // The play button of a sound marker (docs/chats.md › Links, images and files).
    var play = target.closest(".md-sound-play");
    if (play) {
      post({ action: "playSound", name: play.getAttribute("data-sound") || "" });
      return;
    }

    // The replay button of an animation marker (docs/chats.md › Links, images and files).
    var replay = target.closest(".md-animation-play");
    if (replay) {
      var marker = replay.closest(".md-animation");
      if (marker) playAnimation(marker);
      return;
    }

    var codeCopy = target.closest(".md-copy");
    if (codeCopy) {
      var block = codeCopy.closest(".md-codeblock");
      var code = block && block.querySelector("code");
      post({ action: "copy", text: code ? code.textContent : "" });
      copied(codeCopy);
      return;
    }

    var bubbleCopy = target.closest(".bubble-copy");
    if (bubbleCopy) {
      var bubble = bubbleCopy.closest(".bubble");
      post({ action: "copy", text: bubble ? bubble.getAttribute("data-source") || "" : "" });
      copied(bubbleCopy);
      return;
    }

    var more = target.closest(".show-all");
    if (more) {
      showAll(more);
      return;
    }

    var attachment = target.closest("[data-path]");
    if (attachment && (attachment.tagName === "IMG" || attachment.classList.contains("file-chip"))) {
      post({ action: "openAttachment", path: attachment.getAttribute("data-path") });
      return;
    }

    var header = target.closest(".tool-header");
    if (header && !selectionInside(header)) {
      var card = header.closest(".tool-card");
      if (card && !card.classList.contains("preparing")) {
        stick = false;
        card.classList.toggle("expanded");
        requestAnimationFrame(function () {
          stick = atBottom();
          updateJump();
        });
      }
    }
  }

  /// An image that fails to load becomes `Image not found: <alt>` (docs/documentation-viewer.md ›
  /// Preview web view), built with DOM methods.
  function handleError(event) {
    var image = event.target;
    if (!(image instanceof HTMLImageElement)) return;
    var source = image.getAttribute("src") || "";
    var name = image.getAttribute("alt") || source.split("/").pop();
    var broken = document.createElement("span");
    broken.className = "md-image-broken";
    broken.title = source;
    broken.textContent = "Image not found: " + name;
    image.replaceWith(broken);
  }

  document.addEventListener("DOMContentLoaded", function () {
    transcript = document.getElementById("transcript");
    streamsBox = document.getElementById("streams");
    placeholder = document.getElementById("placeholder");
    earlier = document.getElementById("earlier");
    earlierButton = document.getElementById("earlier-button");
    jump = document.getElementById("jump");

    earlierButton.addEventListener("click", function () {
      earlierButton.disabled = true;
      post({ action: "loadEarlier" });
    });
    jump.addEventListener("click", function () {
      stick = true;
      scrollToBottom(true);
    });
    document.addEventListener("click", handleClick);
    document.addEventListener("error", handleError, true);
    window.addEventListener("scroll", function () {
      stick = atBottom();
      updateJump();
    }, { passive: true });
    window.addEventListener("resize", contentChanged);
    if (window.ResizeObserver) {
      new ResizeObserver(contentChanged).observe(document.body);
    }
    post({ action: "ready" });
  });
})();
