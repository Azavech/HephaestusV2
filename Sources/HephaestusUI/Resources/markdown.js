// OWNER: ui-code-docs — the markers of rendered Markdown in doc.html and chat.html: their icons,
// swatches and fonts, the play button of sounds and the replay of animations
// (docs/documentation-viewer.md › Preview web view, docs/chats.md › Links, images and files).
"use strict";
(function () {
  function post(message) {
    try {
      window.webkit.messageHandlers.hephaestus.postMessage(message);
    } catch (e) {
      // Outside the app there is no message handler.
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

  /// Draws the markers inside an element.
  function decorate(element) {
    if (!element || !element.querySelectorAll) return;
    // SF Symbol markers: the icon is the text color through a mask that holds the symbol's image.
    var symbols = element.querySelectorAll(".md-symbol-icon[data-symbol]");
    for (var i = 0; i < symbols.length; i++) {
      var mask = 'url("hephaestus-symbol://symbol/' + encodeURIComponent(symbols[i].getAttribute("data-symbol")) + '")';
      symbols[i].style.webkitMaskImage = mask;
      symbols[i].style.maskImage = mask;
    }
    // Color markers: the swatch takes the light or dark value of its marker through two CSS
    // variables.
    var swatches = element.querySelectorAll(".md-color-swatch[data-light][data-dark]");
    for (var j = 0; j < swatches.length; j++) {
      swatches[j].style.setProperty("--md-color-light", swatches[j].getAttribute("data-light"));
      swatches[j].style.setProperty("--md-color-dark", swatches[j].getAttribute("data-dark"));
    }
    // Font markers: the label in the family and weight of the marker, or in the face loaded from
    // its `data-font-face` URL.
    var fonts = element.querySelectorAll(".md-font[data-font-family]");
    for (var k = 0; k < fonts.length; k++) {
      var family = fonts[k].getAttribute("data-font-family");
      var source = fonts[k].getAttribute("data-font-face");
      fonts[k].style.fontFamily = source ? '"' + fontFaceName(source) + '", ' + family : family;
      fonts[k].style.fontWeight = fonts[k].getAttribute("data-font-weight") || "400";
    }
  }

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

  /// A click on the play button of a sound marker sends `playSound`; a click on the replay button
  /// of an animation marker plays its lane. Returns whether the click was one of them.
  function handleClick(target) {
    if (!(target instanceof Element)) return false;
    var play = target.closest(".md-sound-play");
    if (play) {
      post({ action: "playSound", name: play.getAttribute("data-sound") || "" });
      return true;
    }
    var replay = target.closest(".md-animation-play");
    if (replay) {
      var marker = replay.closest(".md-animation");
      if (marker) playAnimation(marker);
      return true;
    }
    return false;
  }

  window.HephaestusMarkdown = {
    decorate: decorate,
    handleClick: handleClick
  };
})();
