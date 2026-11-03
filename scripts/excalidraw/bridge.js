// The page ExcalidrawUI shows in its web view: Excalidraw, and `window.loam`, what Swift calls.
// Bundled with React into App/Sources/Plugins/ExcalidrawUI/Resources/excalidraw/ by scripts/vendor-excalidraw.sh.
//
// To Swift (window.webkit.messageHandlers.loam): {type: "ready"} once loaded, {type: "change", scene} when the
// drawing changed (debounced), {type: "openLink", url} when a link of the drawing is opened, {type: "library",
// library} when the library (shared by every drawing, an `.excalidrawlib`) changed.
// From Swift: loam.load(sceneJSON, libraryJSON), loam.setTheme("light" | "dark"), loam.addFiles([{id, mimeType,
// dataURL}]), loam.setLibrary(libraryJSON) (another drawing changed it), loam.addLibrary(libraryJSON) (one added from
// libraries.excalidraw.com, merged and shown),
// loam.flush() -> the scene as JSON now, loam.renderSVG(sceneJSON, dark) -> an SVG of a scene, and
// loam.renderPNG(sceneJSON, dark, maxSize) -> a PNG of it as base64 (null when empty), without showing it.
import React from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw,
  MainMenu,
  WelcomeScreen,
  exportToBlob,
  exportToSvg,
  loadLibraryFromBlob,
  restore,
  serializeAsJSON,
  serializeLibraryAsJSON,
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";

const h = React.createElement;
const SAVE_DELAY = 400;

function post(message) {
  const handler = window.webkit?.messageHandlers?.loam;
  if (handler) handler.postMessage(message);
  else console.log("loam", message.type, message);
}

let api = null;
let lastSent = null;
let pending = null;
let setState = null;
// Set while Swift's library goes in, so it is not sent back.
let applyingLibrary = false;

function libraryItems(json) {
  if (!json) return [];
  const data = JSON.parse(json);
  return data.libraryItems || data.library || [];
}

async function applyLibrary(update) {
  applyingLibrary = true;
  try {
    await api?.updateLibrary(update);
  } finally {
    applyingLibrary = false;
  }
}

function serialize() {
  if (!api) return null;
  return serializeAsJSON(api.getSceneElementsIncludingDeleted(), api.getAppState(), api.getFiles(), "local");
}

function sendIfChanged() {
  pending = null;
  const scene = serialize();
  if (scene === null || scene === lastSent) return;
  lastSent = scene;
  post({ type: "change", scene });
}

function onChange() {
  if (pending) clearTimeout(pending);
  pending = setTimeout(sendIfChanged, SAVE_DELAY);
}

function parse(json) {
  const data = JSON.parse(json);
  return restore(data, null, null, { refreshDimensions: false, repairBindings: true });
}

// A colour as Excalidraw's dark theme shows it: `invert(93%) hue-rotate(180deg)`.
function darkColor(color) {
  const match = /^#([0-9a-f]{3}|[0-9a-f]{6})([0-9a-f]{2})?$/i.exec(color || "");
  if (!match) return color;
  let hex = match[1];
  if (hex.length === 3) hex = hex.replace(/./g, (c) => c + c);
  const [r, g, b] = [0, 2, 4].map((i) => 0.93 - 0.86 * (parseInt(hex.slice(i, i + 2), 16) / 255));
  const rows = [
    [-0.574, 1.43, 0.144],
    [0.426, 0.43, 0.144],
    [0.426, 1.43, -0.856],
  ];
  const out = rows.map(([x, y, z]) => Math.round(Math.min(1, Math.max(0, x * r + y * g + z * b)) * 255));
  return "#" + out.map((v) => v.toString(16).padStart(2, "0")).join("") + (match[2] || "");
}

function App() {
  const [state, set] = React.useState({ scene: null, theme: "light", generation: 0 });
  setState = set;
  // Swift loads the drawing once React can take it.
  React.useEffect(() => post({ type: "ready" }), []);
  if (!state.scene) return null;
  return h(
    Excalidraw,
    {
      key: state.generation,
      initialData: { ...state.scene, libraryItems: state.library, scrollToContent: true },
      excalidrawAPI: (value) => {
        api = value;
      },
      theme: state.theme,
      onChange,
      onLibraryChange: (items) => {
        if (!applyingLibrary) post({ type: "library", library: serializeLibraryAsJSON(items) });
      },
      onLinkOpen: (element, event) => {
        event.preventDefault();
        post({ type: "openLink", url: element.link });
      },
      UIOptions: {
        canvasActions: {
          loadScene: false,
          saveToActiveFile: false,
          toggleTheme: null,
          export: false,
        },
      },
    },
    h(
      MainMenu,
      null,
      h(MainMenu.DefaultItems.SaveAsImage),
      h(MainMenu.DefaultItems.Help),
      h(MainMenu.DefaultItems.ClearCanvas),
      h(MainMenu.Separator),
      h(MainMenu.DefaultItems.ChangeCanvasBackground),
    ),
    h(
      WelcomeScreen,
      null,
      h(WelcomeScreen.Hints.MenuHint),
      h(WelcomeScreen.Hints.ToolbarHint),
      h(WelcomeScreen.Hints.HelpHint),
    ),
  );
}

window.loam = {
  load(json, library) {
    const scene = parse(json);
    lastSent = null;
    if (pending) clearTimeout(pending);
    pending = null;
    if (api) {
      // A reload of the open drawing (the file changed on disk): keep the view, replace the content.
      api.addFiles(Object.values(scene.files || {}));
      api.updateScene({ elements: scene.elements, appState: { viewBackgroundColor: scene.appState.viewBackgroundColor } });
      api.history?.clear?.();
      lastSent = serialize();
      return;
    }
    // Excalidraw picks its phone layout from the page's size when it mounts: wait for the real one.
    const mount = () => {
      if (document.body.clientWidth < 100 || document.body.clientHeight < 100) {
        requestAnimationFrame(mount);
        return;
      }
      setState((state) => ({ ...state, scene, library: libraryItems(library), generation: state.generation + 1 }));
    };
    mount();
  },
  setTheme(theme) {
    setState((state) => ({ ...state, theme }));
  },
  addFiles(files) {
    api?.addFiles(files);
  },
  async setLibrary(json) {
    await applyLibrary({ libraryItems: libraryItems(json), merge: false });
  },
  async addLibrary(json) {
    // Excalidraw reads both library versions; the result reaches Swift through onLibraryChange.
    const blob = new Blob([json], { type: "application/vnd.excalidrawlib+json" });
    await api?.updateLibrary({ libraryItems: loadLibraryFromBlob(blob), merge: true, openLibraryMenu: true });
  },
  flush() {
    if (pending) clearTimeout(pending);
    pending = null;
    const scene = serialize();
    if (scene !== null) lastSent = scene;
    return scene;
  },
  async renderSVG(json, dark) {
    const scene = parse(json);
    const svg = await exportToSvg({
      elements: scene.elements.filter((element) => !element.isDeleted),
      appState: { ...scene.appState, exportBackground: false, exportWithDarkMode: !!dark },
      files: scene.files,
      exportPadding: 16,
    });
    return svg.outerHTML;
  },
  async renderPNG(json, dark, maxSize) {
    const scene = parse(json);
    let elements = scene.elements.filter((element) => !element.isDeleted);
    if (elements.length === 0) return null;
    // Excalidraw darkens a canvas with `filter`, which WebKit's canvas lacks: the colours are darkened here, the
    // pictures left as they are, as the editor shows them.
    if (dark) {
      elements = elements.map((element) => ({
        ...element,
        strokeColor: darkColor(element.strokeColor),
        backgroundColor: darkColor(element.backgroundColor),
      }));
    }
    const blob = await exportToBlob({
      elements,
      appState: { ...scene.appState, exportBackground: false, exportWithDarkMode: false },
      files: scene.files,
      exportPadding: 16,
      maxWidthOrHeight: maxSize,
      mimeType: "image/png",
    });
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  },
};

createRoot(document.getElementById("root")).render(h(App));
